import contextlib
import hashlib
import io
import json
import os
import unittest
from unittest.mock import MagicMock, patch

import image_tag
import promotion

SHA = "a" * 40
CONTEXT = {"CI_PROJECT_PATH": "custyard/custyard", "CI_PIPELINE_SOURCE": "push",
           "CI_COMMIT_REF_PROTECTED": "true", "CI_COMMIT_TAG": "v1.2.3", "CI_COMMIT_SHA": SHA}
INDEX = "application/vnd.oci.image.index.v1+json"


def manifest(media_type=INDEX, marker="published"):
    body = json.dumps({"mediaType": media_type, "manifests": [], "annotations": {"marker": marker}}).encode()
    return body, "sha256:" + hashlib.sha256(body).hexdigest()


class Registry:
    """read_bytes against an in-memory registry: manifests by digest or tag."""

    def __init__(self, *bodies, tags=None, accept_put=True):
        self.by_reference = {"sha256:" + hashlib.sha256(body).hexdigest(): body for body in bodies}
        self.by_reference.update(tags or {})
        self.accept_put = accept_put
        self.requests = []

    def __call__(self, url, headers=None, method="GET", data=None, missing_ok=False):
        self.requests.append((method, url, headers, data))
        if url == promotion.REGISTRY_PUSH_TOKEN_URL:
            return b'{"token":"push-token"}'
        assert url.startswith(image_tag.MANIFESTS), url
        reference = url[len(image_tag.MANIFESTS):]
        if method == "PUT":
            if self.accept_put:
                self.by_reference[reference] = data
            return b""
        if reference not in self.by_reference:
            if missing_ok:
                return None
            raise promotion.ValidationError("Remote metadata request failed")
        return self.by_reference[reference]

    def puts(self):
        return [request for request in self.requests if request[0] == "PUT"]


class ImageTagTest(unittest.TestCase):
    def test_only_a_pushed_protected_version_tag_in_custyards_project_tags_an_image(self):
        with patch.dict(os.environ, CONTEXT, clear=True):
            self.assertEqual(image_tag.validate_tag_context(), ("v1.2.3", SHA))
        for field, value in [("CI_PROJECT_PATH", "fork/custyard"), ("CI_COMMIT_REF_PROTECTED", "false"),
                             ("CI_COMMIT_REF_PROTECTED", ""), ("CI_PIPELINE_SOURCE", "web"),
                             ("CI_PIPELINE_SOURCE", "api"), ("CI_COMMIT_TAG", ""), ("CI_COMMIT_TAG", "v1.2"),
                             ("CI_COMMIT_TAG", "1.2.3"), ("CI_COMMIT_TAG", "v1.2.3-rc1"),
                             ("CI_COMMIT_TAG", "v1.2.3\nlatest"), ("CI_COMMIT_TAG", "latest"),
                             ("CI_COMMIT_SHA", "abc123"), ("CI_COMMIT_SHA", "")]:
            with self.subTest(field=field, value=value), \
                    patch.dict(os.environ, dict(CONTEXT, **{field: value}), clear=True), \
                    self.assertRaisesRegex(promotion.ValidationError, "protected vMAJOR.MINOR.PATCH"):
                image_tag.validate_tag_context()

    def test_tag_stores_the_published_manifest_bytes_under_the_version(self):
        body, digest = manifest()
        registry = Registry(body)
        with patch.dict(os.environ, {"CI_JOB_TOKEN": "job-token"}), \
                patch.object(promotion, "read_bytes", side_effect=registry):
            self.assertTrue(image_tag.tag_image(digest, "v1.2.3"))
        token_request = registry.requests[0]
        self.assertEqual(token_request[1], promotion.REGISTRY_PUSH_TOKEN_URL)
        self.assertEqual(token_request[2]["Authorization"], "Basic Z2l0bGFiLWNpLXRva2VuOmpvYi10b2tlbg==")
        [(_, url, headers, data)] = registry.puts()
        self.assertEqual(url, "https://registry.gitlab.com/v2/custyard/custyard/manifests/v1.2.3")
        self.assertEqual(headers, {"Authorization": "Bearer push-token", "Content-Type": INDEX})
        self.assertEqual(data, body)
        self.assertEqual(registry.by_reference["v1.2.3"], body)

    def test_an_existing_version_tag_is_left_alone_or_refused_never_moved(self):
        body, digest = manifest()
        other, _ = manifest(marker="other")
        registry = Registry(body, tags={"v1.2.3": body})
        with patch.object(promotion, "read_bytes", side_effect=registry):
            self.assertFalse(image_tag.tag_image(digest, "v1.2.3"))
        self.assertEqual(registry.puts(), [])
        registry = Registry(body, tags={"v1.2.3": other})
        with patch.object(promotion, "read_bytes", side_effect=registry), \
                self.assertRaisesRegex(promotion.ValidationError, "never moved"):
            image_tag.tag_image(digest, "v1.2.3")
        self.assertEqual(registry.puts(), [])
        self.assertEqual(registry.by_reference["v1.2.3"], other)

    def test_manifest_must_match_its_digest_and_carry_a_known_media_type(self):
        body, digest = manifest()
        tampered = Registry()
        tampered.by_reference[digest] = body + b" "
        unknown, unknown_digest = manifest(media_type="text/html")
        missing = json.dumps({"manifests": []}).encode()
        missing_digest = "sha256:" + hashlib.sha256(missing).hexdigest()
        for registry, reference, message in [(tampered, digest, "does not match its digest"),
                                             (Registry(unknown), unknown_digest, "unsupported media type"),
                                             (Registry(missing), missing_digest, "unsupported media type")]:
            with self.subTest(message=message), patch.object(promotion, "read_bytes", side_effect=registry), \
                    self.assertRaisesRegex(promotion.ValidationError, message):
                image_tag.tag_image(reference, "v1.2.3")
            self.assertEqual(registry.puts(), [])

    def test_tag_is_confirmed_against_the_registry_after_writing(self):
        body, digest = manifest()
        other, _ = manifest(marker="other")

        class Swapped(Registry):
            def __call__(self, url, headers=None, method="GET", data=None, missing_ok=False):
                result = super().__call__(url, headers, method, data, missing_ok)
                if method == "PUT":
                    self.by_reference["v1.2.3"] = other
                return result

        with patch.object(promotion, "read_bytes", side_effect=Swapped(body)), \
                self.assertRaisesRegex(promotion.ValidationError, "does not report the version tag"):
            image_tag.tag_image(digest, "v1.2.3")

    def test_digest_comes_from_the_publish_record_and_is_validated_before_any_write(self):
        digest = "sha256:" + "b" * 64
        calls = []
        with patch.dict(os.environ, CONTEXT, clear=True), \
                patch.object(promotion, "published_digest", side_effect=lambda sha: calls.append(("record", sha)) or (digest, "https://ci")), \
                patch.object(promotion, "validate_image", side_effect=lambda *args: calls.append(("image",) + args)), \
                patch.object(image_tag, "tag_image", side_effect=lambda *args: calls.append(("tag",) + args) or True), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            image_tag.main()
        self.assertEqual(calls, [("record", SHA), ("image", digest, SHA), ("tag", digest, "v1.2.3")])
        self.assertIn("Tagged: registry.gitlab.com/custyard/custyard:v1.2.3", output.getvalue())
        self.assertIn("registry.gitlab.com/custyard/custyard@" + digest, output.getvalue())

    def test_nothing_is_written_when_the_context_record_or_image_is_rejected(self):
        digest = "sha256:" + "b" * 64
        rejected = promotion.ValidationError("rejected")
        for context, record, image in [(dict(CONTEXT, CI_COMMIT_REF_PROTECTED="false"), None, None),
                                       (CONTEXT, rejected, None), (CONTEXT, None, rejected)]:
            with self.subTest(context=context, record=record, image=image), \
                    patch.dict(os.environ, context, clear=True), \
                    patch.object(promotion, "published_digest", side_effect=record, return_value=(digest, "https://ci")), \
                    patch.object(promotion, "validate_image", side_effect=image), \
                    patch.object(promotion, "read_bytes") as request, \
                    patch.object(image_tag, "tag_image") as tag, \
                    self.assertRaises(promotion.ValidationError):
                image_tag.main()
            tag.assert_not_called()
            request.assert_not_called()

    def test_cli_reports_rejections_without_exception_text(self):
        output = io.StringIO()
        with patch.object(image_tag, "main", side_effect=promotion.ValidationError("no published image")), \
                contextlib.redirect_stderr(output):
            self.assertEqual(image_tag.cli(), 1)
        self.assertEqual(output.getvalue(), "Image tag rejected: no published image\n")
        for error in [ValueError("Bearer push-token"), OSError("https://storage.invalid/?signed=secret"),
                      KeyError("CI_JOB_TOKEN=job-token")]:
            output = io.StringIO()
            with patch.object(image_tag, "main", side_effect=error), contextlib.redirect_stderr(output):
                self.assertEqual(image_tag.cli(), 1)
            self.assertNotIn("push-token", output.getvalue())
            self.assertNotIn("signed=secret", output.getvalue())
            self.assertNotIn("job-token", output.getvalue())
        with patch.object(image_tag, "main", return_value=None):
            self.assertEqual(image_tag.cli(), 0)


class PublishedDigestTest(unittest.TestCase):
    digest = "sha256:" + "b" * 64
    older = "sha256:" + "c" * 64

    def pipeline(self, pipeline_id=123, **overrides):
        return dict({"id": pipeline_id, "sha": SHA, "ref": "main", "source": "push", "status": "success"}, **overrides)

    def jobs(self, pipeline_id=123, job_id=456, **publish):
        names = ["test", "turso: [turso]", "turso: [bunny]", "release", "security"]
        job = {"id": job_id, "name": "publish", "status": "success", "ref": "main",
               "pipeline": {"id": pipeline_id, "sha": SHA, "ref": "main"},
               "artifacts": [{"file_type": "archive", "size": 411}]}
        job.update(publish)
        return [{"name": name, "status": "success"} for name in names] + [job]

    def record(self, pipeline_id=123, job_id=456, **overrides):
        value = {"version": 1, "repository": promotion.REPOSITORY, "image": promotion.IMAGE,
                 "source_sha": SHA, "digest": self.digest, "pipeline_id": pipeline_id, "job_id": job_id}
        value.update(overrides)
        return json.dumps(value).encode()

    def test_digest_is_read_from_the_publish_record_of_a_successful_main_pipeline(self):
        with patch.object(promotion, "gitlab", side_effect=[[self.pipeline()], self.jobs()]) as api, \
                patch.object(promotion, "gitlab_bytes", return_value=self.record()) as download:
            self.assertEqual(promotion.published_digest(SHA),
                             (self.digest, "https://gitlab.com/custyard/custyard/-/pipelines/123"))
        self.assertIn("ref=main", api.call_args_list[0].args[0])
        self.assertIn("source=push", api.call_args_list[0].args[0])
        self.assertIn("status=success", api.call_args_list[0].args[0])
        download.assert_called_once_with("jobs/456/artifacts/published-image.json", limit=promotion.MAX_RECORD_SIZE)

    def test_newest_pipeline_with_a_valid_record_wins(self):
        newer, older = self.pipeline(124), self.pipeline(123)
        with patch.object(promotion, "gitlab", side_effect=[[newer, older], self.jobs(124, 457)]), \
                patch.object(promotion, "gitlab_bytes", return_value=self.record(124, 457)):
            self.assertEqual(promotion.published_digest(SHA)[0], self.digest)
        # A newer pipeline whose record is unusable does not hide the older one.
        with patch.object(promotion, "gitlab", side_effect=[[newer, older], self.jobs(124, 457), self.jobs()]), \
                patch.object(promotion, "gitlab_bytes", side_effect=[
                    self.record(124, 457, source_sha="d" * 40), self.record(digest=self.older)]):
            self.assertEqual(promotion.published_digest(SHA),
                             (self.older, "https://gitlab.com/custyard/custyard/-/pipelines/123"))

    def test_commits_without_a_gated_main_pipeline_and_valid_record_are_refused(self):
        message = "no successful push-to-main CI pipeline"
        for pipeline in [self.pipeline(ref="feature"), self.pipeline(source="merge_request_event"),
                         self.pipeline(source="web"), self.pipeline(status="failed"), self.pipeline(sha="d" * 40)]:
            # Complete jobs and a valid record sit behind each pipeline, so only
            # the checks on the pipeline itself can refuse it.
            with self.subTest(pipeline=pipeline), \
                    patch.object(promotion, "gitlab", side_effect=[[pipeline], self.jobs()]), \
                    patch.object(promotion, "gitlab_bytes", return_value=self.record()) as download, \
                    self.assertRaisesRegex(promotion.ValidationError, message):
                promotion.published_digest(SHA)
            download.assert_not_called()
        with patch.object(promotion, "gitlab", return_value=[]), self.assertRaisesRegex(promotion.ValidationError, message):
            promotion.published_digest(SHA)
        jobs = self.jobs()
        for incomplete in [jobs[:-1], [dict(job, status="failed") if job["name"] == "security" else job for job in jobs],
                           self.jobs(status="failed"), self.jobs(ref="feature"), self.jobs(artifacts=[])]:
            with self.subTest(incomplete=incomplete), \
                    patch.object(promotion, "gitlab", side_effect=[[self.pipeline()], incomplete]), \
                    patch.object(promotion, "gitlab_bytes") as download, \
                    self.assertRaisesRegex(promotion.ValidationError, message):
                promotion.published_digest(SHA)
            download.assert_not_called()
        for body in [b"not-json", b"[]", self.record(digest="latest"), self.record(digest=None),
                     self.record(repository="other/repo"), self.record(image="registry.gitlab.com/other/repo"),
                     self.record(source_sha="d" * 40), self.record(pipeline_id=124), self.record(job_id=455),
                     self.record(version=2), self.record(extra="field")]:
            with self.subTest(body=body), patch.object(promotion, "gitlab", side_effect=[[self.pipeline()], self.jobs()]), \
                    patch.object(promotion, "gitlab_bytes", return_value=body), \
                    self.assertRaisesRegex(promotion.ValidationError, message):
                promotion.published_digest(SHA)


class RegistryRequestTest(unittest.TestCase):
    def opener(self, status=None, error=None):
        response = MagicMock()
        response.__enter__.return_value.status = status
        opener = MagicMock()
        opener.open.side_effect = error
        opener.open.return_value = response
        return opener, response

    def test_put_succeeds_only_when_the_registry_creates_the_manifest(self):
        url = image_tag.MANIFESTS + "v1.2.3"
        opener, response = self.opener(status=201)
        with patch.object(promotion.urllib.request, "build_opener", return_value=opener):
            self.assertEqual(promotion.read_bytes(url, {"Authorization": "Bearer t"}, method="PUT", data=b"{}"), b"")
        request = opener.open.call_args.args[0]
        self.assertEqual((request.get_method(), request.full_url, request.data), ("PUT", url, b"{}"))
        response.__enter__.return_value.read.assert_not_called()
        for status in (200, 202, 204):
            opener, _ = self.opener(status=status)
            with self.subTest(status=status), patch.object(promotion.urllib.request, "build_opener", return_value=opener), \
                    self.assertRaisesRegex(promotion.ValidationError, "did not accept the version tag"):
                promotion.read_bytes(url, {}, method="PUT", data=b"{}")

    def test_put_is_never_redirected_and_its_failures_are_rejections(self):
        url = image_tag.MANIFESTS + "v1.2.3"
        redirect = promotion.urllib.error.HTTPError(url, 307, "redirect", {"Location": "https://storage.example.com/x"}, None)
        for error in [redirect, promotion.urllib.error.HTTPError(url, 401, "denied", {}, None),
                      promotion.urllib.error.HTTPError(url, 404, "missing", {}, None)]:
            opener, _ = self.opener(error=error)
            with self.subTest(code=error.code), patch.object(promotion.urllib.request, "build_opener", return_value=opener), \
                    self.assertRaises(promotion.ValidationError):
                promotion.read_bytes(url, {"Authorization": "Bearer t"}, method="PUT", data=b"{}", missing_ok=True)
            self.assertEqual(opener.open.call_count, 1)

    def test_a_missing_tag_is_none_only_when_asked_for(self):
        url = image_tag.MANIFESTS + "v1.2.3"
        missing = promotion.urllib.error.HTTPError(url, 404, "missing", {}, None)
        opener, _ = self.opener(error=missing)
        with patch.object(promotion.urllib.request, "build_opener", return_value=opener):
            self.assertIsNone(promotion.read_bytes(url, {}, missing_ok=True))
            with self.assertRaises(promotion.ValidationError):
                promotion.read_bytes(url, {})
        for code in (401, 403, 500):
            opener, _ = self.opener(error=promotion.urllib.error.HTTPError(url, code, "error", {}, None))
            with self.subTest(code=code), patch.object(promotion.urllib.request, "build_opener", return_value=opener), \
                    self.assertRaises(promotion.ValidationError):
                promotion.read_bytes(url, {}, missing_ok=True)

    def test_push_scope_is_requested_only_for_tagging(self):
        with patch.dict(os.environ, {}, clear=True), \
                patch.object(promotion, "read_bytes", return_value=b'{"token":"t"}') as read:
            promotion.registry_token()
            promotion.registry_token(push=True)
        pull, push = [call.args[0] for call in read.call_args_list]
        self.assertTrue(pull.endswith(":pull"))
        self.assertTrue(push.endswith(":pull,push"))


if __name__ == "__main__":
    unittest.main()
