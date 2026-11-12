import contextlib
import hashlib
import io
import json
import os
import unittest
from unittest.mock import MagicMock, patch

import promotion

CONTEXT = {"CI_PROJECT_PATH": "custyard/custyard", "CI_COMMIT_BRANCH": "main",
           "CI_COMMIT_REF_PROTECTED": "true", "CI_PIPELINE_SOURCE": "web"}


class PromotionTest(unittest.TestCase):
    sha = "a" * 40
    digest = "sha256:" + "b" * 64
    previous = "sha256:" + "c" * 64

    def inputs(self, **overrides):
        values = dict(environment="production", digest=self.digest, source_sha=self.sha,
                      previous_digest=self.previous, acceptance_record="https://gitlab.com/custyard/custyard/-/issues/1",
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

    def test_only_manual_pipelines_on_protected_main_can_promote(self):
        with patch.dict(os.environ, CONTEXT):
            promotion.validate_pipeline_context()
        with patch.dict(os.environ, dict(CONTEXT, CI_PIPELINE_SOURCE="api")):
            promotion.validate_pipeline_context()
        for field, value in [("CI_PROJECT_PATH", "fork/custyard"), ("CI_COMMIT_BRANCH", "feature"),
                             ("CI_COMMIT_REF_PROTECTED", "false"), ("CI_PIPELINE_SOURCE", "push"),
                             ("CI_PIPELINE_SOURCE", "merge_request_event"), ("CI_PIPELINE_SOURCE", "schedule")]:
            with self.subTest(field=field, value=value), patch.dict(os.environ, dict(CONTEXT, **{field: value})), \
                    self.assertRaisesRegex(promotion.ValidationError, "protected main"):
                promotion.validate_pipeline_context()

    def pipeline(self, **overrides):
        return dict({"id": 123, "sha": self.sha, "ref": "main", "source": "push", "status": "success"}, **overrides)

    def jobs(self, publish=None):
        names = ["test", "turso: [turso]", "turso: [bunny]", "release", "security"]
        return [{"name": name, "status": "success"} for name in names] + [publish or self.publish_job()]

    def publish_job(self, **overrides):
        job = {"id": 456, "name": "publish", "status": "success", "ref": "main",
               "pipeline": {"id": 123, "sha": self.sha, "ref": "main"},
               "artifacts": [{"file_type": "archive", "size": 411, "filename": "published-image-123.zip"},
                             {"file_type": "trace", "size": 99999, "filename": "job.log"}]}
        job.update(overrides)
        return job

    def record(self, **overrides):
        value = {"version": 1, "repository": promotion.REPOSITORY, "image": promotion.IMAGE,
                 "source_sha": self.sha, "digest": self.digest, "pipeline_id": 123, "job_id": 456}
        value.update(overrides)
        return json.dumps(value).encode()

    def test_successful_pipeline_must_match_source_main_push_and_publish_job(self):
        with patch.object(promotion, "gitlab", side_effect=[[self.pipeline()], self.jobs()]) as api, \
                patch.object(promotion, "gitlab_bytes", return_value=self.record()) as download:
            self.assertEqual(promotion.validate_ci(self.sha, self.digest),
                             "https://gitlab.com/custyard/custyard/-/pipelines/123")
        self.assertIn("sha=" + self.sha, api.call_args_list[0].args[0])
        self.assertIn("source=push", api.call_args_list[0].args[0])
        self.assertEqual(api.call_args_list[1].args[0], "pipelines/123/jobs?per_page=100")
        download.assert_called_with("jobs/456/artifacts/published-image.json", limit=promotion.MAX_RECORD_SIZE)
        with patch.object(promotion, "gitlab", side_effect=[[self.pipeline()], self.jobs()]), \
                patch.object(promotion, "gitlab_bytes", return_value=self.record()), self.assertRaises(promotion.ValidationError):
            promotion.validate_ci(self.sha, self.previous)
        with patch.object(promotion, "gitlab", side_effect=[[self.pipeline()], self.jobs()[:-1]]):
            with self.assertRaisesRegex(promotion.ValidationError, "release/publish gates"):
                promotion.validate_ci(self.sha, self.digest)
        jobs = self.jobs()
        for incomplete in [jobs[:2] + jobs[3:], [job for job in jobs if not job["name"].startswith("turso")] + [{"name": "turso", "status": "success"}],
                           [dict(job, status="failed") if job["name"] == "security" else job for job in jobs]]:
            with patch.object(promotion, "gitlab", side_effect=[[self.pipeline()], incomplete]), \
                    patch.object(promotion, "gitlab_bytes") as download, self.assertRaises(promotion.ValidationError):
                promotion.validate_ci(self.sha, self.digest)
            download.assert_not_called()
        for field, value in [("source", "merge_request_event"), ("sha", "d" * 40), ("ref", "feature"), ("status", "failed")]:
            with patch.object(promotion, "gitlab", return_value=[self.pipeline(**{field: value})]):
                with self.assertRaises(promotion.ValidationError):
                    promotion.validate_ci(self.sha, self.digest)

    def test_a_later_rebuild_cannot_hide_an_older_matching_ci_publication(self):
        newer = self.pipeline(id=124)
        newer_jobs = self.jobs(self.publish_job(id=457, pipeline={"id": 124, "sha": self.sha, "ref": "main"}))
        with patch.object(promotion, "gitlab", side_effect=[[newer, self.pipeline()], newer_jobs, self.jobs()]), \
                patch.object(promotion, "gitlab_bytes", side_effect=[
                    self.record(digest=self.previous, pipeline_id=124, job_id=457), self.record()]):
            self.assertEqual(promotion.validate_ci(self.sha, self.digest),
                             "https://gitlab.com/custyard/custyard/-/pipelines/123")

    def test_ci_record_rejects_a_different_image_with_the_same_source_labels(self):
        with patch.object(promotion, "gitlab_bytes", return_value=self.record()):
            promotion.validate_published_record(123, self.publish_job(), self.sha, self.digest)
            with self.assertRaisesRegex(promotion.ValidationError, "Candidate digest does not match"):
                promotion.validate_published_record(123, self.publish_job(), self.sha, self.previous)

    def test_record_must_match_the_source_repository_image_pipeline_and_job(self):
        for field, value in [("version", True), ("repository", "other/repo"), ("image", "registry.gitlab.com/other/repo"),
                             ("source_sha", "d" * 40), ("pipeline_id", 124), ("job_id", 455), ("job_id", "456")]:
            with self.subTest(field=field, value=value), \
                    patch.object(promotion, "gitlab_bytes", return_value=self.record(**{field: value})), \
                    self.assertRaises(promotion.ValidationError):
                promotion.validate_published_record(123, self.publish_job(), self.sha, self.digest)

    def test_wrong_pipeline_failed_or_artifactless_publish_jobs_are_not_downloaded(self):
        for overrides in [{"status": "failed"}, {"name": "container"}, {"ref": "feature"}, {"id": "456"},
                          {"pipeline": {"id": 999, "sha": self.sha}}, {"pipeline": {"id": 123, "sha": "d" * 40}},
                          {"artifacts": []}, {"artifacts": None},
                          {"artifacts": [{"file_type": "archive", "size": promotion.MAX_RECORD_ARCHIVE + 1}]},
                          {"artifacts": [{"file_type": "archive", "size": 1}, {"file_type": "archive", "size": 1}]}]:
            with self.subTest(overrides=overrides), patch.object(promotion, "gitlab_bytes") as download, \
                    self.assertRaises(promotion.ValidationError):
                promotion.validate_published_record(123, self.publish_job(**overrides), self.sha, self.digest)
            download.assert_not_called()

    def test_malformed_records_are_rejected(self):
        for body in [b"not-json", b"[]", b'"text"', self.record()[:-1]]:
            with self.subTest(body=body), patch.object(promotion, "gitlab_bytes", return_value=body), \
                    self.assertRaises(promotion.ValidationError):
                promotion.validate_published_record(123, self.publish_job(), self.sha, self.digest)

    def test_registry_metadata_is_hash_checked(self):
        body = b'{"key":"value"}'
        digest = "sha256:" + hashlib.sha256(body).hexdigest()
        self.assertEqual(promotion.verify_hash(body, digest), {"key": "value"})
        with self.assertRaisesRegex(promotion.ValidationError, "does not match"):
            promotion.verify_hash(body + b" ", digest)

    def image_fixture(self, revision=None, architecture="amd64", source="https://gitlab.com/custyard/custyard"):
        records = {}

        def record(kind, value):
            body = json.dumps(value, separators=(",", ":")).encode()
            digest = "sha256:" + hashlib.sha256(body).hexdigest()
            records[f"https://registry.gitlab.com/v2/custyard/custyard/{kind}/{digest}"] = body
            return digest

        config_digest = record("blobs", {"architecture": architecture, "os": "linux", "config": {"Labels": {
            "org.opencontainers.image.revision": revision or self.sha,
            "org.opencontainers.image.source": source}}})
        manifest_digest = record("manifests", {"config": {"digest": config_digest}})
        attestation_digest = record("manifests", {"config": {"digest": "sha256:" + "e" * 64}})
        digest = record("manifests", {"manifests": [
            {"digest": manifest_digest, "platform": {"os": "linux", "architecture": architecture}},
            {"digest": attestation_digest, "platform": {"os": "unknown", "architecture": "unknown"}}]})
        records[promotion.REGISTRY_TOKEN_URL] = b'{"token":"test"}'
        return digest, records

    def test_verifies_index_child_manifest_and_config_revision(self):
        digest, records = self.image_fixture()
        requests = []

        def read(url, headers):
            requests.append((url, headers))
            return records[url]

        with patch.dict(os.environ, {"CI_JOB_TOKEN": "job-token"}), patch.object(promotion, "read_bytes", side_effect=read):
            promotion.validate_image(digest, self.sha)
        token_url, token_headers = requests[0]
        self.assertEqual(token_url, promotion.REGISTRY_TOKEN_URL)
        self.assertEqual(token_headers["Authorization"], "Basic Z2l0bGFiLWNpLXRva2VuOmpvYi10b2tlbg==")
        self.assertTrue(all(headers["Authorization"] == "Bearer test" for _, headers in requests[1:]))

    def test_registry_token_is_anonymous_without_a_job_token(self):
        with patch.dict(os.environ, {}, clear=True), \
                patch.object(promotion, "read_bytes", return_value=b'{"token":"anonymous"}') as read:
            self.assertEqual(promotion.registry_token(), "anonymous")
        self.assertEqual(read.call_args.args[1], {})
        with patch.object(promotion, "read_bytes", return_value=b'{}'), self.assertRaises(promotion.ValidationError):
            promotion.registry_token()

    def test_wrong_revision_architecture_or_source_cannot_be_promoted(self):
        for fixture in [dict(revision="d" * 40), dict(architecture="arm64"),
                        dict(source="https://github.com/custyard/custyard")]:
            digest, records = self.image_fixture(**fixture)
            with self.subTest(fixture=fixture), \
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

    def promotion_env(self, **overrides):
        values = dict(CONTEXT, PROMOTE_ENVIRONMENT="production", IMAGE_DIGEST=self.digest, SOURCE_SHA=self.sha,
                      PREVIOUS_DIGEST=self.previous, ACCEPTANCE_RECORD="https://gitlab.com/custyard/custyard/-/issues/1",
                      HEALTHCHECK_URL="https://custyard.com/api/health")
        values.update(overrides)
        return values

    def test_production_update_runs_only_from_a_manually_started_job(self):
        for manual in [None, "false"]:
            env = self.promotion_env() if manual is None else self.promotion_env(CI_JOB_MANUAL=manual)
            with self.subTest(manual=manual), patch.dict(os.environ, env, clear=True), \
                    patch("sys.argv", ["promotion.py", "update-bunny"]), \
                    patch.object(promotion, "update_bunny") as update, \
                    self.assertRaisesRegex(promotion.ValidationError, "started by hand"):
                promotion.main()
            update.assert_not_called()
        with patch.dict(os.environ, self.promotion_env(CI_JOB_MANUAL="true"), clear=True), \
                patch("sys.argv", ["promotion.py", "update-bunny"]), \
                patch.object(promotion, "update_bunny") as update:
            promotion.main()
        update.assert_called_once_with(self.digest, self.sha, self.previous)

    def test_validate_writes_the_verified_reference_for_the_deploy_job(self):
        with patch.dict(os.environ, self.promotion_env(), clear=True), \
                patch("sys.argv", ["promotion.py", "validate"]), \
                patch.object(promotion, "validate_ci", return_value="https://gitlab.com/custyard/custyard/-/pipelines/123"), \
                patch.object(promotion, "validate_image"), patch.object(promotion, "validate_bunny_previous") as previous, \
                patch.object(promotion, "Path") as path, contextlib.redirect_stdout(io.StringIO()):
            promotion.main()
        previous.assert_called_once_with(self.previous)
        path.assert_called_once_with(promotion.DOTENV_FILE)
        self.assertEqual(path.return_value.write_text.call_args.args[0],
                         f"IMAGE_REFERENCE=registry.gitlab.com/custyard/custyard@{self.digest}\n"
                         f"IMAGE_TAG=sha-{self.sha}\nENVIRONMENT_URL=https://custyard.com\n")

    def test_commands_refuse_to_run_outside_protected_main(self):
        for command in ["validate", "update-bunny", "verify-bunny", "wait-healthy"]:
            with self.subTest(command=command), \
                    patch.dict(os.environ, self.promotion_env(CI_COMMIT_REF_PROTECTED="false", CI_JOB_MANUAL="true"), clear=True), \
                    patch("sys.argv", ["promotion.py", command]), \
                    patch.object(promotion, "read_bytes") as request, \
                    self.assertRaisesRegex(promotion.ValidationError, "protected main"):
                promotion.main()
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
        redirect = promotion.urllib.error.HTTPError("https://registry.gitlab.com/blob", 307, "redirect",
                                                    {"Location": "https://storage.example.com/signed-blob"}, None)
        response = MagicMock()
        response.__enter__.return_value.read.return_value = b"blob"
        opener = MagicMock()
        opener.open.side_effect = [redirect, response]
        with patch.object(promotion.urllib.request, "build_opener", return_value=opener):
            self.assertEqual(promotion.read_bytes("https://registry.gitlab.com/blob", {"Authorization": "Bearer private-token"}), b"blob")
        source_request, destination_request = [call.args[0] for call in opener.open.call_args_list]
        self.assertEqual(source_request.get_header("Authorization"), "Bearer private-token")
        self.assertIsNone(destination_request.get_header("Authorization"))

    def test_api_redirect_drops_token_and_preserves_the_download_bound(self):
        redirect = promotion.urllib.error.HTTPError("https://gitlab.com/api/v4/artifact", 302, "redirect",
                                                    {"Location": "https://storage.example.com/archive?signature=private"}, None)
        response = MagicMock()
        response.__enter__.return_value.read.return_value = b"record"
        opener = MagicMock()
        opener.open.side_effect = [redirect, response]
        with patch.dict(os.environ, {"PROMOTION_API_TOKEN": "private-token"}), \
                patch.object(promotion.urllib.request, "build_opener", return_value=opener):
            self.assertEqual(promotion.gitlab_bytes("jobs/456/artifacts/published-image.json",
                                                    limit=promotion.MAX_RECORD_SIZE), b"record")
        source, destination = [call.args[0] for call in opener.open.call_args_list]
        self.assertEqual(source.full_url, promotion.PROJECT_API + "/jobs/456/artifacts/published-image.json")
        self.assertEqual(source.get_header("Private-token"), "private-token")
        self.assertIsNone(destination.get_header("Private-token"))
        response.__enter__.return_value.read.assert_called_once_with(promotion.MAX_RECORD_SIZE + 1)
        response.__enter__.return_value.read.return_value = b"x" * (promotion.MAX_RECORD_SIZE + 1)
        opener.open.side_effect = None
        opener.open.return_value = response
        with patch.object(promotion.urllib.request, "build_opener", return_value=opener), self.assertRaises(promotion.ValidationError):
            promotion.gitlab_bytes("jobs/456/artifacts/published-image.json", limit=promotion.MAX_RECORD_SIZE)

    def test_api_reads_are_anonymous_without_a_token(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(promotion, "read_bytes", return_value=b"[]") as read:
            self.assertEqual(promotion.gitlab("pipelines"), [])
        self.assertEqual(read.call_args.args[1], {"Accept": "application/json"})

    def test_health_requires_all_reported_checks_to_succeed(self):
        promotion.validate_health(b'{"status":"ok","checks":{"database":"ok","pubsub":"ok","scheduler":"ok","task_supervisor":"ok"}}')
        for body in [b'{}', b'[]', b'{"status":"ok","checks":{}}', b'{"status":"ok","checks":[]}',
                     b'{"status":"ok","checks":{"unrelated":"ok"}}',
                     b'{"status":"ok","checks":{"database":"ok","pubsub":"ok"}}',
                     b'{"status":"ok","checks":{"database":"error","pubsub":"ok","scheduler":"ok","task_supervisor":"ok"}}']:
            with self.subTest(body=body), self.assertRaises(promotion.ValidationError):
                promotion.validate_health(body)

    def test_wait_healthy_retries_until_every_check_passes(self):
        healthy = b'{"status":"ok","checks":{"database":"ok","pubsub":"ok","scheduler":"ok","task_supervisor":"ok"}}'
        failures = [OSError("connection refused"), promotion.ValidationError("HTTP 503"), b"not-json", b'{"status":"starting"}']
        with patch.object(promotion, "read_bytes", side_effect=failures + [healthy]) as read, \
                patch.object(promotion.time, "sleep") as sleep, contextlib.redirect_stdout(io.StringIO()):
            promotion.wait_healthy("https://custyard.com/api/health")
        self.assertEqual(read.call_count, 5)
        self.assertEqual(sleep.call_count, 4)
        self.assertEqual(read.call_args.args[1], {"Cache-Control": "no-cache"})
        self.assertEqual(read.call_args.kwargs["limit"], promotion.MAX_HEALTH_SIZE)
        with patch.object(promotion, "read_bytes", return_value=b'{"status":"starting"}'), \
                patch.object(promotion.time, "sleep"), self.assertRaisesRegex(promotion.ValidationError, "did not pass"):
            promotion.wait_healthy("https://custyard.com/api/health", attempts=3)


if __name__ == "__main__":
    unittest.main()
