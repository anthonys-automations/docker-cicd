#!/usr/bin/env bash
#
# Allocate the next release version for a Docker Hub repository.
#
# Prints "YYYY.MM.DD.N" on stdout; the caller appends the architecture suffix
# when tagging. Diagnostics go to stderr so callers can capture the version
# directly. See renovate.example/image-versioning.md for the tag contract.
#
# Fails closed: only an authenticated registry-confirmed "repository does not
# exist" (404 on the first listing call) may be read as an empty tag list. A
# degraded listing that hides an existing tag would otherwise allocate a version
# that sorts older than a published release - the availability check at the end
# only catches an exact collision, not a stale allocation.
#
# Usage: allocate-version.sh <namespace/repository> <arch>

set -euo pipefail

readonly API='https://hub.docker.com/v2/repositories'
readonly RETRIES=3

log() { printf '%s\n' "$*" >&2; }
die() { log "$*"; exit 1; }

HTTP_STATUS=''
HTTP_BODY=''
HUB_TOKEN=''
CURL_HEADERS=()

# Private Docker Hub repositories also return 404 to anonymous callers, so
# authenticate when credentials are provided before trusting a 404 response.
authenticate() {
  local response

  if [[ -z ${DOCKERHUB_USERNAME:-} && -z ${DOCKERHUB_TOKEN:-} ]]; then
    return 0
  fi
  [[ -n ${DOCKERHUB_USERNAME:-} && -n ${DOCKERHUB_TOKEN:-} ]] \
    || die "DOCKERHUB_USERNAME and DOCKERHUB_TOKEN must be set together"

  response=$(curl -sS --fail-with-body --max-time 30 \
    --request POST "${API}/users/login" \
    --header 'Content-Type: application/json' \
    --data "$(jq -cn --arg username "${DOCKERHUB_USERNAME}" --arg password "${DOCKERHUB_TOKEN}" '{username: $username, password: $password}')") \
    || die "cannot authenticate to Docker Hub"
  HUB_TOKEN=$(jq -er '.token' <<<"${response}") \
    || die "Docker Hub authentication response did not contain a token"
  CURL_HEADERS=(--header "Authorization: JWT ${HUB_TOKEN}")
}

# Returns 0 only for a definitive 200 or 404; anything else is retried and then fatal.
http_get() {
  local url=$1 response attempt
  for (( attempt = 1; attempt <= RETRIES; attempt++ )); do
    if response=$(curl -sS --max-time 30 "${CURL_HEADERS[@]}" -w $'\n%{http_code}' "${url}" 2>&1); then
      HTTP_STATUS=${response##*$'\n'}
      HTTP_BODY=${response%$'\n'*}
      case "${HTTP_STATUS}" in
        200|404) return 0 ;;
      esac
      log "attempt ${attempt}/${RETRIES}: HTTP ${HTTP_STATUS} from ${url}"
    else
      log "attempt ${attempt}/${RETRIES}: request to ${url} failed: ${response}"
    fi
    (( attempt < RETRIES )) && sleep $(( attempt * 2 ))
  done
  return 1
}

main() {
  local repo=${1:-} arch=${2:-}
  [[ -n ${repo} && -n ${arch} ]] || die "usage: ${0##*/} <namespace/repository> <arch>"
  command -v curl >/dev/null || die "curl is required"
  command -v jq >/dev/null || die "jq is required"
  authenticate

  local date pattern url names next
  local highest=0 page=1

  date=$(date -u +'%Y.%m.%d')
  pattern="^${date//./\\.}\.([0-9]+)-${arch}$"
  # Server-side name filter, so a long tag history is not paged through in full.
  url="${API}/${repo}/tags?page_size=100&name=${date}."

  while [[ -n ${url} ]]; do
    http_get "${url}" || die "cannot list tags for ${repo}: gave up after ${RETRIES} attempts"

    if [[ ${HTTP_STATUS} == 404 ]]; then
      (( page == 1 )) || die "tag listing for ${repo} returned 404 on page ${page}; refusing to allocate"
      log "repository ${repo} does not exist yet"
      break
    fi

    names=$(jq -r '[.results[]?.name] | .[]' <<<"${HTTP_BODY}") \
      || die "malformed tag listing for ${repo} (page ${page})"

    while read -r name; do
      if [[ ${name} =~ ${pattern} ]] && (( BASH_REMATCH[1] > highest )); then
        highest=${BASH_REMATCH[1]}
      fi
    done <<<"${names}"

    next=$(jq -r '.next // ""' <<<"${HTTP_BODY}") || die "malformed tag listing for ${repo} (page ${page})"
    url=${next}
    page=$(( page + 1 ))
  done

  local version="${date}.$(( highest + 1 ))"

  http_get "${API}/${repo}/tags/${version}-${arch}" \
    || die "cannot verify availability of ${repo}:${version}-${arch}"
  [[ ${HTTP_STATUS} == 404 ]] \
    || die "tag ${repo}:${version}-${arch} already exists; refusing to overwrite a release"

  log "allocated ${repo}:${version}-${arch}"
  printf '%s\n' "${version}"
}

main "$@"
