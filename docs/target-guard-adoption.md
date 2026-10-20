# Tenant and current subscription guards

This source-only pilot addresses issue #34 on top of the final green runtime
PR #35, commit `16471ae721b59df71bffd6f919f1b70e7bb9ebc3`. It must remain
stacked on PR #35 until that dependency is merged. Viewer/drift PRs #29–31
are separate work and are not changed here.

## Immutable canonical source

The eight vendored Maester hooks files are exact bytes from Reference PR #111,
commit `fd26f7351f36c569067ae37edcb35d6b6cc40f29`, component
`maester-azd-hooks` **1.0.0**, status **pilot**. `azd-components.lock.json`
records each source path, destination and SHA-256. No runtime reference checkout
is needed. The component's public helper can derive a tenant for read-only callers;
these deployment entrypoints instead require configured expected tenant context.

Direct `Build-MaesterImage.ps1`, `Invoke-JobValidation.ps1`,
`Setup-PostDeploy.ps1` and `Run-AzdPreProvision.ps1` calls must supply `-TenantId`
or `AZURE_TENANT_ID`. Preup uses the selected azd/environment tenant. The setup
caller forwards its validated tenant to both the image builder and the real
Exchange helper. Outlook tokens select that tenant explicitly and the helper
checks the returned token tenant; it does not fall back to an ambient login.

The canonical guard reads fresh ARM subscription metadata via explicitly scoped
`az rest`, verifies subscription identity, expected tenant and exact `Enabled`
state. Cached `az account list/show` data is not current state evidence, and no
hook changes the global CLI default. ACR build is guarded after discovery and
job update is checked again after the potentially long build. Job start is
checked again after token acquisition. These checks reduce stale-state exposure;
they cannot make separate remote metadata reads and mutations atomic.

Exact existing resource, tag, environment and identity resolution is preserved.
The ACR and non-ACR runtime paths, package locks, images, bootstrap and runner
result/failure semantics remain unchanged. Permission evidence hashes are refreshed
for current source bytes only; that manifest and synthetic fixtures do not grant
permission or authorize any live operation.

## Offline evidence and separate live gates

The registered Pester suite uses PowerShell 7.6.6 and Pester 6.2.0, with official
PowerShell/.NET telemetry opt-outs before execution. Tests invoke the actual
preup, build, validation and setup scripts using fail-closed command doubles:

- Wrong tenant/subscription, disabled state despite stale cached Enabled, missing
  tenant/state, failed or malformed metadata cannot reach resource/job/build or
  permission writes.
- Valid selected targets work independently of an unrelated global default.
- State changes between discovery/build/update or token acquisition/start stop
  the next mutation. Genuine job failure remains an execution failure.
- The real setup Exchange branch and real helper capture the splatted Outlook
  token arguments. A mismatched returned token tenant reaches no Exchange role
  writes. Earlier Graph grants in that fixture are already-present synthetic roles.
- Canonical file hashes and permission evidence are checked by registered tests.

The existing Python bootstrap fault suite, PowerShell parser, component drift,
backlog/schema checks and ordinary hosted CI remain applicable. Hosted ACR and
non-ACR runtime jobs test source and pinned packages, not Azure resources.

No Azure login, token acquisition, grants, live resource writes, release or merge
was performed to implement this change. Native sub-mvp runtime, managed identity,
publication/access/retention/rollback and owned resource cleanup remain separate
owner-run validation gates. Offline/CI success does not close them.

## Direct runtime publication (issue #38)

`Publish-MaesterRuntimeFiles` also requires explicit `SubscriptionId`, `TenantId`
and `ResourceGroupName`. Before staging or downloading it uses the same pinned
canonical subscription guard and resolves the storage account with an explicitly
subscription-scoped ARM lookup. The returned account ID, name, type and resource
group must match the requested target. Setup passes its validated selectors to
this actual publisher.

Before each bounded publication attempt, the publisher rechecks canonical tenant/Enabled subscription context and obtains a token bound to the approved operator, tenant, audience and expiry. The canonical Blob endpoint uses direct Entra Bearer authorization, redirects disabled, and create-only publication; no storage CLI credential resolution is used. Existing conflicts require independent size/hash readback before acceptance. Job activation changes all external bundle pins in one template update after a fresh target/template read and verifies the resulting pins. The Jobs API has no documented ETag/CAS contract, so deployments must remain single-owner and serialized.

Archive SHA-256 verification and owned staging cleanup remain. Native managed-identity runtime, report access and cleanup gates remain owner-run work. See [keyless migration constraints](keyless-runtime-migration.md) for retained legacy resources, broad grants and source-bound ownership receipts.
