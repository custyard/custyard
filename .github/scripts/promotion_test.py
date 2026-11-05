import hashlib
import contextlib
import io
import json
import os
import unittest
from unittest.mock import MagicMock, patch

import promotion


class PromotionTest(unittest.TestCase):
    sha = "a" * 40
    digest = "sha256:" + "b" * 64
    previous = "sha256:" + "c" * 64

    def inputs(self, **overrides):
        values = dict(environment="production", digest=self.digest, source_sha=self.sha,
                      previous_digest=self.previous, acceptance_record="https://github.com/custyard/custyard/issues/1",
                      health_url="https://custyard.com/api/health")
        values.update(overrides)
        return values

    def test_accepts_digest_pinned_production_and_initial_staging(self):
        promotion.validate_inputs(**self.inputs())
        promotion.validate_inputs(**self.inputs(environment="staging", previous_digest="", acceptance_record=""))

    def test_rejects_missing_production_rollback_or_acceptance_record(self):
        for value in [dict(previous_digest=""), dict(acceptance_record="")]:
            with self.subTest(value=value), self.assertRaises(promotion.ValidationError):
                promotion.validate_inputs(**self.inputs(**value))

    def test_rejects_tags_shell_fragments_and_credentials_in_urls(self):
        for value in [dict(digest="latest"), dict(digest=self.digest + "\nextra=value"),
                      dict(source_sha="$(touch /tmp/injected)"),
                      dict(acceptance_record="https://user:secret@example.com/record"),
                      dict(health_url="https://example.com/api/health?token=secret"),
                      dict(health_url="http://example.com/api/health")]:
            with self.subTest(value=value), self.assertRaises(promotion.ValidationError):
                promotion.validate_inputs(**self.inputs(**value))

    def test_production_requires_reviewer_and_branch_protections(self):
        with patch.object(promotion, "github", return_value={"deployment_branch_policy": {"protected_branches": True}, "protection_rules": []}):
            with self.assertRaisesRegex(promotion.ValidationError, "required reviewers"):
                promotion.validate_environment("production")
        with patch.object(promotion, "github", return_value={"deployment_branch_policy": None}):
            with self.assertRaisesRegex(promotion.ValidationError, "restrict deployments"):
                promotion.validate_environment("staging")

    def test_explicit_main_branch_policy_is_accepted_but_wildcards_are_not(self):
        config = {"deployment_branch_policy": {"custom_branch_policies": True},
                  "protection_rules": [{"type": "required_reviewers", "reviewers": [{"type": "User"}]}]}
        with patch.object(promotion, "github", side_effect=[config, {"branch_policies": [{"name": "main", "type": "branch"}]}]):
            promotion.validate_environment("production")
        with patch.object(promotion, "github", side_effect=[config, {"branch_policies": [{"name": "*", "type": "branch"}]}]):
            with self.assertRaises(promotion.ValidationError):
                promotion.validate_environment("production")

    def test_successful_run_must_match_source_main_push_and_publish_job(self):
        run = {"id": 123, "head_sha": self.sha, "head_branch": "main", "event": "push",
               "status": "completed", "conclusion": "success", "html_url": "https://github.com/custyard/custyard/actions/runs/123"}
        jobs = [{"name": name, "conclusion": "success"} for name in ["test", "turso (turso)", "turso (bunny)", "release", "security", "publish"]]
        with patch.object(promotion, "github", side_effect=[{"workflow_runs": [run]}, {"jobs": jobs}]):
            self.assertEqual(promotion.validate_ci(self.sha), run["html_url"])
        with patch.object(promotion, "github", side_effect=[{"workflow_runs": [run]}, {"jobs": jobs[:-1]}]):
            with self.assertRaisesRegex(promotion.ValidationError, "release/publish gates"):
                promotion.validate_ci(self.sha)
        for incomplete in [jobs[:2] + jobs[3:], [job for job in jobs if not job["name"].startswith("turso")] + [{"name": "turso", "conclusion": "success"}]]:
            with patch.object(promotion, "github", side_effect=[{"workflow_runs": [run]}, {"jobs": incomplete}]):
                with self.assertRaises(promotion.ValidationError):
                    promotion.validate_ci(self.sha)
        for field, value in [("event", "pull_request"), ("head_sha", "d" * 40), ("head_branch", "feature")]:
            with patch.object(promotion, "github", return_value={"workflow_runs": [dict(run, **{field: value})]}):
                with self.assertRaises(promotion.ValidationError):
                    promotion.validate_ci(self.sha)

    def test_registry_metadata_is_hash_checked(self):
        body = b'{"key":"value"}'
        digest = "sha256:" + hashlib.sha256(body).hexdigest()
        self.assertEqual(promotion.verify_hash(body, digest), {"key": "value"})
        with self.assertRaisesRegex(promotion.ValidationError, "does not match"):
            promotion.verify_hash(body + b" ", digest)

    def image_fixture(self, revision=None, architecture="amd64"):
        records = {}

        def record(kind, value):
            body = json.dumps(value, separators=(",", ":")).encode()
            digest = "sha256:" + hashlib.sha256(body).hexdigest()
            records[f"https://ghcr.io/v2/custyard/custyard/{kind}/{digest}"] = body
            return digest

        config_digest = record("blobs", {"architecture": architecture, "os": "linux", "config": {"Labels": {
            "org.opencontainers.image.revision": revision or self.sha,
            "org.opencontainers.image.source": "https://github.com/custyard/custyard"}}})
        manifest_digest = record("manifests", {"config": {"digest": config_digest}})
        digest = record("manifests", {"manifests": [{"digest": manifest_digest, "platform": {"os": "linux", "architecture": architecture}}]})
        records["https://ghcr.io/token?service=ghcr.io&scope=repository:custyard/custyard:pull"] = b'{"token":"test"}'
        return digest, records

    def test_verifies_index_child_manifest_and_config_revision(self):
        digest, records = self.image_fixture()
        with patch.dict(os.environ, {"GITHUB_ACTOR": "test", "GITHUB_TOKEN": "test"}), \
                patch.object(promotion, "read_bytes", side_effect=lambda url, headers: records[url]):
            promotion.validate_image(digest, self.sha)

    def test_wrong_revision_or_architecture_cannot_be_promoted(self):
        for fixture in [dict(revision="d" * 40), dict(architecture="arm64")]:
            digest, records = self.image_fixture(**fixture)
            with patch.dict(os.environ, {"GITHUB_ACTOR": "test", "GITHUB_TOKEN": "test"}), \
                    patch.object(promotion, "read_bytes", side_effect=lambda url, headers: records[url]), \
                    self.assertRaises(promotion.ValidationError):
                promotion.validate_image(digest, self.sha)

    def test_previous_digest_is_checked_against_bunny_before_update(self):
        with patch.object(promotion, "bunny_container", return_value={"imageDigest": self.previous}):
            promotion.validate_bunny_previous(self.previous)
            with self.assertRaisesRegex(promotion.ValidationError, "differs"):
                promotion.validate_bunny_previous(self.digest)

    def test_bunny_patch_contains_only_image_fields_and_rechecks_the_previous_digest(self):
        container = {"id": "container-1", "imageDigest": self.previous,
                     "environmentVariables": [{"name": "PRIVATE_KEY", "value": "runtime-secret"}]}
        with patch.dict(os.environ, {"BUNNY_APP_ID": "app-1", "BUNNYNET_API_KEY": "test-key"}), \
                patch.object(promotion, "bunny_container", return_value=container), \
                patch.object(promotion, "read_bytes") as request:
            promotion.update_bunny(self.digest, self.sha, self.previous)
            call = request.call_args
            self.assertEqual(call.args[0], "https://api.bunny.net/mc/apps/app-1/containers/container-1")
            self.assertEqual(call.kwargs["method"], "PATCH")
            self.assertEqual(json.loads(call.kwargs["data"]), {
                "id": "container-1", "imageTag": "sha-" + self.sha,
                "imageName": "custyard", "imageDigest": self.digest})
            self.assertNotIn(b"runtime-secret", call.kwargs["data"])
            request.reset_mock()
            with self.assertRaises(promotion.ValidationError):
                promotion.update_bunny(self.digest, self.sha, self.digest)
            request.assert_not_called()

    def test_patch_success_does_not_read_the_returned_application_configuration(self):
        response = MagicMock()
        response.__enter__.return_value.status = 200
        opener = MagicMock()
        opener.open.return_value = response
        with patch.object(promotion.urllib.request, "build_opener", return_value=opener):
            self.assertEqual(promotion.read_bytes("https://api.bunny.net/mc/apps/app-1/containers/c-1",
                                                {"AccessKey": "test"}, method="PATCH", data=b"{}"), b"")
        response.__enter__.return_value.read.assert_not_called()

    def test_cli_never_prints_parser_error_bodies_or_request_exceptions(self):
        for error in [json.JSONDecodeError("runtime-secret", "runtime-secret", 0),
                      ValueError("AccessKey=request-secret"),
                      OSError("https://storage.invalid/?signed=secret")]:
            output = io.StringIO()
            with patch.object(promotion, "main", side_effect=error), contextlib.redirect_stderr(output):
                self.assertEqual(promotion.cli(), 1)
            self.assertNotIn("runtime-secret", output.getvalue())
            self.assertNotIn("request-secret", output.getvalue())
            self.assertNotIn("signed=secret", output.getvalue())

    def test_registry_redirects_do_not_forward_authorization_to_storage(self):
        redirect = promotion.urllib.error.HTTPError("https://ghcr.io/blob", 307, "redirect",
                                                    {"Location": "https://storage.example.com/signed-blob"}, None)
        response = MagicMock()
        response.__enter__.return_value.read.return_value = b"blob"
        opener = MagicMock()
        opener.open.side_effect = [redirect, response]
        with patch.object(promotion.urllib.request, "build_opener", return_value=opener):
            self.assertEqual(promotion.read_bytes("https://ghcr.io/blob", {"Authorization": "Bearer private-token"}), b"blob")
        source_request, destination_request = [call.args[0] for call in opener.open.call_args_list]
        self.assertEqual(source_request.get_header("Authorization"), "Bearer private-token")
        self.assertIsNone(destination_request.get_header("Authorization"))

    def test_health_requires_all_reported_checks_to_succeed(self):
        promotion.validate_health(b'{"status":"ok","checks":{"database":"ok","pubsub":"ok","scheduler":"ok","task_supervisor":"ok"}}')
        for body in [b'{}', b'{"status":"ok","checks":{}}', b'{"status":"ok","checks":{"unrelated":"ok"}}',
                     b'{"status":"ok","checks":{"database":"ok","pubsub":"ok"}}',
                     b'{"status":"ok","checks":{"database":"error","pubsub":"ok","scheduler":"ok","task_supervisor":"ok"}}']:
            with self.assertRaises(promotion.ValidationError):
                promotion.validate_health(body)


if __name__ == "__main__":
    unittest.main()
