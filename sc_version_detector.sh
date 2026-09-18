#!/bin/bash

#
# Syncovery version upgrade detector script
#
# - Reads the offical per-architecture "latest version" pointer files
# - Outputs the newest version as the last line of stdout, if the Dockerfile is outdated.
# - If no update is available/required, nothing is output on stdout.
# - Exit codes other than 0 indicate failure.
# - Note: see currently published releases at https://www.syncovery.com/syncovery11linux/
#
# Super Flexible Software GmbH publishes the latest version and download URL per architecture at:
#   https://www.syncovery.com/linver_x86_64-Web.tar.gz.txt   (amd64)
#   https://www.syncovery.com/linver_aarch64-Web.tar.gz.txt  (arm64)
# In each file, line 3 is the download URL, line 5 is the version, and line 7 is a SHA256, e.g.:
# ```
# 220
# 
# https://www.syncovery.com/release/SyncoveryCL-x86_64-11.16.2-Web.tar.gz
# %TEMP%/SyncoveryCL-x86_64-11.16.2-Web.tar.gz
# 11.16.2
# 11.16.2 has been released.
# ea634680385c4d242193c3aabe151fe6d465f93ed6e42e78bf54544b027034e9
# ```
#
# Optional environment variables:
#   SC_CURRENT_VERSION  Version to compare against. Default: parsed from the Dockerfile.
#   SC_MAJOR            Pin to a single major line (e.g. "11").
#                       When set, a latest release with a different major version is not proposed.
#                       Default: unset (track latest).
#                       Note: the vendor pointer file only contains the newest version per arch,
#                       so this blocks a major upgrade, but doesn't detect patches for an older branch.
#   SC_AMD64_URL        amd64 version pointer file. Default: the vendor URL above.
#   SC_ARM64_URL        arm64 version pointer file. Default: the vendor URL above.
#   SC_RELEASE_BASE     Base for the release download URL. Default: https://www.syncovery.com/release
#   SC_POINTER_OUT      Optional file path. When set and an update is proposed, the vendor pointer
#                       details for the new release are written there for the update workflow & PR.
#

# Abort on error
set -euo pipefail

# Define environment variable inputs with fallback defaults
: "${SC_AMD64_URL:=https://www.syncovery.com/linver_x86_64-Web.tar.gz.txt}"
: "${SC_ARM64_URL:=https://www.syncovery.com/linver_aarch64-Web.tar.gz.txt}"
: "${SC_RELEASE_BASE:=https://www.syncovery.com/release}"
# Parse existing version from SYNCOVERY_VERSION in the Dockerfile if not provided
: "${SC_CURRENT_VERSION:=$(grep -m1 -oP '^\s*ARG\s+SYNCOVERY_VERSION=\K[0-9]+(\.[0-9]+)+' Dockerfile 2>/dev/null || true)}"
# Optional major-version pin; empty means track the latest overall
: "${SC_MAJOR:=}"

# Fetch the vendor version pointer for each architecture
amd64_info="$(curl -fsSL "$SC_AMD64_URL")" || { echo "ERROR: could not fetch ${SC_AMD64_URL}" >&2; exit 1; }
arm64_info="$(curl -fsSL "$SC_ARM64_URL")" || { echo "ERROR: could not fetch ${SC_ARM64_URL}" >&2; exit 1; }

# The version string is on line 5 of each pointer file
latest="$(printf '%s\n' "$amd64_info" | awk 'NR==5' | tr -d '[:space:]')"
arm_latest="$(printf '%s\n' "$arm64_info" | awk 'NR==5' | tr -d '[:space:]')"

if ! printf '%s' "$latest" | grep -qE '^[0-9]+(\.[0-9]+)+$'; then
  echo "ERROR: could not parse a version from ${SC_AMD64_URL}" >&2
  exit 1
fi

# Both architectures must advertise the same version, or a multi-arch build would not be viable
if [ "$latest" != "$arm_latest" ]; then
  echo "ERROR: amd64 (${latest}) and arm64 (${arm_latest}) versions differ; not proposing an update" >&2
  exit 2
fi

# If pinned to a major line, do not propose a release on a different major
if [ -n "$SC_MAJOR" ] && [ "${latest%%.*}" != "$SC_MAJOR" ]; then
  echo "Latest release ${latest} is outside the pinned major ${SC_MAJOR}; nothing to do." >&2
  exit 0
fi

# Emit nothing on stdout if it's already current
if [ -n "$SC_CURRENT_VERSION" ] && [ "$SC_CURRENT_VERSION" = "$latest" ]; then
  echo "Already up to date (${SC_CURRENT_VERSION})." >&2
  exit 0
fi

# Don't propose a downgrade
if [ -n "$SC_CURRENT_VERSION" ]; then
  newer="$(printf '%s\n%s\n' "$SC_CURRENT_VERSION" "$latest" | sort -V | tail -n 1)"
  if [ "$newer" != "$latest" ]; then
    echo "Current version ${SC_CURRENT_VERSION} is newer than the latest found (${latest}); nothing to do." >&2
    exit 0
  fi
fi

# Check all the download URLs seem to work before proposing the bump
for arch in x86_64 aarch64; do
  url="${SC_RELEASE_BASE}/SyncoveryCL-${arch}-${latest}-Web.tar.gz"
  if ! curl -fsIL -o /dev/null "$url"; then
    echo "ERROR: constructed URL is not reachable: ${url}" >&2
    exit 3
  fi
done

# Optionally record the vendor pointer details for the proposed release, for the update PR body.
# Parsed from the same pointer files fetched above: line 3 = release URL, line 6 = announcement, line 7 = SHA256.
if [ -n "${SC_POINTER_OUT:-}" ]; then
  announcement="$(printf '%s\n' "$amd64_info" | sed -n '6p' | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  amd64_rel_url="$(printf '%s\n' "$amd64_info" | sed -n '3p' | tr -d '[:space:]')"
  amd64_sha="$(printf '%s\n' "$amd64_info" | sed -n '7p' | tr -d '[:space:]')"
  arm64_rel_url="$(printf '%s\n' "$arm64_info" | sed -n '3p' | tr -d '[:space:]')"
  arm64_sha="$(printf '%s\n' "$arm64_info" | sed -n '7p' | tr -d '[:space:]')"
  {
    echo "SC_NEW_VERSION=${latest}"
    echo "SC_ANNOUNCEMENT=${announcement}"
    echo "SC_AMD64_URL=${amd64_rel_url}"
    echo "SC_AMD64_SHA256=${amd64_sha}"
    echo "SC_ARM64_URL=${arm64_rel_url}"
    echo "SC_ARM64_SHA256=${arm64_sha}"
  } > "$SC_POINTER_OUT"
fi

echo "Current version: ${SC_CURRENT_VERSION:-unknown}" >&2
echo "New version available: ${latest}" >&2
echo "${latest}"
exit 0
