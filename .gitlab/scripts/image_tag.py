#!/usr/bin/env python3
"""Give the image main CI published for a commit its version tag."""

import hashlib
import os
import re
import sys

import promotion
from promotion import ValidationError, require

VERSION = re.compile(r"v\d+\.\d+\.\d+\Z")
MANIFESTS = f"https://{promotion.REGISTRY}/v2/{promotion.REPOSITORY}/manifests/"


def validate_tag_context():
    """Only the push of a protected version tag in Custyard's own project tags
    an image. Tag protection (v*, Maintainers) is what stops other members:
    GitLab refuses their tag push, so no pipeline starts. Without it
    CI_COMMIT_REF_PROTECTED is false and this fails closed."""
    env = os.environ
    version = env.get("CI_COMMIT_TAG", "")
    source_sha = env.get("CI_COMMIT_SHA", "")
    require(env.get("CI_PROJECT_PATH") == promotion.REPOSITORY
            and env.get("CI_PIPELINE_SOURCE") == "push"
            and env.get("CI_COMMIT_REF_PROTECTED") == "true"
            and bool(VERSION.fullmatch(version)) and bool(promotion.SHA.fullmatch(source_sha)),
            "Images are tagged only by pushing a protected vMAJOR.MINOR.PATCH tag to Custyard's project")
    return version, source_sha


def digest_of(body):
    return "sha256:" + hashlib.sha256(body).hexdigest()


def tag_image(digest, version):
    """Point `version` at the manifest `digest` names by storing the same
    bytes under the tag, which is what `oras tag` does. An existing version
    tag is never moved. Returns False when the tag was already in place."""
    token = promotion.registry_token(push=True)
    read = {"Authorization": "Bearer " + token, "Accept": promotion.MANIFEST_TYPES}
    body = promotion.read_bytes(MANIFESTS + digest, read)
    media_type = promotion.verify_hash(body, digest).get("mediaType")
    require(media_type in promotion.MANIFEST_MEDIA_TYPES, "Published image manifest has an unsupported media type")
    existing = promotion.read_bytes(MANIFESTS + version, read, missing_ok=True)
    if existing is not None:
        require(digest_of(existing) == digest, "Version tag already points at a different image; version tags are never moved")
        return False
    promotion.read_bytes(MANIFESTS + version, {"Authorization": "Bearer " + token, "Content-Type": media_type},
                         method="PUT", data=body)
    require(digest_of(promotion.read_bytes(MANIFESTS + version, read)) == digest,
            "Registry does not report the version tag on the published image")
    return True


def main():
    version, source_sha = validate_tag_context()
    digest, ci_url = promotion.published_digest(source_sha)
    promotion.validate_image(digest, source_sha)
    created = tag_image(digest, version)
    print(f"{'Tagged' if created else 'Already tagged'}: {promotion.IMAGE}:{version}")
    print(f"Deploy by digest: {promotion.IMAGE}@{digest}\nSource: {source_sha}\nCI: {ci_url}")


def cli():
    try:
        main()
        return 0
    except ValidationError as error:
        print("Image tag rejected: " + str(error), file=sys.stderr)
        return 1
    except Exception:
        # As in promotion.py: never print exceptions, response bodies or
        # signed URLs on the runner.
        print("Image tag rejected: registry or CI metadata could not be verified", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(cli())
