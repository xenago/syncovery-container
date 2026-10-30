# Documentation

Development and release info, plus migration steps for an existing Syncovery deployment.

## Development and releases

Automated updates target the `dev` branch.
A release is published by merging the release PR from `dev` into `main`, which tags the new
Syncovery version automatically; a push to `main` that doesn't change the version never cuts a
release on its own.

### Workflows

- `update-syncovery.yml` runs daily (07:30 UTC).
  It creates `dev` from the default branch if missing, detects the newest Syncovery release with
  `sc_version_detector.sh`, and opens a pull request bumping `SYNCOVERY_VERSION` in the Dockerfile against `dev`.
- Dependabot runs 30 minutes afterwards, opening Docker base image and GitHub Actions updates against `dev`.
- `release-pr.yml` opens or updates a pull request from `dev` to `main` whenever `dev` changes.
- `tag-release.yml` tags `main` with the Dockerfile's Syncovery version (if untagged) and starts the release build.
- `build.yml` builds the image natively for `linux/amd64` and `linux/arm64` and smoke-tests the stack.
- PRs into `dev` and manual runs validate the build and smoke test only.
- A version tag pushed to `main` builds, tests, pushes, and publishes a release.

### Initial repository setup

- Enable `Allow GitHub Actions to create and approve pull requests` under
  `Settings > Actions > General > Workflow permissions` so the update and release-PR workflows can open PRs.
- Enable `Automatically delete head branches` and `Allow auto-merge` under `Settings > General`.
- Add the rulesets under [Branch and tag rules](#branch-and-tag-rules).
- Enable Dependabot alerts and security updates under `Settings > Advanced Security`.
- Enable `Private vulnerability reporting` under `Settings > Advanced Security` for the
  [SECURITY.md](SECURITY.md) process.

### Branch and tag rules

Configured under `Settings > Rules > Rulesets`.

`main` (branch ruleset on the default branch):

- Bypass list: `Repository admin`, `Always`, for urgent direct pushes.
- `Restrict deletions`, `Block force pushes`, and `Require linear history`.
- `Require a pull request before merging`, 0 approvals, `Squash` as the only merge method.
- No required status checks, since `build.yml` only runs on pull requests into `dev`.

`dev` (branch ruleset), so auto-merge waits for the test build:

- `Block force pushes`.
- `Restrict deletions` unchecked, since `dev` is deleted after each release.
- `Require status checks to pass` with `build (linux/arm64)` and `smoke`, plus
  `Do not require status checks on creation` so the update workflow can recreate `dev`.

Release tags (tag ruleset on all tags):

- Bypass list: `Repository admin`, `Always`, so a tag can be moved for a [re-release](#re-releasing-a-version).
- `Restrict updates`, `Restrict deletions`, and `Block force pushes`.
- `Restrict creations` unchecked, since `tag-release.yml` creates the tags.

### Cutting a release

1. Prepare `dev`: approve the update PR and squash-merge it once the build and smoke test pass
   (or enable auto-merge after approving).
2. Merge to `main`: squash-merge the PR `release-pr.yml` opened, then delete `dev` (the squash
   leaves it behind `main`; the update workflow recreates it). Merge or close other `dev` PRs
   first, or GitHub retargets them to `main`.
3. `tag-release.yml` tags `main` with the Dockerfile's version and starts the build. To tag by
   hand instead: `git tag 11.16.4 && git push origin 11.16.4`.

`build.yml` publishes the version tag and a commit-sha tag, and updates `latest` only when the
pushed tag is the highest version, so tagging an older release later never rolls `latest`
backwards. The tag must point at a commit on `main`, or the workflow refuses to publish.
A GitHub Release is created for the tag with the image pull commands.

The image in this repo publishes to `ghcr.io/xenago/syncovery-container` using the built-in
`GITHUB_TOKEN`. The package visibility can be set after the first tagged publish creates it.

### Re-releasing a version

To publish a change without a new Syncovery version (for example to update the base image or
configs), move the existing tag to the new `main` commit:

    git push origin :refs/tags/11.16.4
    git tag -f 11.16.4
    git push origin 11.16.4

Release builds skip the cache, so re-running picks up current Debian packages.

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
