#!/usr/bin/env python3
"""Validate immutable releases and apply narrowly scoped Bunny image updates."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REPOSITORY = "custyard/custyard"
SOURCE_URL = "https://gitlab.com/" + REPOSITORY
PROJECT_API = "https://gitlab.com/api/v4/projects/" + urllib.parse.quote(REPOSITORY, safe="")
REGISTRY = "registry.gitlab.com"
IMAGE = REGISTRY + "/" + REPOSITORY
REGISTRY_TOKEN_URL = ("https://gitlab.com/jwt/auth?service=container_registry"
                      f"&scope=repository:{REPOSITORY}:pull")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
SHA = re.compile(r"[0-9a-f]{40}\Z")
RECORD_FILE = "published-image.json"
DOTENV_FILE = "promotion.env"
MAX_RECORD_SIZE = 4096
MAX_RECORD_ARCHIVE = 65_536
MAX_HEALTH_SIZE = 65_536
# Job names in .gitlab-ci.yml; a parallel:matrix job reports one name per value.
REQUIRED_JOBS = {"test", "turso: [turso]", "turso: [bunny]", "release", "security", "publish"}
MANIFEST_TYPES = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


class ValidationError(Exception):
    """Safe, static operator-facing failure."""


def require(condition, message):
    if not condition:
        raise ValidationError(message)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def read_bytes(url, headers=None, redirects=0, method="GET", data=None, limit=16_777_216):
    """Never forward credentials when registries or artifacts redirect to storage."""
    require(redirects <= 3, "Remote response redirected too many times")
    parts = urllib.parse.urlsplit(url)
    require(parts.scheme == "https" and not parts.username, "Remote URL must use HTTPS")
    request = urllib.request.Request(url, headers=headers or {}, method=method, data=data)
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=20) as response:
            if method == "PATCH":
                require(response.status == 200, "Bunny container update did not succeed")
                # The successful PATCH body is irrelevant and may contain app
                # configuration. Do not parse it, retain it or print it.
                return b""
            body = response.read(limit + 1)
            require(len(body) <= limit, "Remote metadata exceeds the supported size")
            return body
    except urllib.error.HTTPError as error:
        if error.code in (301, 302, 303, 307, 308) and error.headers.get("Location"):
            require(method == "GET", "Bunny container update redirected unexpectedly")
            target = urllib.parse.urljoin(url, error.headers["Location"])
            return read_bytes(target, redirects=redirects + 1, limit=limit)
        raise ValidationError("Remote metadata request failed") from None


def gitlab_bytes(path, limit=16_777_216):
    """Read the project API. The project is public; PROMOTION_API_TOKEN (a
    read_api project access token) is only needed if it becomes private."""
    headers = {"Accept": "application/json"}
    token = os.environ.get("PROMOTION_API_TOKEN", "")
    if token:
        headers["PRIVATE-TOKEN"] = token
    return read_bytes(f"{PROJECT_API}/{path}", headers, limit=limit)


def gitlab(path):
    return json.loads(gitlab_bytes(path))


def validate_inputs(environment, digest, source_sha, previous_digest, acceptance_record, health_url):
    require(environment in ("staging", "production"), "Unknown deployment environment")
    require(bool(DIGEST.fullmatch(digest)), "Image must be an immutable sha256 digest")
    require(bool(SHA.fullmatch(source_sha)), "Source must be a full lowercase commit SHA")
    if previous_digest:
        require(bool(DIGEST.fullmatch(previous_digest)), "Previous image must be a sha256 digest")
    if acceptance_record:
        require(valid_https_url(acceptance_record), "Acceptance-record URL must use HTTPS without credentials or query strings")
    if environment == "production":
        require(bool(previous_digest), "Production requires the previous image digest")
        require(bool(acceptance_record), "Production requires an HTTPS acceptance-record URL")
    parts = urllib.parse.urlsplit(health_url)
    require(valid_https_url(health_url) and parts.path == "/api/health" and not parts.fragment,
            "HEALTHCHECK_URL must be an HTTPS /api/health URL without credentials or query strings")


def valid_https_url(value):
    parts = urllib.parse.urlsplit(value)
    return (parts.scheme == "https" and bool(parts.hostname) and not parts.username
            and not parts.password and not parts.query
            and not any(c.isspace() or c in '<>"()' for c in value))


def validate_pipeline_context():
    """The GitLab stand-in for GitHub's environment branch policy: only a
    manually started pipeline on Custyard's protected main branch promotes.
    Protected CI/CD variables keep the deploy credentials off other refs."""
    require(os.environ.get("CI_PROJECT_PATH") == REPOSITORY
            and os.environ.get("CI_COMMIT_BRANCH") == "main"
            and os.environ.get("CI_COMMIT_REF_PROTECTED") == "true"
            and os.environ.get("CI_PIPELINE_SOURCE") in ("web", "api"),
            "Promotions must run from a manual pipeline on Custyard's protected main branch")


def validate_ci(source_sha, digest):
    query = urllib.parse.urlencode({"sha": source_sha, "ref": "main", "source": "push",
                                    "status": "success", "per_page": 100})
    pipelines = gitlab("pipelines?" + query)
    require(isinstance(pipelines, list), "CI pipeline list is invalid")
    for pipeline in pipelines:
        if not (isinstance(pipeline, dict) and pipeline.get("sha") == source_sha
                and pipeline.get("ref") == "main" and pipeline.get("source") == "push"
                and pipeline.get("status") == "success"):
            continue
        pipeline_id = pipeline.get("id")
        if not (type(pipeline_id) is int and pipeline_id > 0):
            continue
        # Without include_retried, each name appears once: its latest attempt.
        jobs = gitlab(f"pipelines/{pipeline_id}/jobs?per_page=100")
        if not isinstance(jobs, list):
            continue
        jobs = [job for job in jobs if isinstance(job, dict)]
        successful = {job.get("name") for job in jobs if job.get("status") == "success"}
        publish = [job for job in jobs if job.get("name") == "publish"]
        if not (REQUIRED_JOBS <= successful and len(publish) == 1):
            continue
        try:
            validate_published_record(pipeline_id, publish[0], source_sha, digest)
        except ValidationError:
            continue
        return f"{SOURCE_URL}/-/pipelines/{pipeline_id}"
    raise ValidationError("Candidate has no successful push-to-main CI pipeline with all release/publish gates and a matching published image record")


def validate_published_record(pipeline_id, job, source_sha, digest):
    # The record names the publish job that wrote it, so a retried publish
    # cannot borrow the record of an earlier attempt. Expired, legacy or
    # incomplete records fail closed.
    job_id = job.get("id")
    origin = job.get("pipeline")
    archives = [item for item in job.get("artifacts") or []
                if isinstance(item, dict) and item.get("file_type") == "archive"]
    require(type(job_id) is int and job_id > 0 and job.get("name") == "publish"
            and job.get("status") == "success" and job.get("ref") == "main"
            and isinstance(origin, dict) and origin.get("id") == pipeline_id
            and origin.get("sha") == source_sha and len(archives) == 1
            and type(archives[0].get("size")) is int
            and 0 < archives[0]["size"] <= MAX_RECORD_ARCHIVE,
            "CI published image record is expired or invalid")
    # GitLab serves one bounded member of the archive; nothing is extracted.
    body = gitlab_bytes(f"jobs/{job_id}/artifacts/{RECORD_FILE}", limit=MAX_RECORD_SIZE)
    try:
        record = json.loads(body)
    except ValueError:
        raise ValidationError("CI published image record could not be decoded") from None
    expected = {"version": 1, "repository": REPOSITORY, "image": IMAGE, "source_sha": source_sha,
                "digest": digest, "pipeline_id": pipeline_id, "job_id": job_id}
    require(isinstance(record, dict)
            and all(type(record.get(key)) is int for key in ("version", "pipeline_id", "job_id"))
            and record == expected, "Candidate digest does not match the image published by this CI publish job")


def verify_hash(body, digest):
    require(bool(DIGEST.fullmatch(digest)), "Registry descriptor has an invalid digest")
    require("sha256:" + hashlib.sha256(body).hexdigest() == digest, "Registry metadata does not match its digest")
    return json.loads(body)


def registry_token():
    headers = {}
    job_token = os.environ.get("CI_JOB_TOKEN", "")
    if job_token:
        credentials = base64.b64encode(("gitlab-ci-token:" + job_token).encode()).decode()
        headers["Authorization"] = "Basic " + credentials
    token = json.loads(read_bytes(REGISTRY_TOKEN_URL, headers)).get("token")
    require(isinstance(token, str) and bool(token), "Registry pull token could not be obtained")
    return token


def validate_image(digest, source_sha):
    headers = {"Authorization": "Bearer " + registry_token(), "Accept": MANIFEST_TYPES}

    def manifest_at(value):
        body = read_bytes(f"https://{REGISTRY}/v2/{REPOSITORY}/manifests/{value}", headers)
        return verify_hash(body, value)

    manifest = manifest_at(digest)
    if "manifests" in manifest:
        # The index also lists buildx's attestation manifest (unknown/unknown).
        candidates = [item for item in manifest["manifests"]
                      if item.get("platform", {}).get("os") == "linux"
                      and item.get("platform", {}).get("architecture") == "amd64"]
        require(len(candidates) == 1, "Candidate must contain exactly one linux/amd64 image")
        manifest = manifest_at(candidates[0]["digest"])
    config_digest = manifest["config"]["digest"]
    require(bool(DIGEST.fullmatch(config_digest)), "Image config has an invalid digest")
    config = verify_hash(read_bytes(f"https://{REGISTRY}/v2/{REPOSITORY}/blobs/{config_digest}", headers), config_digest)
    validate_image_config(config, source_sha)


def validate_image_config(config, source_sha):
    require(config.get("os") == "linux" and config.get("architecture") == "amd64", "Candidate must target linux/amd64")
    labels = config.get("config", {}).get("Labels") or {}
    require(labels.get("org.opencontainers.image.revision") == source_sha, "Image revision does not match the selected source SHA")
    require(labels.get("org.opencontainers.image.source") == SOURCE_URL, "Image source repository does not match Custyard")


def bunny_container():
    app_id = os.environ.get("BUNNY_APP_ID", "")
    name = os.environ.get("BUNNY_CONTAINER_NAME", "")
    token = os.environ.get("BUNNYNET_API_KEY", "")
    require(bool(re.fullmatch(r"[A-Za-z0-9_-]{1,128}", app_id)) and bool(name) and bool(token),
            "Bunny environment app ID, container name and API key are required")
    config = json.loads(read_bytes(f"https://api.bunny.net/mc/apps/{app_id}", {"AccessKey": token, "Accept": "application/json"}))
    containers = [container for container in config.get("containerTemplates", []) if container.get("name") == name]
    require(len(containers) == 1, "Bunny app must contain exactly one matching container")
    container = containers[0]
    require(container.get("imageNamespace") == "custyard" and container.get("imageName") == "custyard",
            "Bunny container must already select the custyard/custyard registry image")
    return container


def validate_bunny_previous(previous_digest):
    require(bunny_container().get("imageDigest") == previous_digest,
            "Bunny's current configured digest differs from the supplied previous digest")


def update_bunny(digest, source_sha, previous_digest):
    """Apply only reviewed image fields; never upload or echo environment data.

    Endpoint and fields match BunnyWay/actions at immutable commit
    931a74b9c45ea9f9f01435fbbf1649830e67d3b3. An in-repo request avoids that
    action's raw JSON/fetch-error logging and awaits the completed PATCH.
    """
    container = bunny_container()
    require(container.get("imageDigest") == previous_digest,
            "Bunny's configured digest changed before update; inspect the target")
    container_id = container.get("id", "")
    require(bool(re.fullmatch(r"[A-Za-z0-9_-]{1,128}", container_id)), "Bunny container ID could not be verified")
    app_id = os.environ["BUNNY_APP_ID"]
    body = json.dumps({"id": container_id, "imageTag": "sha-" + source_sha,
                       "imageName": "custyard", "imageDigest": digest}).encode()
    read_bytes(f"https://api.bunny.net/mc/apps/{app_id}/containers/{container_id}",
               {"AccessKey": os.environ["BUNNYNET_API_KEY"], "Content-Type": "application/json"},
               method="PATCH", data=body)


def verify_bunny_digest(digest):
    for _ in range(24):
        if bunny_container().get("imageDigest") == digest:
            return
        time.sleep(5)
    raise ValidationError("Bunny did not report the selected configured image digest")


def validate_health(body):
    health = json.loads(body)
    require(isinstance(health, dict), "Application health checks have not passed")
    checks = health.get("checks", {})
    expected = {"database", "pubsub", "scheduler", "task_supervisor"}
    require(health.get("status") == "ok" and isinstance(checks, dict) and expected <= checks.keys()
            and all(value == "ok" for value in checks.values()), "Application health checks have not passed")


def wait_healthy(health_url, attempts=24, delay=5):
    for _ in range(attempts):
        try:
            validate_health(read_bytes(health_url, {"Cache-Control": "no-cache"}, limit=MAX_HEALTH_SIZE))
            print("Provider update completed; HTTPS application health checks passed.")
            return
        except (ValidationError, ValueError, OSError):
            time.sleep(delay)
    raise ValidationError("HTTPS application health checks did not pass. Inspect the deployment; "
                          "the previous digest is recorded in the promote:validate job")


def write_record(environment, digest, source_sha, previous_digest, acceptance_record, ci_url, health_url):
    """Hand the verified reference to the deploy job (dotenv report) and log it."""
    reference = IMAGE + "@" + digest
    environment_url = "https://" + urllib.parse.urlsplit(health_url).netloc
    Path(DOTENV_FILE).write_text(f"IMAGE_REFERENCE={reference}\nIMAGE_TAG=sha-{source_sha}\n"
                                 f"ENVIRONMENT_URL={environment_url}\n", encoding="utf-8")
    print(f"Promotion target: {environment}\nCandidate: {reference}\nSource: {source_sha}")
    print(f"Previous digest: {previous_digest or 'initial staging deployment'}\nCI: {ci_url}")
    if acceptance_record:
        print(f"Operator acceptance record: {acceptance_record}")
    print("This record precedes deployment. Check the deploy job for provider and HTTPS health results.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["validate", "update-bunny", "verify-bunny", "wait-healthy"])
    args = parser.parse_args()
    validate_pipeline_context()
    digest = os.environ.get("IMAGE_DIGEST", "")
    require(bool(DIGEST.fullmatch(digest)), "Image must be an immutable sha256 digest")
    if args.command == "verify-bunny":
        verify_bunny_digest(digest)
        return
    environment = os.environ.get("PROMOTE_ENVIRONMENT", "")
    source_sha = os.environ.get("SOURCE_SHA", "")
    previous_digest = os.environ.get("PREVIOUS_DIGEST", "")
    acceptance_record = os.environ.get("ACCEPTANCE_RECORD", "")
    health_url = os.environ.get("HEALTHCHECK_URL", "")
    validate_inputs(environment, digest, source_sha, previous_digest, acceptance_record, health_url)
    if args.command == "wait-healthy":
        wait_healthy(health_url)
        return
    if args.command == "update-bunny":
        require(environment == "production", "Bunny image updates require the production environment")
        # GitLab Free has no deployment approvals; the production deploy job is
        # manual, and this refuses to run unless a person started it.
        require(os.environ.get("CI_JOB_MANUAL") == "true", "Production updates must be started by hand from the promote:production job")
        update_bunny(digest, source_sha, previous_digest)
        return
    ci_url = validate_ci(source_sha, digest)
    validate_image(digest, source_sha)
    if environment == "production":
        validate_bunny_previous(previous_digest)
    write_record(environment, digest, source_sha, previous_digest, acceptance_record, ci_url, health_url)


def cli():
    try:
        main()
        return 0
    except ValidationError as error:
        print("Promotion rejected: " + str(error), file=sys.stderr)
        return 1
    except Exception:
        # Provider metadata can contain runtime secrets; never print exceptions,
        # response bodies, signed URLs or traceback locals on the runner.
        print("Promotion rejected: remote metadata or health response could not be verified", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(cli())
