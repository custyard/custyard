#!/usr/bin/env python3
"""Validate immutable releases and apply narrowly scoped Bunny image updates."""

import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

REPOSITORY = "custyard/custyard"
IMAGE = "ghcr.io/custyard/custyard"
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
SHA = re.compile(r"[0-9a-f]{40}\Z")
RECORD_FILE = "published-image.json"
MAX_RECORD_SIZE = 4096
MAX_RECORD_ARCHIVE = 65_536
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


def github_bytes(path, limit=16_777_216):
    token = os.environ.get("GITHUB_TOKEN", "")
    require(bool(token), "GITHUB_TOKEN is required")
    return read_bytes(f"https://api.github.com/repos/{REPOSITORY}/{path}", {
        "Authorization": "Bearer " + token,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2026-03-10",
    }, limit=limit)


def github(path):
    return json.loads(github_bytes(path))


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


def validate_environment(environment):
    config = github("environments/" + environment)
    policy = config.get("deployment_branch_policy") or {}
    restricted = policy.get("protected_branches") is True
    if policy.get("custom_branch_policies") is True:
        rules = github(f"environments/{environment}/deployment-branch-policies").get("branch_policies", [])
        restricted = bool(rules) and all(rule.get("name") == "main" and rule.get("type", "branch") == "branch" for rule in rules)
    require(restricted, "Deployment environment must restrict deployments to main or protected branches")
    if environment == "production":
        require(any(rule.get("type") == "required_reviewers" and rule.get("reviewers")
                    for rule in config.get("protection_rules", [])),
                "Production environment must have required reviewers")


def validate_ci(source_sha, digest):
    query = urllib.parse.urlencode({"head_sha": source_sha, "branch": "main", "event": "push", "status": "success", "per_page": 100})
    runs = github("actions/workflows/ci.yml/runs?" + query).get("workflow_runs", [])
    for run in runs:
        if not (run.get("head_sha") == source_sha and run.get("head_branch") == "main"
                and run.get("event") == "push" and run.get("status") == "completed"
                and run.get("conclusion") == "success"):
            continue
        run_id, attempt = run.get("id"), run.get("run_attempt")
        if not (type(run_id) is int and run_id > 0 and type(attempt) is int and attempt > 0):
            continue
        jobs = github(f"actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100").get("jobs", [])
        required = {"test", "turso (turso)", "turso (bunny)", "release", "security", "publish"}
        successful = {job.get("name") for job in jobs if job.get("conclusion") == "success"}
        if required <= successful:
            try:
                validate_published_record(run_id, attempt, source_sha, digest)
            except ValidationError:
                continue
            return run["html_url"] + f"/attempts/{attempt}"
    raise ValidationError("Candidate has no successful push-to-main CI run with all release/publish gates and a matching published image record")


def validate_published_record(run_id, attempt, source_sha, digest):
    # Attempt-specific immutable names prevent a rerun from using the record
    # of an earlier publish. Legacy, expired or incomplete records fail closed.
    name = f"published-image-{run_id}-{attempt}"
    query = urllib.parse.urlencode({"name": name, "per_page": 100})
    listing = github(f"actions/runs/{run_id}/artifacts?{query}")
    require(isinstance(listing, dict), "CI published image record list is invalid")
    artifacts = listing.get("artifacts", [])
    require(isinstance(artifacts, list) and type(listing.get("total_count")) is int
            and listing["total_count"] == len(artifacts)
            and len(artifacts) == 1, "CI published image record is missing or ambiguous")
    artifact = artifacts[0]
    require(isinstance(artifact, dict), "CI published image record metadata is invalid")
    origin = artifact.get("workflow_run") or {}
    require(isinstance(origin, dict), "CI published image record origin is invalid")
    artifact_id, size = artifact.get("id"), artifact.get("size_in_bytes")
    archive_digest = artifact.get("digest", "")
    require(artifact.get("name") == name and artifact.get("expired") is False
            and origin.get("id") == run_id and origin.get("head_sha") == source_sha
            and origin.get("head_branch") == "main"
            and type(artifact_id) is int and artifact_id > 0
            and type(size) is int and 0 < size <= MAX_RECORD_ARCHIVE
            and isinstance(archive_digest, str) and bool(DIGEST.fullmatch(archive_digest)),
            "CI published image record is expired or invalid")
    body = github_bytes(f"actions/artifacts/{artifact_id}/zip", limit=MAX_RECORD_ARCHIVE)
    require(len(body) == size and "sha256:" + hashlib.sha256(body).hexdigest() == archive_digest,
            "CI published image record archive does not match its digest")
    try:
        # Read one bounded member in memory; never extract supplied paths.
        with zipfile.ZipFile(io.BytesIO(body)) as archive:
            entries = archive.infolist()
            require(len(entries) == 1 and entries[0].filename == RECORD_FILE
                    and 0 < entries[0].file_size <= MAX_RECORD_SIZE,
                    "CI published image record archive has invalid contents")
            with archive.open(entries[0]) as member:
                record_bytes = member.read(MAX_RECORD_SIZE + 1)
            require(len(record_bytes) <= MAX_RECORD_SIZE, "CI published image record exceeds the supported size")
            record = json.loads(record_bytes)
    except (ValueError, OSError, RuntimeError, zipfile.BadZipFile):
        raise ValidationError("CI published image record could not be decoded") from None
    expected = {"version": 1, "repository": REPOSITORY, "image": IMAGE,
                "source_sha": source_sha, "digest": digest, "run_id": run_id, "run_attempt": attempt}
    require(isinstance(record, dict)
            and all(type(record.get(key)) is int for key in ("version", "run_id", "run_attempt"))
            and record == expected, "Candidate digest does not match the image published by this CI run attempt")


def verify_hash(body, digest):
    require(bool(DIGEST.fullmatch(digest)), "Registry descriptor has an invalid digest")
    require("sha256:" + hashlib.sha256(body).hexdigest() == digest, "Registry metadata does not match its digest")
    return json.loads(body)


def validate_image(digest, source_sha):
    credentials = base64.b64encode((os.environ["GITHUB_ACTOR"] + ":" + os.environ["GITHUB_TOKEN"]).encode()).decode()
    token_url = "https://ghcr.io/token?service=ghcr.io&scope=repository:custyard/custyard:pull"
    token = json.loads(read_bytes(token_url, {"Authorization": "Basic " + credentials}))["token"]
    headers = {"Authorization": "Bearer " + token, "Accept": MANIFEST_TYPES}

    def manifest_at(value):
        body = read_bytes(f"https://ghcr.io/v2/{REPOSITORY}/manifests/{value}", headers)
        return verify_hash(body, value)

    manifest = manifest_at(digest)
    if "manifests" in manifest:
        candidates = [item for item in manifest["manifests"]
                      if item.get("platform", {}).get("os") == "linux"
                      and item.get("platform", {}).get("architecture") == "amd64"]
        require(len(candidates) == 1, "Candidate must contain exactly one linux/amd64 image")
        manifest = manifest_at(candidates[0]["digest"])
    config_digest = manifest["config"]["digest"]
    require(bool(DIGEST.fullmatch(config_digest)), "Image config has an invalid digest")
    config = verify_hash(read_bytes(f"https://ghcr.io/v2/{REPOSITORY}/blobs/{config_digest}", headers), config_digest)
    validate_image_config(config, source_sha)


def validate_image_config(config, source_sha):
    require(config.get("os") == "linux" and config.get("architecture") == "amd64", "Candidate must target linux/amd64")
    labels = config.get("config", {}).get("Labels") or {}
    require(labels.get("org.opencontainers.image.revision") == source_sha, "Image revision does not match the selected source SHA")
    require(labels.get("org.opencontainers.image.source") == "https://github.com/custyard/custyard", "Image source repository does not match Custyard")


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
    checks = health.get("checks", {})
    expected = {"database", "pubsub", "scheduler", "task_supervisor"}
    require(health.get("status") == "ok" and expected <= checks.keys()
            and all(value == "ok" for value in checks.values()), "Application health checks have not passed")


def write_record(environment, digest, source_sha, previous_digest, acceptance_record, ci_url):
    reference = IMAGE + "@" + digest
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"image_reference={reference}\nimage_tag=sha-{source_sha}\n")
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
        summary.write(f"Promotion target: {environment}\n\nCandidate: `{reference}`\n\nSource: `{source_sha}`\n\n")
        summary.write(f"Previous digest: `{previous_digest or 'initial staging deployment'}`\n\nCI: {ci_url}\n\n")
        if acceptance_record:
            summary.write(f"Operator acceptance record: {acceptance_record}\n\n")
        summary.write("This record precedes deployment. Check subsequent provider and HTTPS health steps for their results.\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["validate", "update-bunny", "verify-bunny", "health"])
    args = parser.parse_args()
    if args.command == "health":
        validate_health(Path("promotion-health.json").read_bytes())
        return
    require(os.environ.get("GITHUB_REPOSITORY") == REPOSITORY
            and os.environ.get("GITHUB_REF") == "refs/heads/main", "Promotions must run from Custyard's main branch")
    digest = os.environ.get("IMAGE_DIGEST", "")
    require(bool(DIGEST.fullmatch(digest)), "Image must be an immutable sha256 digest")
    if args.command == "verify-bunny":
        verify_bunny_digest(digest)
        return
    environment = os.environ.get("DEPLOY_ENVIRONMENT", "")
    source_sha = os.environ.get("SOURCE_SHA", "")
    previous_digest = os.environ.get("PREVIOUS_DIGEST", "")
    acceptance_record = os.environ.get("ACCEPTANCE_RECORD", "")
    validate_inputs(environment, digest, source_sha, previous_digest, acceptance_record, os.environ.get("HEALTHCHECK_URL", ""))
    if args.command == "update-bunny":
        require(environment == "production", "Bunny image updates require the production environment")
        update_bunny(digest, source_sha, previous_digest)
        return
    validate_environment(environment)
    ci_url = validate_ci(source_sha, digest)
    validate_image(digest, source_sha)
    if environment == "production":
        validate_bunny_previous(previous_digest)
    write_record(environment, digest, source_sha, previous_digest, acceptance_record, ci_url)


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
