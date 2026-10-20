# Isolated Azure runtime-only smoke

These opt-in utilities qualify the no-ACR managed-identity download and runtime
Reader isolation on a **new disposable fixture**, not an existing deployment.
They do not deploy, grant permissions, publish artifacts, or start jobs themselves.
Obtain approval for exact targets, identities, grants, two manual executions, and
any cleanup before taking those actions. Do not run `azd up`, postdeploy setup,
consent hooks, Graph setup, assessments, or mail for this smoke.

## Inputs and safety gates

- Check out a reviewed immutable commit with Git line-ending conversion disabled.
  Build the bundle using `New-MaesterRuntimeStaging` and
  `New-MaesterRuntimeBundle` in `scripts/Maester-RuntimeFiles.psm1`.
  Verify the locked engine and packages, then record and approve the generated
  SHA-256, byte size and `bundles/<sha256>.zip` name. If reproducing an approved
  artifact, a different hash or size requires review, not silent replacement.
- Use the digest-pinned bootstrap image from `infra/main.bicep`. Set
  `POWERSHELL_TELEMETRY_OPTOUT=1` and `DOTNET_CLI_TELEMETRY_OPTOUT=1` before tools
  or engines start. Never print identity headers, tokens or full environments.
- Create a fresh uniquely marked resource group. Capture the actual HTTP 201
  creation response, exact tenant/subscription/resource IDs, marker and timestamp
  contemporaneously, then verify identity/marker by readback before deployment.
  HTTP 200 or an earlier absence check is not creation evidence. Stop on uncertain
  creation; never retrospectively manufacture an application ownership receipt.
- Use a minimal fixture template: Manual trigger, system-assigned Job identity,
  private `runtime` container, Shared Key disabled, no Files/mounts, no ACR,
  schedules, web app, assessments or mail. Empty archive/latest containers are
  optional and require no job write roles. Keep initially empty runtime pins.
- Separately approve Job **Storage Blob Data Reader** only at the runtime
  container and publisher **Storage Blob Data Contributor** at that container
  only if existing authorized access is insufficient. Verify the actual principals
  and inherited assignments. Broader Job write access invalidates the smoke.
  No Graph, report-write, account-key, SAS or account-wide fallback permissions.
- Publish with the production OAuth publisher, including create-only upload and
  verified readback, then bind the coherent account/name/hash/size pins. Use a
  single owner for fixture template changes, fresh exact-target/template checks
  and readback. Do not claim an undocumented ETag compare-and-swap guarantee.

## Run 1: runtime only

Embed `scripts/validation/Start-RuntimeOnlySmoke.sh` as the isolated fixture's
`/bin/sh -c` command, retaining production `MAESTER_RUNTIME_BOOTSTRAP` and runtime
pins. This is an explicit fixture-only customization: its inner shell invocation
adds literal `-ValidateRuntimeOnly`. The production outer launcher does not forward
arguments; appending a flag to its command is **not** a safe substitute. This run
qualifies the production bootstrap and inner runtime, not the untouched outer
production command. The launcher retains private HOME/XDG paths, signal forwarding
and owned temporary cleanup.

Read back the full command, pins and Manual configuration before one execution.
Require terminal success **and** runtime-only JSON confirming the exact engine,
.NET major, architecture and module versions in `runtime-packages.lock.json`.
Status alone is insufficient. There must be no assessment/report output.

## Run 2: Reader write denial

Execute `scripts/validation/Test-RuntimeReaderWriteDenial.ps1` under the same Job
identity with the reviewed production bootstrap helper base64-encoded in
`MAESTER_RUNTIME_BOOTSTRAP` and the same pins. Use an approved fixture-only command
wrapper with private temporary HOME/XDG paths, telemetry opt-outs, signal forwarding
and cleanup before starting `pwsh`. This is a separate permission probe, not an
assessment engine. Never embed a token in the template.

The probe first requires HEAD 200 and the exact pinned Content-Length. It then
attempts one create-only PUT of the fixed nonsensitive text
`runtime-reader-write-denial-probe` at a new `runtime/smoke-write-denial/<guid>.txt`.
This is an attempted write and must be included in approval. It emits the exact
blob name before transport. Only 403 `AuthorizationPermissionMismatch`, together
with the positive read control and terminal success, proves the intended denial.
Generic 403, network errors, bad tokens and failed reads are not passes.
Unexpected success or uncertain transport requires stopping and inspecting that
exact blob; never blindly retry or broaden access. Delete a possible marker only
under approved fixture cleanup.

## Evidence and cleanup

Stop after these two bounded manual runs or any unexpected identity, mutation or
permission result. Record source commit, utility hashes, bundle pins, resource and
principal IDs, grant scopes, creation evidence, execution IDs, sanitized result
JSON, terminal states and final Manual/private/no-mount/Shared-Key-disabled
readback. Confirm no report blobs exist. Distinguish this evidence from offline
CI and from report-writing or legacy-migration qualification, neither of which
this smoke establishes.

Cleanup requires separate authorization and fresh identity/marker comparison
against contemporaneous ownership evidence. Preserve all pre-existing grants,
shares, mounts, receipts and data. Verify deletion outcomes rather than assuming
submission succeeded. If evidence is incomplete, stop and list remaining targets.

## Offline regression tests

`Invoke-Pester -Path ./tests/RuntimeReaderProbe.Tests.ps1` runs only an in-memory
HTTP handler. It tests success, denied/error paths, target guards, token secrecy
and cleanup without connecting to Azure. The standard repository test workflow
includes these tests; no Azure smoke is automatically executed by CI.
