import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from verify_claude_review import IncompleteReview, main, validate_execution, validate_publication


class ReviewCompletionTest(unittest.TestCase):
    def setUp(self):
        self.result = {"type": "result", "subtype": "success", "is_error": False, "permission_denials": []}
        self.event = {"repository": {"full_name": "custyard/custyard"},
                      "pull_request": {"number": 45, "head": {"sha": "abc123"}}}
        self.current = {"head": {"sha": "abc123"}, "state": "open", "draft": False}
        self.comment = {"user": {"login": "claude[bot]"},
                        "body": "Reviewed abc123. No issues found after checking the complete diff.\n"
                                "<!-- claude-review:abc123:100:1 -->",
                        "html_url": "https://github.com/custyard/custyard/pull/45#issuecomment-1"}

    def fetch(self, endpoint, paginate=False):
        if paginate:
            return [[], [self.comment]]
        return self.current

    def test_complete_execution_and_published_review(self):
        validate_execution([self.result])
        self.assertEqual(validate_publication(self.event, "100", "1", self.fetch), self.comment["html_url"])

    def test_missing_final_result_fails(self):
        for messages in (None, [], [{"type": "assistant"}], [self.result, self.result]):
            with self.subTest(messages=messages), self.assertRaises(IncompleteReview):
                validate_execution(messages)

    def test_unsuccessful_results_fail(self):
        for changes in ({"is_error": True}, {"subtype": "error_max_turns"}, {"is_error": None}):
            with self.subTest(changes=changes), self.assertRaises(IncompleteReview):
                validate_execution([{**self.result, **changes}])

    def test_permission_denials_fail_without_exposing_inputs(self):
        denied = {**self.result, "permission_denials": [{"tool_name": "Bash", "tool_input": "SECRET_TOKEN"}]}
        with self.assertRaises(IncompleteReview) as error:
            validate_execution([denied])
        self.assertIn("Bash", str(error.exception))
        self.assertNotIn("SECRET_TOKEN", str(error.exception))

    def test_denial_count_also_fails(self):
        with self.assertRaises(IncompleteReview):
            validate_execution([{**self.result, "permission_denials_count": 1}])

    def test_old_head_run_or_attempt_does_not_count(self):
        for replacement in ("def456:100:1", "abc123:99:1", "abc123:100:2"):
            self.comment["body"] = f"A previous review completed with no issues found.\n<!-- claude-review:{replacement} -->"
            with self.subTest(replacement=replacement), self.assertRaises(IncompleteReview):
                validate_publication(self.event, "100", "1", self.fetch)

    def test_other_author_cannot_supply_completion(self):
        self.comment["user"]["login"] = "someone-else"
        with self.assertRaises(IncompleteReview):
            validate_publication(self.event, "100", "1", self.fetch)

    def test_empty_summary_does_not_count(self):
        self.comment["body"] = "<!-- claude-review:abc123:100:1 -->"
        with self.assertRaises(IncompleteReview):
            validate_publication(self.event, "100", "1", self.fetch)

    def test_head_changed_while_reviewing(self):
        self.current["head"]["sha"] = "def456"
        with self.assertRaises(IncompleteReview):
            validate_publication(self.event, "100", "1", self.fetch)

    def test_closed_or_draft_pr_does_not_count(self):
        for changes in ({"state": "closed"}, {"draft": True}):
            self.current = {**self.current, **changes}
            with self.subTest(changes=changes), self.assertRaises(IncompleteReview):
                validate_publication(self.event, "100", "1", self.fetch)

    def test_missing_execution_fails_visibly(self):
        with tempfile.TemporaryDirectory() as directory:
            output = io.StringIO()
            summary = Path(directory) / "summary.md"
            with patch.dict(os.environ, {"RUNNER_TEMP": directory, "CLAUDE_EXECUTION_FILE": "",
                                         "GITHUB_STEP_SUMMARY": str(summary)}):
                with contextlib.redirect_stdout(output):
                    self.assertEqual(main(), 1)
            self.assertIn("::error::Claude review incomplete", output.getvalue())
            self.assertIn("Claude review incomplete", summary.read_text())

    def test_failure_summary_never_publishes_transcript_or_tool_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            execution = Path(directory) / "execution.json"
            summary = Path(directory) / "summary.md"
            denied = {**self.result, "permission_denials": [
                {"tool_name": "Bash", "tool_input": "SECRET_TOKEN"}
            ]}
            execution.write_text(json.dumps([
                {"type": "assistant", "message": "PRIVATE_TRANSCRIPT"}, denied
            ]))
            output = io.StringIO()
            with patch.dict(os.environ, {"CLAUDE_EXECUTION_FILE": str(execution),
                                         "GITHUB_STEP_SUMMARY": str(summary)}):
                with contextlib.redirect_stdout(output):
                    self.assertEqual(main(), 1)
            public_output = output.getvalue() + summary.read_text()
            self.assertIn("Denied tools: Bash", public_output)
            self.assertNotIn("SECRET_TOKEN", public_output)
            self.assertNotIn("PRIVATE_TRANSCRIPT", public_output)


if __name__ == "__main__":
    unittest.main()
