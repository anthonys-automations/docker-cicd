# Container image versioning: design and implementation guide

A portable description of the tag strategy used by this repository, written so it
can be re-implemented for a different product without reading the code.

---

## 1. When this design applies

Use it when **all** of the following hold:

- Images are rebuilt on a schedule, and most releases contain no source change —
  what actually moves is the upstream base image and its packages.
- Builds are unattended: no human picks a version number or approves a release.
- A **separate** repository (typically Kubernetes manifests) consumes the images
  and wants an automated updater such as Renovate to advance them.
- More than one CPU architecture is published, and the architectures are **not**
  built in lockstep — e.g. amd64 is automated in CI while arm64 is built manually
  on an irregular schedule.

If images are built in lockstep for all architectures in a single pipeline, the
architecture-suffix part of this design is unnecessary; publish a single
multi-architecture manifest per release instead.

---

## 2. The core problem

An automated updater needs a version that is:

1. **New whenever image contents change** — otherwise a security rebuild is
   invisible and never gets deployed.
2. **Totally ordered** — otherwise the updater cannot tell newer from older.
3. **Immutable** — otherwise the deployed artefact silently changes underneath a
   pinned reference, and there is nothing to raise a pull request against.
4. **Architecture-aware** — otherwise an amd64-only build can be offered to an
   arm64 cluster.

### Rejected alternatives

| Approach | Why rejected |
| --- | --- |
| `latest` only | Mutable. Nothing for the updater to diff, no rollback target, no audit trail. |
| Upstream application package version (e.g. `1.11.2-r3`) | Does not change when a *transitive* dependency is patched. `openssl`/`musl` can receive a CVE fix while the primary package version is unchanged, producing a different image with no new version. |
| Git commit SHA | Not ordered, and does not change at all for a scheduled rebuild of unchanged source — which is the majority of releases. |
| Second-resolution build timestamp (`2026-07-30T14-22-05Z`) | Works, but is more precision than needed, awkward to read and type, and needs custom parsing to sort. |
| Monotonic integer build counter | Ordered and unique, but carries no information; requires external state to allocate. |
| Semantic versioning | Meaningless here. There is no API surface and no human deciding major/minor/patch. |

### Chosen approach

A **calendar version with a daily sequence number and an architecture suffix**,
with exact upstream versions relegated to metadata.

The date changes on every rebuild, which is precisely the event that matters. The
sequence disambiguates same-day rebuilds. The suffix keeps architectures in
separate update streams. Package versions stay inspectable without polluting the
sortable identifier.

---

## 3. Tag contract

```text
<YYYY>.<MM>.<DD>.<N>[-<arch>]
```

| Field | Meaning |
| --- | --- |
| `YYYY.MM.DD` | UTC date of the build |
| `N` | 1-based sequence within that date and architecture |
| `arch` | `amd64`, `arm64`, … — omitted for multi-architecture manifests |

Example: `2026.07.30.1-amd64`

### Published tags

| Tag | Mutability | Role |
| --- | --- | --- |
| `2026.07.30.1-amd64` | immutable | deployable release, pinned by consumers |
| `2026.07.30.1-arm64` | immutable | deployable release, pinned by consumers |
| `latest-<arch>` | moving | human convenience only, never deployed |
| `latest` / unsuffixed version | reserved | promoted multi-architecture manifest |

### Rules

1. **Release tags are never overwritten.** The build must verify the tag is unused
   and abort otherwise.
2. **Each architecture allocates versions independently.** A manual arm64 build
   made weeks after an amd64 build resolves different package contents; giving it
   the amd64 version would assert an equivalence that does not exist.
3. **Single-architecture pipelines never publish unsuffixed tags.** Those are
   reserved for a manifest that genuinely contains every architecture, so a
   mixed-architecture cluster cannot receive an image that only runs on some of
   its nodes.
4. **All timestamps are UTC**, so builds from different regions order correctly.

---

## 4. Version allocation algorithm

Runs immediately before each build.

```text
INPUT:  repository, arch
OUTPUT: version string, or failure

date  := current UTC date, formatted YYYY.MM.DD
tags  := registry tags for `repository` whose name starts with `date.`
         (use a server-side name filter to avoid paging full tag history)

highest := 0
for each tag matching ^<date>\.([0-9]+)-<arch>$:
    highest := max(highest, captured integer)

version := date + "." + (highest + 1)

# Immutability guard: a failed or partial listing above must never cause an
# existing release to be silently overwritten.
status := registry lookup of `repository:version-arch`
if status == NOT_FOUND: return version
if status == FOUND:     fail "tag already exists"
otherwise:              fail "cannot verify tag availability"
```

Notes:

- **Fail closed on the listing step, not just the existence check.** Only a
  registry-confirmed "repository does not exist" response (e.g. HTTP 404) may be
  treated as an empty tag list. Any other non-success response, malformed body,
  or network failure must abort — treating it as empty is unsafe: if a real tag
  (e.g. `.2`) is invisible to a degraded listing call, the allocator can compute
  `.1`, find `.1` unused via the existence check, and publish a release that
  sorts *older* than one that already exists. The trailing existence check only
  protects against re-publishing the exact same version; it does not protect
  against allocating a stale one.
- Retry the registry calls a few times for transient network errors; once
  retries are exhausted, a non-success response is fatal, not "treat as empty".
- Serialise builds **per (product, architecture)** in CI so two concurrent runs
  cannot allocate the same sequence number. Note the existence check does *not*
  substitute for this: it runs at allocation time, not at push time, so two
  overlapping runs can both see a version as free. If manual builds are frequent
  or run by several people, add a lock; if they are rare and single-operator,
  accepting the race is a reasonable trade.
- Diagnostics go to stderr; only the version goes to stdout, so callers can
  capture it directly.

---

## 5. Image metadata

The tag stays short; provenance lives in labels plus an SBOM attestation.

```text
org.opencontainers.image.title       service name
org.opencontainers.image.version     allocated version (no arch suffix)
org.opencontainers.image.revision    source commit SHA
org.opencontainers.image.source      source repository URL
org.opencontainers.image.created     RFC 3339 UTC build time
<ns>.<product>.base.version          pinned base image version
```

Additionally, the commit is baked in as a **`GIT_COMMIT` environment variable**
via a build argument, so a running container can be traced to source without
registry access (`kubectl exec <pod> -- printenv GIT_COMMIT`). Treat this, and
the `revision` label, as **best-effort, not authoritative**: an environment
variable can be overridden by a pod/container spec, and it is only correct in
the first place if the build was made from a clean working tree (see §6 on
refusing dirty manual builds). For a binding audit record, use the immutable
image digest.

Two implementation details matter:

- **Declare the `ARG`/`ENV` after the package-installation layers.** The commit
  changes on every build; placing it early invalidates the dependency cache for
  every rebuild.
- **Give the `ARG` a default** (`unknown`) so an ad-hoc local build still works.

Have both the CI build summary and the manual script print a **registry link to
the exact published tag** (e.g. `https://hub.docker.com/layers/<ns>/<image>/<tag>/`).
Releases here are unattended and machine-named, so the one thing a human needs
afterwards is a one-click route from the run to the artefact it produced.

### Package inventory: prefer SBOM over an independent lookup

Do **not** determine installed package versions by querying a separately pulled
copy of the base image before the build starts. That query and the actual build
can resolve different package-index snapshots — Alpine's (or any distro's)
package index is mutable, so "the same base image tag" can serve different
package versions minutes apart. A label populated this way can describe an image
other than the one actually pushed.

Instead, enable an **SBOM attestation** on the build itself (e.g.
`docker buildx build --sbom=true`, or `sbom: true` for
`docker/build-push-action`). This is generated by BuildKit from the exact image
being pushed, with no separate query and no drift window. Consumers inspect it
with `docker buildx imagetools inspect --format '{{ json .SBOM }}' <ref>`. The
base image *pin* (e.g. `alpine:3.22.1`) is still safe to read directly from the
Dockerfile and record as a label — that value is static source, not something
resolved against a live, mutable index.

If your registry/CI tooling has no SBOM support, treat the trade-off explicitly:
either accept an independent, best-effort, clearly-labelled-as-approximate
package-version lookup with the same `unknown`-on-failure fallback used
elsewhere in this design, or omit the label rather than presenting an
unverified value as fact.

Avoid `command | head -n1` under `set -o pipefail` in any shell metadata
extraction — the early `head` exit can deliver `SIGPIPE` and fail the build.
Capture output into a variable and take the first line with parameter expansion
instead.

---

## 6. Component inventory

| Component | Responsibility |
| --- | --- |
| Version allocator script | Implements §4. Shared verbatim by CI and manual builds so both obey one contract. |
| Reusable CI workflow | Automated build for the CI-native architecture: allocate version, collect metadata, build, push release tag + moving alias. |
| Per-service CI wrappers | Triggers only (schedule / manual / change detection); pass just the service name — derive the registry repository and any other per-service input from it wherever they follow the same pattern, to avoid inputs that only ever repeat the service name. |
| Build-only validation workflow | Manually dispatchable build of every service without publishing; supplies the check that gates automerge on updater branches (§7). |
| Manual build script | Same steps for the non-CI architecture, runnable from a workstation. |
| Dockerfiles | Pinned base image; late `ARG GIT_COMMIT` / `ENV GIT_COMMIT`. |
| Base-image updater config | Renovate (or equivalent) bumping the pinned base image and CI action versions. |
| Updater bot workflow | Scheduled run of that updater against this repository, with a token whose capabilities are chosen per §7. |

Keeping the allocator as a **script rather than inline CI steps** is the key
structural decision: it is what makes the manual architecture reproduce CI
behaviour exactly.

The manual script should additionally:

- Validate dependencies and that the builder supports the target platform.
- Accept credentials via environment variables and pipe them to `docker login`
  through stdin, never as command-line arguments.
- **Refuse to publish when the working tree is dirty** (tracked or untracked
  changes in the build context), rather than merely warning — a mismatched
  recorded commit undermines the entire audit-trail purpose of §5. Provide an
  explicit, opt-in override (e.g. an `ALLOW_DIRTY` environment variable) for
  cases where that mismatch is knowingly acceptable.
- Derive the source URL from the checkout rather than hard-coding it.

It need not serialise itself if manual builds are rare and single-operator (see
§4) — but that is a deliberate trade, not a property the existence check
provides for free.

---

## 7. Consumer configuration (Renovate)

```yaml
# renovate: datasource=docker depName=<registry>/<image> versioning=regex:^(?<major>\d{4})\.(?<minor>\d{2})\.(?<patch>\d{2})\.(?<build>\d+)(?:-(?<compatibility>amd64|arm64))?$
image: <registry>/<image>:2026.07.30.1-amd64
```

The suffix is captured as `compatibility`, which Renovate requires to match
between current and candidate versions. An amd64 deployment therefore only ever
sees amd64 updates. Each workload tracks the newest image its nodes can run,
rather than the newest image overall.

Consumers must pin immutable release tags. Deploying a moving alias defeats the
entire mechanism.

If a previous scheme published a plain, unsuffixed moving tag (e.g. a bare
`latest`) and it stops being updated when this design is introduced, treat that
as a **breaking change requiring migration**, not an implementation detail —
existing consumers must be repointed to an immutable, architecture-scoped tag
before the old one is allowed to go stale.

### Running the updater bot itself

The producer repository also runs the updater (here: self-hosted Renovate in a
scheduled workflow) to bump its own pinned base images and CI action versions.
Credentials are the part that bites:

- **The bot fails closed on a missing token.** Wiring the action to a
  `RENOVATE_TOKEN` secret that was never created does not degrade gracefully —
  the run aborts with `'token' MUST be passed using its input or the
  'RENOVATE_TOKEN' environment variable`, because an unset secret expands to an
  empty string. Either create the secret or reference the CI platform's built-in
  token explicitly; do not leave a dangling secret reference.
- **The built-in CI token works, with three documented limits.** Using
  `GITHUB_TOKEN` (plus `contents: write` and `pull-requests: write`
  permissions) needs no secret management, but (a) PRs it opens do not trigger
  other workflows, so automerge has no CI result to wait for, (b) it cannot
  write files under `.github/workflows`, so CI action bumps must be applied by
  hand, and (c) it cannot read the platform's vulnerability alerts — that is a
  GitHub App permission with no equivalent key in a workflow's `permissions:`
  block. Leave alert-driven updates (`vulnerabilityAlerts`) switched off unless
  a token that can actually read them is in use, otherwise every run logs a
  warning that no permission change can clear.
- **A PAT or app token buys back both**, at the cost of a credential to store
  and rotate. Choose deliberately and record which one is in use; the two behave
  differently enough that a reader cannot infer it from the workflow alone.
- **Grant the bot whatever its side effects need**, not just repository write:
  a dependency-dashboard issue requires issue-write permission, and without it
  the bot merely logs an authorization warning.

### Make automerge consistent with what the token can trigger

Automerge that waits for checks which will never run is automerge that never
happens — and it fails quietly: the run stays green, logging only that it
updated the branch, while the pull request sits open indefinitely.

If the bot uses the CI platform's built-in token, its pushes and pull requests
raise no workflow runs, so the branch has no check results at all. The fix is
not to switch automerge off or to skip tests — an unattended base-image bump is
exactly the change that should be built before it merges — but to trigger the
check deliberately:

1. **Provide a build-only validation workflow** that is manually dispatchable
   and does *not* publish. The release workflow must never run from an unmerged
   branch: it would allocate a version and push an image for code that was
   never merged.
2. **Dispatch it from the updater job** on every branch the bot owns, granting
   that job permission to start workflows. An API-triggered dispatch is exempt
   from the rule that suppresses runs for bot-authored pushes, so the resulting
   check does land on the branch head.
3. **Let the updater do the merge** once it sees that check pass. Delegating to
   the platform's auto-merge queue instead only works if the check is marked
   *required*, which needs branch protection.

The merge therefore happens on the run *after* the one that opened the branch,
which is fine for a weekly cadence. Skip re-dispatching when the branch head
already has a validation check, or every run queues a duplicate build.

The token limit bites once more on the CI-workflow manager: updates to files
under the workflow directory cannot be pushed at all. Route those to the
dependency dashboard for manual application rather than letting the bot retry a
push that is rejected on every run.

### Group updates so a run costs one validation build

Every branch the bot opens costs a dispatched validation build and a merge, so
group everything it may actually branch into a single branch and pull request.
Disable the updater's default split of major updates into their own branch
(`separateMajorMinor: false`) as well, or a major bump escapes the group.

Name the managers in that group explicitly rather than matching everything: the
CI-workflow manager has to stay outside it, because a change it cannot push
would fail the shared branch for every other update travelling with it.

Grouping also removes the need for the updater's PR rate limit, which is worth
switching off deliberately (`prHourlyLimit: 0`). Its default counts every PR
opened in the current clock hour — *including ones already closed*, such as the
per-dependency PRs pruned when a config moves to a single group. Once the limit
is reached the updater still creates the branch but silently skips the PR, and
because that is a `debug`-level event an `info`-level run shows only
`Branch created` and the log assertions above still pass. If a branch ever
exists without a pull request, check the dependency dashboard: rate-limited
updates are listed there with a checkbox that forces creation.

### The updater exits green when it does nothing

Renovate returns exit code 0 for repository-level failures — an invalid config
key, an auth rejection — so the scheduled job reports success while having made
no updates at all. A dependency updater that fails silently is worse than one
that is absent, because nobody looks at it again. Two guards close that gap:

1. **Validate the config before running.** Run the updater's own config
   validator (`renovate-config-validator --strict`) as a preceding step, so a
   malformed option fails the job outright. This also catches the trap that JSON
   has no comment syntax: an explanatory `"comment"` key is *not* ignored, it is
   rejected as an unknown option. Use the schema's own annotation field
   (`description`) instead.
2. **Assert on the run result afterwards.** Have the updater write a structured
   log (`LOG_FILE`) to a path shared with the runner, then fail the job if any
   record is at error level or the repository result is not the success value.
   Note the CI action only forwards an allow-listed set of environment variables
   into its container, so the log-file variables must be added to that list
   explicitly (`env-regex`) or no log appears.

Pin the validator and the run to the same updater version, otherwise the
validation step can accept config that the run rejects.

The same log is worth reusing for the job summary: emit a link for every pull
request the run created, updated or automerged. When updates merge unattended,
the run page is the only place an auditor can start from.

---

## 8. Failure modes and edge cases

| Situation | Required behaviour |
| --- | --- |
| Repository does not exist yet (registry confirms, e.g. HTTP 404) | Allocate `.1`; do not fail. |
| Registry listing fails, times out, or returns malformed data | Fail closed. Do not treat as empty — see §4. |
| Computed tag already exists | Abort. Never overwrite a release. |
| Two builds on the same day | Second gets `.2`. Serialise to prevent races. |
| SBOM/package inventory generation fails | Depends on tooling; must never silently produce a *wrong* value — omit or clearly mark as unavailable rather than fabricate. |
| Working tree is dirty at manual-build time | Abort by default; require an explicit opt-in to publish with mismatched provenance. |
| Base image pin unreadable | Abort — this indicates a malformed Dockerfile. |
| Updater bot token missing or unset | The bot aborts before doing any work. Reference a token that actually exists (§7). |
| Updater bot config invalid | The bot exits 0 having done nothing. Validate config in a preceding step and assert on the run result (§7). |
| Updater PR waits on checks that never run | Same silent stall. Dispatch a build-only validation workflow on the bot's branches so a real check reports (§7). |
| Updater branch exists but no PR was opened | Almost always the hourly PR rate limit, which is only logged at debug level. Switch it off or force creation from the dependency dashboard (§7). |
| One architecture lags behind | Expected. Each stream advances independently. |
| Clock skew across builders | Use UTC everywhere; sequence numbers absorb same-day disorder. |

---

## 9. Re-implementation checklist

Parameters to adapt for a new product:

1. Registry and namespace, and its **tag listing API** — this design uses Docker
   Hub's `/v2/repositories/{repo}/tags?name=<prefix>` filter. For GHCR, OCI
   `/v2/<name>/tags/list` with client-side filtering; for ECR,
   `describe-images`. Only §4's listing and existence steps change; whichever
   API is used, confirm what a "not found" response looks like versus a genuine
   error, so the two are not conflated (§4, §8).
2. Service list, and whether the registry/build tooling in use supports SBOM
   attestations (§5) for package inventory.
3. Base image and its pinning strategy.
4. Which architecture is automated and which is manual.
5. Label namespace (`<ns>.<product>.*`).
6. Build cadence.

Then implement, in order:

1. Version allocator script (§4) — test against a real and a nonexistent repo.
2. Dockerfile provenance `ARG`/`ENV` (§5), placed after dependency layers.
3. Reusable build workflow for the automated architecture (§6).
4. Thin per-service trigger wrappers.
5. Manual build script for the remaining architecture.
6. Consumer-side updater config (§7).
7. Documentation of the tag contract for consumers.

### Deliberate gap

Nothing in this design creates the multi-architecture manifest for the unsuffixed
tags. That requires a **promotion step** — selecting one release per architecture,
verifying they are acceptably equivalent, and combining them (e.g.
`docker buildx imagetools create`) under a newly allocated unsuffixed version.
Add it only if consumers genuinely need a single architecture-agnostic tag;
single-architecture consumers are fully served without it.
