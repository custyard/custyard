import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from verify_claude_review import (
    IncompleteReview, denied_command_family, main, validate_execution, validate_publication,
)


class ReviewCompletionTest(unittest.TestCase):
    def setUp(self):
        self.result = {"type": "result", "subtype": "success", "is_error": False, "permission_denials": []}
        self.result["structured_output"] = {
            "review_completed": True, "reviewed_head_sha": "abc123", "blocking_reason": "none",
            "reviewed_files": ["lib/example.ex"],
        }
        self.event = {"repository": {"full_name": "custyard/custyard"},
                      "pull_request": {"number": 45, "head": {"sha": "abc123"}}}
        self.current = {"head": {"sha": "abc123"}, "state": "open", "draft": False}
        self.comment = {"user": {"login": "claude[bot]"},
                        "body": "Reviewed abc123. No issues found after checking the complete diff.\n"
                                "<!-- claude-review:abc123:100:1 -->",
                        "html_url": "https://github.com/custyard/custyard/pull/45#issuecomment-1"}

    def fetch(self, endpoint, paginate=False):
        if "/files?" in endpoint:
            return [[], [{"filename": "lib/example.ex"}]]
        if paginate:
            return [[], [self.comment]]
        return self.current

    def test_complete_execution_and_published_review(self):
        validate_execution([self.result])
        self.assertEqual(validate_publication(self.event, "100", "1", self.fetch, ["lib/example.ex"]), self.comment["html_url"])

    def test_missing_final_result_fails(self):
        for messages in (None, [], [{"type": "assistant"}], [self.result, self.result]):
            with self.subTest(messages=messages), self.assertRaises(IncompleteReview):
                validate_execution(messages)

    def test_unsuccessful_results_fail(self):
        for changes in ({"is_error": True}, {"subtype": "error_max_turns"}, {"is_error": None}):
            with self.subTest(changes=changes), self.assertRaises(IncompleteReview):
                validate_execution([{**self.result, **changes}])

    def test_recovered_permission_denials_are_recorded_without_exposing_inputs(self):
        denied = {**self.result, "permission_denials": [{"tool_name": "Bash", "tool_input": "SECRET_TOKEN"}]}
        report, diagnostic = validate_execution([denied])
        self.assertTrue(report["review_completed"])
        self.assertIn("Bash", diagnostic)
        self.assertNotIn("SECRET_TOKEN", diagnostic)

    def test_denial_count_is_also_recorded(self):
        _, diagnostic = validate_execution([{**self.result, "permission_denials_count": 1}])
        self.assertIn("permission denials", diagnostic)

    def test_missing_or_invalid_structured_result_fails(self):
        for report in (None, {}, {"review_completed": True, "blocking_reason": "SECRET_TOKEN"}):
            with self.subTest(report=report), self.assertRaises(IncompleteReview) as error:
                validate_execution([{**self.result, "structured_output": report}])
            self.assertNotIn("SECRET_TOKEN", str(error.exception))

    def test_explicit_incomplete_result_fails(self):
        report = {"review_completed": False, "reviewed_head_sha": "abc123", "blocking_reason": "publication_failed"}
        with self.assertRaisesRegex(IncompleteReview, "publication_failed"):
            validate_execution([{**self.result, "structured_output": report}])

    def test_completed_result_with_a_blocker_still_fails(self):
        report = {**self.result["structured_output"], "blocking_reason": "review_not_finished"}
        with self.assertRaises(IncompleteReview):
            validate_execution([{**self.result, "structured_output": report}])

    def test_invalid_reviewed_file_reports_fail(self):
        for files in (None, [], "lib/example.ex", [1], ["lib/example.ex", "lib/example.ex"]):
            report = {**self.result["structured_output"], "reviewed_files": files}
            with self.subTest(files=files), self.assertRaises(IncompleteReview):
                validate_execution([{**self.result, "structured_output": report}])

    def test_partial_review_cannot_pass_with_a_valid_completion_comment(self):
        def fetch(endpoint, paginate=False):
            if "/files?" in endpoint:
                return [[{"filename": "lib/example.ex"}], [{"filename": "priv/repo/migrations/example.exs"}]]
            return self.fetch(endpoint, paginate)

        with self.assertRaisesRegex(IncompleteReview, "1 of 2 changed files"):
            validate_publication(self.event, "100", "1", fetch, ["lib/example.ex"])

    def test_unexpected_reviewed_paths_fail(self):
        with self.assertRaisesRegex(IncompleteReview, "unexpected paths"):
            validate_publication(self.event, "100", "1", self.fetch, ["lib/example.ex", "other.ex"])

    def test_command_diagnostics_only_publish_known_command_families(self):
        for command, expected in (
            ("gh api repos/private/repository/pulls/45 -H 'Authorization: SECRET'", "gh api"),
            ("gh pr view 45 --json body", "gh pr view"),
            ("echo SECRET_TOKEN", "echo"),
            ("SECRET_TOKEN=private gh pr view 45", "unrecognized shell command"),
            ("/private/SECRET_TOKEN", "unrecognized shell command"),
            ("gh api 'unterminated SECRET_TOKEN", "unrecognized shell command"),
        ):
            with self.subTest(command=command):
                denial = {"tool_name": "Bash", "tool_input": {"command": command}}
                self.assertEqual(denied_command_family(denial), expected)

    def test_old_head_run_or_attempt_does_not_count(self):
        for replacement in ("def456:100:1", "abc123:99:1", "abc123:100:2"):
            self.comment["body"] = f"A previous review completed with no issues found.\n<!-- claude-review:{replacement} -->"
            with self.subTest(replacement=replacement), self.assertRaises(IncompleteReview):
                validate_publication(self.event, "100", "1", self.fetch, ["lib/example.ex"])

    def test_other_author_cannot_supply_completion(self):
        self.comment["user"]["login"] = "someone-else"
        with self.assertRaises(IncompleteReview):
            validate_publication(self.event, "100", "1", self.fetch, ["lib/example.ex"])

    def test_empty_summary_does_not_count(self):
        self.comment["body"] = "<!-- claude-review:abc123:100:1 -->"
        with self.assertRaises(IncompleteReview):
            validate_publication(self.event, "100", "1", self.fetch, ["lib/example.ex"])

    def test_head_changed_while_reviewing(self):
        self.current["head"]["sha"] = "def456"
        with self.assertRaises(IncompleteReview):
            validate_publication(self.event, "100", "1", self.fetch, ["lib/example.ex"])

    def test_closed_or_draft_pr_does_not_count(self):
        for changes in ({"state": "closed"}, {"draft": True}):
            self.current = {**self.current, **changes}
            with self.subTest(changes=changes), self.assertRaises(IncompleteReview):
                validate_publication(self.event, "100", "1", self.fetch, ["lib/example.ex"])

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

    def test_structured_result_must_match_the_event_head(self):
        with tempfile.TemporaryDirectory() as directory:
            execution = Path(directory) / "execution.json"
            event = Path(directory) / "event.json"
            execution.write_text(json.dumps([self.result]))
            event.write_text(json.dumps({**self.event, "pull_request": {"head": {"sha": "def456"}}}))
            with patch.dict(os.environ, {"CLAUDE_EXECUTION_FILE": str(execution),
                                         "GITHUB_EVENT_PATH": str(event), "GITHUB_STEP_SUMMARY": ""}):
                with patch("verify_claude_review.github_fetch") as fetch:
                    with contextlib.redirect_stdout(io.StringIO()) as output:
                        self.assertEqual(main(), 1)
                    fetch.assert_not_called()
            self.assertIn("different PR head", output.getvalue())

    def test_failure_summary_never_publishes_transcript_or_tool_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            execution = Path(directory) / "execution.json"
            summary = Path(directory) / "summary.md"
            denied = {**self.result, "permission_denials": [
                {"tool_name": "Bash", "tool_input": "SECRET_TOKEN"}
            ], "structured_output": {"review_completed": False, "blocking_reason": "permission_denied"}}
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

    def test_complete_published_review_with_recovered_denials_warns(self):
        with tempfile.TemporaryDirectory() as directory:
            execution = Path(directory) / "execution.json"
            event = Path(directory) / "event.json"
            summary = Path(directory) / "summary.md"
            execution.write_text(json.dumps([{**self.result, "permission_denials_count": 1}]))
            event.write_text(json.dumps(self.event))
            output = io.StringIO()
            with patch.dict(os.environ, {"CLAUDE_EXECUTION_FILE": str(execution),
                                         "GITHUB_EVENT_PATH": str(event), "GITHUB_STEP_SUMMARY": str(summary),
                                         "GITHUB_RUN_ID": "100", "GITHUB_RUN_ATTEMPT": "1"}):
                with patch("verify_claude_review.github_fetch", side_effect=self.fetch):
                    with contextlib.redirect_stdout(output):
                        self.assertEqual(main(), 0)
            self.assertIn("::warning::", output.getvalue())
            self.assertIn("completed and published", output.getvalue())
            self.assertIn("Tool warnings:", summary.read_text())

    def test_recovered_denials_do_not_excuse_missing_publication(self):
        self.comment["body"] = "No completion marker was posted."
        _, diagnostic = validate_execution([{**self.result, "permission_denials_count": 1}])
        self.assertTrue(diagnostic)
        with self.assertRaises(IncompleteReview):
            validate_publication(self.event, "100", "1", self.fetch, ["lib/example.ex"])


if __name__ == "__main__":
    unittest.main()
