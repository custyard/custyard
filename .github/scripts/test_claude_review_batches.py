import base64
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from verify_claude_review import (
    IncompleteReview, batch_command, build_plan, combine_results, load_missing_markdown_sources,
    validate_plan_context, verify_shard,
)


class BoundedReviewTest(unittest.TestCase):
    def setUp(self):
        self.event = {"repository": {"full_name": "custyard/custyard"},
                      "pull_request": {"number": 45, "head": {"sha": "abc123"}}}
        self.files = [{"filename": f"lib/file-{i}.ex", "patch": "small"} for i in range(31)]
        self.current = {"head": {"sha": "abc123"}, "state": "open", "draft": False,
                        "changed_files": len(self.files), "title": "Example", "body": "Review this change."}
        self.plan = build_plan(self.event, "100", "1", self.current, self.files)

    def execution(self, shard):
        return [{"type": "result", "subtype": "success", "is_error": False, "permission_denials": [],
                 "structured_output": {"review_completed": True, "reviewed_head_sha": "abc123",
                                       "blocking_reason": "none", "summary": "No additional issues found.",
                                       "reviewed_files": [f["filename"] for f in shard["files"]]}}]

    def receipts(self):
        return [verify_shard(self.execution(s), self.plan, s["id"]) for s in self.plan["shards"]]

    def test_every_file_is_assigned_once_with_bounded_counts(self):
        assigned = [f["filename"] for s in self.plan["shards"] for f in s["files"]]
        self.assertEqual(assigned, self.plan["files"])
        self.assertEqual(len(assigned), len(set(assigned)))
        self.assertTrue(all(len(s["files"]) <= 5 for s in self.plan["shards"]))

    def test_patch_size_also_bounds_batches_and_keeps_large_single_files(self):
        files = [{"filename": str(i), "patch": "x" * size}
                 for i, size in enumerate([70_000, 40_000, 150_000, 1])]
        plan = build_plan(self.event, "100", "1", {**self.current, "changed_files": 4}, files)
        self.assertEqual([len(s["files"]) for s in plan["shards"]], [1, 1, 1, 1])

    def test_patch_line_count_bounds_reader_input(self):
        files = [{"filename": str(i), "patch": "short\n" * count}
                 for i, count in enumerate([500, 400, 900, 1])]
        plan = build_plan(self.event, "100", "1", {**self.current, "changed_files": 4}, files)
        self.assertEqual([len(s["files"]) for s in plan["shards"]], [1, 1, 1, 1])

    def test_incomplete_api_file_list_cannot_become_a_plan(self):
        with self.assertRaises(IncompleteReview):
            build_plan(self.event, "100", "1", self.current, self.files[:2])

    def test_stale_or_draft_pr_cannot_be_planned(self):
        for changes in ({"head": {"sha": "wrong"}}, {"draft": True}, {"state": "closed"}):
            with self.subTest(changes=changes), self.assertRaises(IncompleteReview):
                build_plan(self.event, "100", "1", {**self.current, **changes}, self.files)

    def test_duplicate_paths_cannot_be_planned(self):
        with self.assertRaises(IncompleteReview):
            build_plan(self.event, "100", "1", {**self.current, "changed_files": 2}, [self.files[0]] * 2)

    def test_artifacts_cannot_be_replayed_from_another_run_or_attempt(self):
        validate_plan_context(self.plan, self.event, "100", "1")
        for key in ("head", "run_id", "attempt", "repository", "number"):
            altered = {**self.plan, key: "different"}
            with self.subTest(key=key), self.assertRaises(IncompleteReview):
                validate_plan_context(altered, self.event, "100", "1")

    def test_shard_requires_exact_assigned_coverage(self):
        execution = self.execution(self.plan["shards"][0])
        execution[0]["structured_output"]["reviewed_files"].pop()
        with self.assertRaises(IncompleteReview):
            verify_shard(execution, self.plan, 0)

    def test_shard_requires_the_expected_head_and_a_summary(self):
        for changes in ({"reviewed_head_sha": "wrong"}, {"summary": ""}, {"summary": "x" * 3001}):
            execution = self.execution(self.plan["shards"][0])
            execution[0]["structured_output"].update(changes)
            with self.subTest(changes=changes), self.assertRaises(IncompleteReview):
                verify_shard(execution, self.plan, 0)

    def test_complete_receipts_cover_the_entire_pr(self):
        reviewed, summaries, errors = combine_results(self.plan, self.receipts())
        self.assertEqual(reviewed, set(self.plan["files"]))
        self.assertEqual(len(summaries), 7)
        self.assertEqual(errors, [])

    def test_missing_failed_and_partial_receipts_stay_incomplete(self):
        for mode in ("missing", "failed", "partial"):
            receipts = self.receipts()
            if mode == "missing":
                receipts.pop()
            elif mode == "failed":
                receipts[-1]["verified"] = False
            else:
                receipts[-1]["files"] = []
            with self.subTest(mode=mode):
                reviewed, _, errors = combine_results(self.plan, receipts)
                self.assertTrue(errors)
                self.assertNotEqual(reviewed, set(self.plan["files"]))

    def test_duplicate_unknown_and_stale_receipts_fail_closed(self):
        for mode in ("duplicate", "unknown", "stale"):
            receipts = self.receipts()
            if mode == "duplicate":
                receipts.append(copy.deepcopy(receipts[0]))
            elif mode == "unknown":
                receipts[0]["shard"] = 99
            else:
                receipts[0]["attempt"] = "2"
            with self.subTest(mode=mode), self.assertRaises(IncompleteReview):
                combine_results(self.plan, receipts)

    def local_context(self, directory):
        root = Path(directory)
        (root / "event.json").write_text(json.dumps(self.event))
        plan_dir, result_dir = root / "plan", root / "results"
        plan_dir.mkdir()
        result_dir.mkdir()
        (plan_dir / "manifest.json").write_text(json.dumps(self.plan))
        for receipt in self.receipts():
            (result_dir / f"result-{receipt['shard']}.json").write_text(json.dumps(receipt))
        return {"GITHUB_EVENT_PATH": str(root / "event.json"), "GITHUB_RUN_ID": "100",
                "GITHUB_RUN_ATTEMPT": "1", "REVIEW_PLAN_DIR": str(plan_dir),
                "REVIEW_RESULT_DIR": str(result_dir), "REVIEW_JOBS_RESULT": "success",
                "GITHUB_STEP_SUMMARY": str(root / "summary.md"), "GITHUB_OUTPUT": str(root / "output")}

    def fetch(self, endpoint, paginate=False):
        if "/files?" in endpoint:
            return [self.files[:20], self.files[20:]]
        if "/comments?" in endpoint:
            return [[{"user": {"login": "github-actions[bot]"},
                      "body": "Reviewed all changed files and published the combined report.\n"
                              "<!-- claude-review:abc123:100:1 -->", "html_url": "https://example.test/comment"}]]
        return self.current

    def test_plan_command_writes_matrix_and_per_shard_patches(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.local_context(directory)
            with patch.dict(os.environ, env), patch("verify_claude_review.github_fetch", side_effect=self.fetch):
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(batch_command("plan"), 0)
            matrix = json.loads(Path(env["GITHUB_OUTPUT"]).read_text().split("=", 1)[1])
            self.assertEqual(len(matrix["include"]), 7)
            assigned = json.loads((Path(env["REVIEW_PLAN_DIR"]) / "shard-0.json").read_text())
            self.assertEqual(len(assigned["files"]), 5)
            self.assertNotIn("shards", assigned)
            self.assertEqual(assigned["assigned_paths"], [f["filename"] for f in self.files[:5]])
            self.assertEqual(assigned["files"][0]["patch_lines"], ["small"])

    def test_multiline_patches_remain_readable_without_one_long_escaped_line(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.local_context(directory)
            self.files[0]["patch"] = "@@ -1 +1 @@\n-old\n+new\n" * 100
            with patch.dict(os.environ, env), patch("verify_claude_review.github_fetch", side_effect=self.fetch):
                with contextlib.redirect_stdout(io.StringIO()):
                    batch_command("plan")
            raw = (Path(env["REVIEW_PLAN_DIR"]) / "shard-0.json").read_text()
            assigned = json.loads(raw)
            self.assertEqual(assigned["files"][0]["patch_lines"], self.files[0]["patch"].splitlines())
            self.assertLess(max(map(len, raw.splitlines())), 200)
            self.assertLess(raw.index('"assigned_paths"'), raw.index('"patch_lines"'))

    def test_failed_shard_retains_no_raw_output_or_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.local_context(directory)
            execution = Path(directory) / "sdk.json"
            execution.write_text(json.dumps([{"type": "assistant", "message": "SECRET_TRANSCRIPT"}]))
            env.update(REVIEW_SHARD="0", CLAUDE_EXECUTION_FILE=str(execution))
            with patch.dict(os.environ, env), self.assertRaises(IncompleteReview):
                batch_command("shard")
            receipt = (Path(env["REVIEW_RESULT_DIR"]) / "result-0.json").read_text()
            self.assertNotIn("SECRET_TRANSCRIPT", receipt)
            self.assertFalse(json.loads(receipt)["verified"])

    def test_review_input_preserves_readable_unicode_and_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.local_context(directory)
            marked = "+C\U000E0101a\U000E0101f\U000E0101é — 返信"
            self.files[0]["patch"] = marked
            with patch.dict(os.environ, env), patch("verify_claude_review.github_fetch", side_effect=self.fetch):
                with contextlib.redirect_stdout(io.StringIO()):
                    batch_command("plan")
            raw = (Path(env["REVIEW_PLAN_DIR"]) / "shard-0.json").read_text(encoding="utf-8")
            self.assertIn(marked, raw)
            self.assertNotIn("\\udb40", raw)
            self.assertEqual(json.loads(raw)["files"][0]["patch_lines"], [marked])
            self.assertIn("TextProv", json.loads(raw)["provenance_note"])

    def test_markdown_reading_view_keeps_exact_attribution_in_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.local_context(directory)
            marked = "+H\U000E0100i\U000E0101 — 返信\U000E0102"
            self.files[0].update(filename="README.md", patch=marked)
            with patch.dict(os.environ, env), patch("verify_claude_review.github_fetch", side_effect=self.fetch):
                with contextlib.redirect_stdout(io.StringIO()):
                    batch_command("plan")
            root = Path(env["REVIEW_PLAN_DIR"])
            view = json.loads((root / "shard-0.json").read_text(encoding="utf-8"))
            manifest = json.loads((root / "manifest.json").read_text())
            self.assertEqual(view["files"][0]["patch_lines"], ["+Hi — 返信\U000E0102"])
            self.assertEqual(manifest["shards"][0]["files"][0]["patch"], marked)
            self.assertEqual(self.files[0]["patch"], marked)

    def test_missing_markdown_patch_receives_complete_blob_reading_view(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.local_context(directory)
            marked = "# R\U000E0101esearch\n\nThe complete document.\n"
            self.files[0].update(filename="docs/research.md", patch=None, sha="blob-sha")
            def fetch(endpoint, paginate=False):
                if "/git/blobs/" in endpoint:
                    self.assertEqual(endpoint, "repos/custyard/custyard/git/blobs/blob-sha")
                    return {"encoding": "base64", "content": base64.b64encode(marked.encode()).decode()}
                return self.fetch(endpoint, paginate)
            with patch.dict(os.environ, env), patch("verify_claude_review.github_fetch", side_effect=fetch):
                with contextlib.redirect_stdout(io.StringIO()):
                    batch_command("plan")
            root = Path(env["REVIEW_PLAN_DIR"])
            view = json.loads((root / "shard-0.json").read_text())
            manifest = json.loads((root / "manifest.json").read_text())
            self.assertFalse(view["files"][0]["patch_available"])
            self.assertEqual(view["files"][0]["source_lines"], ["# Research", "", "The complete document."])
            self.assertEqual(manifest["shards"][0]["files"][0]["source_text"], marked)
            self.assertNotIn("source_text", self.files[0])

    def test_missing_patch_fallback_does_not_fetch_binary_or_code_files(self):
        files = [{"filename": "image.png"}, {"filename": "module.ex"}]
        with patch("verify_claude_review.github_fetch") as fetch:
            self.assertEqual(load_missing_markdown_sources("custyard/custyard", files, fetch), files)
            fetch.assert_not_called()

    def test_unreadable_markdown_source_fails_planning(self):
        for blob in ({"encoding": "none", "content": ""},
                     {"encoding": "base64", "content": "not valid base64!"},
                     {"encoding": "base64", "content": "/w=="}):
            with self.subTest(blob=blob), self.assertRaises(IncompleteReview):
                load_missing_markdown_sources("custyard/custyard", [{"filename": "README.md", "sha": "sha"}],
                                             lambda endpoint: blob)

    def test_incomplete_review_explanation_is_retained_without_transcript(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.local_context(directory)
            messages = self.execution(self.plan["shards"][0])
            messages[0]["structured_output"].update(
                review_completed=False, blocking_reason="review_not_finished",
                summary="The assigned README patch could not be read completely.")
            messages.insert(0, {"type": "assistant", "message": "SECRET_TRANSCRIPT"})
            execution = Path(directory) / "sdk.json"
            execution.write_text(json.dumps(messages))
            env.update(REVIEW_SHARD="0", CLAUDE_EXECUTION_FILE=str(execution))
            with patch.dict(os.environ, env), self.assertRaises(IncompleteReview):
                batch_command("shard")
            raw = (Path(env["REVIEW_RESULT_DIR"]) / "result-0.json").read_text()
            self.assertNotIn("SECRET_TRANSCRIPT", raw)
            receipt = json.loads(raw)
            receipts = self.receipts()
            receipts[0] = receipt
            _, _, errors = combine_results(self.plan, receipts)
            self.assertTrue(any("README patch could not be read completely" in e for e in errors))

    def test_sdk_error_cannot_publish_a_provider_error_as_a_blocker_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.local_context(directory)
            messages = self.execution(self.plan["shards"][0])
            messages[0].update(is_error=True, subtype="error_during_execution")
            messages[0]["structured_output"]["summary"] = "SECRET_PROVIDER_ERROR"
            execution = Path(directory) / "sdk.json"
            execution.write_text(json.dumps(messages))
            env.update(REVIEW_SHARD="0", CLAUDE_EXECUTION_FILE=str(execution))
            with patch.dict(os.environ, env), self.assertRaises(IncompleteReview):
                batch_command("shard")
            raw = (Path(env["REVIEW_RESULT_DIR"]) / "result-0.json").read_text()
            self.assertNotIn("SECRET_PROVIDER_ERROR", raw)
            self.assertNotIn("blocker_summary", json.loads(raw))

    def test_complete_workflow_publishes_and_verifies_one_combined_comment(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.local_context(directory)
            with patch.dict(os.environ, env), patch("verify_claude_review.github_fetch", side_effect=self.fetch):
                with patch("verify_claude_review.github_post", return_value={"html_url": "https://example.test/comment"}) as post:
                    with contextlib.redirect_stdout(io.StringIO()):
                        self.assertEqual(batch_command("publish"), 0)
                    body = post.call_args.args[1]
            self.assertIn("Completed: 31/31", body)
            self.assertIn("<!-- claude-review:abc123:100:1 -->", body)

    def test_missing_receipt_posts_incomplete_and_fails_without_a_success_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.local_context(directory)
            (Path(env["REVIEW_RESULT_DIR"]) / "result-6.json").unlink()
            with patch.dict(os.environ, env), patch("verify_claude_review.github_fetch", side_effect=self.fetch):
                with patch("verify_claude_review.github_post", return_value={"html_url": "https://example.test/comment"}) as post:
                    with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(IncompleteReview):
                        batch_command("publish")
                    body = post.call_args.args[1]
            self.assertIn("Incomplete: 30/31", body)
            self.assertNotIn("<!-- claude-review:abc123", body)

    def test_stale_pr_is_not_published(self):
        with tempfile.TemporaryDirectory() as directory:
            env = self.local_context(directory)
            self.current["head"]["sha"] = "new-head"
            with patch.dict(os.environ, env), patch("verify_claude_review.github_fetch", side_effect=self.fetch):
                with patch("verify_claude_review.github_post") as post, self.assertRaises(IncompleteReview):
                    batch_command("publish")
                post.assert_not_called()


if __name__ == "__main__":
    unittest.main()
