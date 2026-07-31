#!/usr/bin/env bash
# Smoke coverage requested for the allocator's public-repository and absent-
# repository paths; run manually or from CI without changing registry state.

set -euo pipefail

readonly REPO=${1:-anthonysautomations/github-runner}
readonly ARCH=${2:-arm64}
DATE=$(date -u +'%Y.%m.%d')
readonly DATE
readonly MISSING_REPO="anthonysautomations/renovate-allocator-test-${RANDOM}-${RANDOM}"

version=$(./scripts/allocate-version.sh "${REPO}" "${ARCH}")
[[ ${version} =~ ^${DATE//./\\.}\.[1-9][0-9]*$ ]] \
  || { printf 'unexpected allocated version: %s\n' "${version}" >&2; exit 1; }

missing_version=$(./scripts/allocate-version.sh "${MISSING_REPO}" "${ARCH}")
[[ ${missing_version} == "${DATE}.1" ]] \
  || { printf 'unexpected absent-repository version: %s\n' "${missing_version}" >&2; exit 1; }

printf 'allocator smoke test passed: %s and %s\n' "${version}" "${missing_version}"