# Viewer container image source

`viewer/Dockerfile` has two Linux/amd64 runtime targets. `worker` runs only the absolute
PowerShell 7.6.6 executable and `Start-MaesterViewer.ps1`; `caddy` runs only the
absolute Caddy 2.11.7 executable with the fixed production `viewer/Caddyfile`.
Each process is PID 1. The images do not contain a supervisor and share no report
volume. Container Apps provides their shared loopback network namespace.

Both targets use the Docker Official Image `debian:bookworm-20261005-slim`
linux/amd64 manifest digest
`sha256:a4672c0cb26fbdde88e38fa2dfb6c681942306680e41e4378b28770b6e79ee91`.
On 2026-10-15 the Docker registry resolved its index digest as
`sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587`
and identified the upstream source as `debuerreotype/docker-debian-artifacts`.
PowerShell and Caddy are downloaded only during the build from their official
GitHub releases and must match the committed SHA-256 values before extraction.
The build also downloads the locked Maester 2.2.0 package, verifies its package
SHA-256, extracts only `assets/ReportTemplate.html`, verifies the approved
template SHA-256, and copies that file to a fixed worker path. The entrypoint
accepts no template path override.
APT now uses only the frozen Debian import `20261015T205142Z` and security import
`20261015T222501Z`, selected on 2026-10-15. The shared `pinned-apt` build stage
checks that no other source entries exist, requires a completely successful APT
update with normal Debian archive-keyring signature verification, and verifies
the exact three `InRelease` SHA-256 values in `viewer/debian-inrelease.sha256`
before either descendant can install packages. Those signed metadata files bind
the package-index hashes and package content hashes; there is no live-repository
fallback. The Caddy runtime inherits only the digest-pinned base and installs no
additional Debian packages.

`Check-Valid-Until: no` is scoped to these frozen source entries because archived
security metadata expires; it does not disable signature or exact-hash checks.
Public APT traffic uses HTTP to bootstrap the base's missing CA bundle, with
Debian signatures and the committed metadata hashes providing integrity. TLS
verification is never disabled. Changing any snapshot or metadata pin requires
review and a fresh build. The runtime images perform no dependency downloads
and contain no Azure SDK or credential chain. These inputs do not establish a
byte-for-byte reproducible build or a hermetic build environment.

Both targets run as UID/GID 65532, declare `SIGTERM`, and support a read-only
root filesystem with a private `/tmp` tmpfs. PowerShell compilation and .NET
temporary state use that tmpfs. The worker requires its storage, projection,
tenant, environment, and explicit user-assigned identity client ID as container
arguments; the image supplies no target defaults. Container orchestration owns
the termination grace period and hard kill deadline. The worker handles
`SIGTERM`; Caddy handles its own process signal.

CI builds both exact runtime targets and the build-only `artifacts` target,
records sorted Debian package/version/architecture inventories bound to all
three tested local image IDs and inventory hashes, and verifies the runtime users, entrypoints,
versions and Caddy configuration, then runs them in a controlled test-only
network namespace with no external network and no host port. A separate Caddy
process in that namespace acts only as local identity metadata. The production
worker and production Caddy defaults must return health 200 and report 503 when
Blob is unavailable, then both must exit zero after a bounded container stop.
Every container receives a separate tmpfs and no report volume.
The smoke script also builds the `pinned-apt` stage in a minimal context with one
expected metadata hash deliberately changed. It must fail with the exact
checksum-mismatch diagnostic before package installation; a network or unrelated
build failure does not satisfy the negative check. Inventories and the negative
build log are retained with the image proof. A Debian package inventory is not a
complete SBOM for the copied PowerShell/Caddy archives or application source.

CI additionally retains Buildx `--metadata-file` output with maximum provenance
for all three builds and the Buildx version. The runtime records must bind their
config digest to the exact image IDs exercised by the smoke check. These are
unsigned local build records. Loading into Docker's local image store does not
retain registry-attached attestations; this is not signed release provenance.

SHA-pinned Syft 1.54.1 scans Docker archives exported by those exact runtime image
IDs. The scanner runs in a private network namespace, disables update/enrichment
and Go license-cache lookups, and scans the local archive without a registry resolver.
It emits Syft JSON and SPDX 2.3 with file SHA-256 metadata. Validation requires
every independently queried Debian package/version/architecture, the expected
PowerShell or Caddy runtime package, and exact copied viewer source/configuration
and approved Maester template hashes. Every cataloged package must also appear
in SPDX with the same purl and version. Raw config bytes must hash to the tested
image ID, and the SPDX root must describe the scanned archive manifest. An
archive manifest can differ from BuildKit's output manifest due to export
representation; both are recorded separately and bound through the same config
digest. The final receipt hashes the build metadata, independent inventory and
both SBOM files, and records the actual checked-out Git commit (which can be a
PR merge commit). Large transport archives are removed only after validation;
failed-scan artifacts remain for diagnosis.

This verifies selected package and file coverage, not universal dependency
completeness. In particular, hashing the locked Maester HTML template does not
recover the npm dependency composition of its embedded minified JavaScript.
That composition, vulnerability review, registry publication and signed release
attestations remain open before deployment acceptance.

The [hosted viewer-image job](https://github.com/nathanmcnulty/azd-maester-containerappjob/actions/runs/38831862245) passed against commit `245831b8431b5175f0f9d9e7d961332901e9b4c0`. Its retained proof binds both tested local image IDs. The preserved first run exposed an expected negative cleanup probe leaking a nonzero caller exit status; the reviewed repair preserves real failures and clears only successful completion.

This proves image construction, nonroot/read-only execution, fixed process
defaults, local sidecar routing, and signal lifecycle. It does not prove a
registry artifact digest, complete SBOM/signature/provenance,
Azure managed-identity or Blob authority, report-content safety, ingress
authorization, deployment, or human-visible delivery. Complete SBOM coverage,
release provenance, signing and registry publication remain release gates.

Sources: [Docker Official Debian image](https://hub.docker.com/_/debian/),
[Debian Snapshot usage](https://snapshot.debian.org/),
[PowerShell Debian installation](https://learn.microsoft.com/powershell/scripting/install/install-debian),
and [PowerShell binary archive installation](https://learn.microsoft.com/powershell/scripting/install/alternate-install-methods).
