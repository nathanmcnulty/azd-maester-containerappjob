# Viewer container image source

`viewer/Dockerfile` has two Linux/amd64 targets. `worker` runs only the absolute
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
The Debian packages are resolved from the live signed Debian repositories and
are not snapshot- or version-pinned, so the complete build is not reproducible
from these source pins alone. The runtime images perform no downloads and
contain no Azure SDK or credential chain.

Both targets run as UID/GID 65532, declare `SIGTERM`, and support a read-only
root filesystem with a private `/tmp` tmpfs. PowerShell compilation and .NET
temporary state use that tmpfs. The worker requires its storage, projection,
tenant, environment, and explicit user-assigned identity client ID as container
arguments; the image supplies no target defaults. Container orchestration owns
the termination grace period and hard kill deadline. The worker handles
`SIGTERM`; Caddy handles its own process signal.

CI builds both exact targets, verifies their configured users, entrypoints,
versions and Caddy configuration, then runs them in a controlled test-only
network namespace with no external network and no host port. A separate Caddy
process in that namespace acts only as local identity metadata. The production
worker and production Caddy defaults must return health 200 and report 503 when
Blob is unavailable, then both must exit zero after a bounded container stop.
Every container receives a separate tmpfs and no report volume.

The [hosted viewer-image job](https://github.com/nathanmcnulty/azd-maester-containerappjob/actions/runs/38831862245) passed against commit `245831b8431b5175f0f9d9e7d961332901e9b4c0`. Its retained proof binds both tested local image IDs. The preserved first run exposed an expected negative cleanup probe leaking a nonzero caller exit status; the reviewed repair preserves real failures and clears only successful completion.

This proves image construction, nonroot/read-only execution, fixed process
defaults, local sidecar routing, and signal lifecycle. It does not prove a
registry artifact digest, closed dependency set, SBOM/signature/provenance,
Azure managed-identity or Blob authority, report-content safety, ingress
authorization, deployment, or human-visible delivery. Dependency closure,
SBOM, and provenance remain release gates before image publication.

Sources: [Docker Official Debian image](https://hub.docker.com/_/debian/),
[PowerShell Debian installation](https://learn.microsoft.com/powershell/scripting/install/install-debian),
and [PowerShell binary archive installation](https://learn.microsoft.com/powershell/scripting/install/alternate-install-methods).
