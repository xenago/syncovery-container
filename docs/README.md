# Documentation

Development and release info, plus migration steps for an existing Syncovery deployment.

## Development and releases

Automated updates target the `dev` branch.
A release is published by merging `dev` into `main` and pushing a version tag,
so a push to `main` never cuts a new release on its own.

### Workflows

- `update-syncovery.yml` runs weekly (Monday 07:30 UTC).
  It creates `dev` from the default branch if missing, detects the newest Syncovery release with
  `sc_version_detector.sh`, and opens a pull request bumping `SYNCOVERY_VERSION` in the Dockerfile against `dev`.
- Dependabot runs 30 minutes afterwards, opening Docker base image and GitHub Actions updates against `dev`.
- `build.yml` builds the image natively for `linux/amd64` and `linux/arm64` and smoke-tests the
  stack.
- PRs into `dev` and manual runs validate the build and smoke test only.
- A semver tag pushed to `main` builds, tests, pushes, and publishes a release.

### Initial repository setup

- Enable `Allow GitHub Actions to create and approve pull requests` under
  `Settings > Actions > General > Workflow permissions` so the update workflow can open PRs.
- Enable Dependabot alerts and security updates under `Settings > Advanced Security`.
- Enable `Private vulnerability reporting` under `Settings > Advanced Security` for the
  [SECURITY.md](SECURITY.md) process.

### Cutting a release

1. Prepare a stable commit on `dev`.
2. Merge from `dev` to `main`.
3. Tag the release commit with the Syncovery version and push the tag:

       git tag 11.16.4
       git push origin 11.16.4

`build.yml` publishes the version tag and a commit-sha tag, and updates `latest` only when the
pushed tag is the highest version, so tagging an older release later never rolls `latest`
backwards. The tag must point at a commit on `main`, or the workflow refuses to publish.
A GitHub Release is created for the tag with the image pull commands.

The image in this repo publishes to `ghcr.io/xenago/syncovery-container` using the built-in
`GITHUB_TOKEN`. The package visibility can be set after the first tagged publish creates it.

## Migrating an existing deployment

An existing Syncovery install keeps its configuration and jobs under a `.Syncovery` directory in
the service account's home. To migrate onto this stack:

1. Back up the existing Syncovery configuration.
2. Stop the old Syncovery instance so no jobs run during the copy.
3. Copy the existing `.Syncovery` directory into the container's config volume so it lands at
   `/config/.Syncovery` (default host path `./data/config/.Syncovery`):

       mkdir -p ./data/config
       cp -a <old_home>/.Syncovery ./data/config/.Syncovery

4. Mount the paths the jobs use. Add any required local paths to the `volumes`
   for `syncovery-container` in `docker-compose.yml`, e.g.:

         volumes:
           - /srv/data:/srv/data:ro     # read-only
           - /backups:/backups          # fully-writable

5. Provide the `machine-id`. Syncovery encrypts stored passwords with the host machine-id,
   so the new container must reuse the source machine's id to keep those credentials working.
   Copy it into the bind-mounted file before first start.
   For example, if run on the same host:

       cp /etc/machine-id ./data/machine-id

   For a fresh install or a non-Linux source, instead create an empty file with
   `touch ./data/machine-id` and let the container generate a new id;
   any credentials carried over from the old install must then be re-entered in the Syncovery web UI.
6. Start the stack and confirm the jobs and settings are present:

       docker compose up -d
       docker compose logs -f

Back up both the `/config` data and the machine-id file as part of any ongoing backup strategy.
