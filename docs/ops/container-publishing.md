# Publishing container images

The GitLab CI pipeline publishes
`registry.gitlab.com/custyard/custyard:sha-<full-commit-sha>` after a push to
`main` passes the `test`, `turso`, `release`, and `security` jobs. It builds
the production release from `Containerfile` for `linux/amd64`. The image
records the commit as an OCI label.

Merge request and manual pipelines build and smoke-test the image in the
`container` job without logging in to the registry or publishing. Scheduled
pipelines do not build or publish images. Publishing does not deploy to Fly or
Bunny.

Images published before the move to GitLab remain at
`ghcr.io/custyard/custyard`. New builds are not published there.

## Authentication

The `publish` job logs in with the pipeline's predefined `CI_REGISTRY_USER`
and `CI_REGISTRY_PASSWORD`. No personal token or CI/CD variable is required.
Only `publish` logs in: the `container` job reads the build cache
(`registry.gitlab.com/custyard/custyard:buildcache`) anonymously, so merge
request pipelines cannot write the cache that `publish` builds from.

The project is public, so its registry allows anonymous pulls. Bunny's
registry form still requires a username and token: give it a deploy token
with only the `read_registry` scope. If the project or its registry becomes
private, give Fly one too. Do not save the pipeline's short-lived job token in
Bunny or Fly.

See GitLab's [container registry](https://docs.gitlab.com/user/packages/container_registry/)
and [registry authentication](https://docs.gitlab.com/user/packages/container_registry/authenticate_with_container_registry/)
documentation.

## Selecting an image for deployment

The `publish` job log prints the commit tag and the exact image digest. Its
`published-image.json` artifact, kept for 90 days, records the digest, source
commit, pipeline ID and job ID. Use the digest when promoting between staging
and production:

```text
registry.gitlab.com/custyard/custyard@sha256:<digest-from-the-publish-job>
```

A commit tag can be rebuilt with newer base images or system packages on a
retry, changing its digest. Record each deployed digest for promotion and
rollback. The pipeline does not maintain a moving `latest` tag. The project's
registry cleanup policy is disabled, so old versions are kept.

## Version tags

Pushing a git tag such as `v1.2.3` runs only the `image-tag` job. It adds the
version as a tag on the image `publish` already built for that commit, so
`registry.gitlab.com/custyard/custyard:v1.2.3` and `:sha-<commit>` share one
digest. Nothing is rebuilt or retested:

```sh
git tag -a v1.2.3 -m "v1.2.3" <commit-on-main>
git push gitlab v1.2.3
```

The job fails if the commit has no published `sha-<commit>` image (tag a
commit whose `main` pipeline published one) or if the version tag already
points at a different digest. Only tags matching `vMAJOR.MINOR.PATCH` start a
pipeline. To tag by hand instead, `oras tag
registry.gitlab.com/custyard/custyard@sha256:<digest> v1.2.3` after `oras login
registry.gitlab.com` with a token that has `write_registry`.

## Promotion

The promotion jobs in `.gitlab-ci.yml` deploy a published digest to Fly
staging or Bunny production after checking it against this job's record. See
[Bunny setup](bunny-setup.md) for inputs, gates and required variables. Images
built before the move to GitLab carry the GitHub source label and cannot be
promoted.

## Failed publishes

Retry the failed `publish` job from its pipeline after resolving the cause. A
failed prerequisite job prevents publishing. Manual pipelines (Build >
Pipelines > Run pipeline) build the image in the `container` job but do not
publish, even on `main`. Merge request pipelines cannot verify registry write
access; the first push to `main` after a registry change exercises it.
