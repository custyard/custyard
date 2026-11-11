# Publishing container images to GHCR

The CI workflow publishes `ghcr.io/custyard/custyard:sha-<full-commit-sha>`
after a push to `main` passes the `test`, `turso`, `release`, and `security`
jobs. It builds the production release from `Containerfile` for `linux/amd64`.
The image records the source repository and commit as OCI labels.

Pull requests and manual workflow runs build the image without logging into
GHCR or publishing. Scheduled security checks do not build or publish images.
Publishing does not deploy to Fly or Bunny.

## Authentication and package setup

The publishing job uses GitHub's generated `GITHUB_TOKEN` with job-scoped
`contents: read` and `packages: write`. No personal token or new repository
secret is required for publishing. The repository/organization must allow
Actions to create packages.

The first successful push creates the GHCR package and associates it with this
repository. New packages are private by default, even for a public source
repository. Choose visibility explicitly in package settings. If the package
already exists, grant this repository Actions access before publishing; a
manually created package might not have that association.

See GitHub's [publishing guide](https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images)
and [container registry permissions](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry).

## Selecting an image for deployment

The publishing job's summary records the commit tag and exact image digest.
Use the digest when promoting between staging and production:

```text
ghcr.io/custyard/custyard@sha256:<digest-from-the-publish-summary>
```

A commit tag can be rebuilt with newer base images or system packages on a
rerun, changing its digest. Record each deployed digest for promotion/rollback.
The workflow does not maintain a moving `latest` tag or delete old versions.

For private pulls outside Actions, configure the host's registry connection
with a GitHub username and classic personal access token with `read:packages`
and package access. Authorize organization SSO if required. Public images allow
anonymous pulls. Do not save Actions' short-lived `GITHUB_TOKEN` in Bunny or Fly.

## Failed publishes

Open the failed CI run and rerun the publishing job after resolving its cause.
A failed prerequisite prevents publishing. Manual dispatch validates a build
but intentionally does not publish, even on `main`. The pull-request build
cannot verify registry access; the first eligible push to `main` exercises
publishing credentials and package permissions.
