# azd-maester-containerappjob

Deploys a production-style Maester automation solution on Azure with:

- Azure Container App Job (PowerShell 7.6.6 / .NET 10 Linux x64, with optional ACR)
- Managed identity + Graph permissions
- Keyless private runtime bundle with managed identity (optional ACR packages the runner)
- Storage-backed report history (`archive`) and latest pointer (`latest/latest.html`)
- Optional Azure Container Registry with pre-built image for faster startup
- Optional App Service + Easy Auth portal in WebApp mode

## Quickstart (recommended)

After `azd init -t nathanmcnulty/azd-maester-containerappjob`, run from the template root:

`azd up`

## Versioning and shared components

This template uses the stable Maester module `2.3.0`. Shared azd hooks,
permission setup, and the optional report web app are vendored from
`nathanmcnulty/azd-reference` and recorded in `azd-components.lock.json`.

The original multi-variant catalog remains available at
[`nathanmcnulty/azd-maester`](https://github.com/nathanmcnulty/azd-maester) while
the migration is being completed.

During interactive `azd up`, the preprovision wizard prompts for:

- Include Web App / Exchange / Teams / Azure / ACR
- Security group object ID (required when Web App is enabled)
- Azure RBAC scopes (when Azure is enabled)
- Optional mail recipient

For fresh environments, `preprovision` creates the selected absent dedicated resource group and records its exact creation outcome. Existing groups are never silently adopted for cleanup.

## Advanced options (optional)

You can optionally enable additional data collection/connectivity for Maester by enabling one or more include options in the `azd up` wizard.

- `IncludeACR`
  - Deploys an Azure Container Registry (Basic SKU).
  - Builds a custom container image with all PowerShell modules pre-installed for significantly faster job startup.
  - Grants the Container App Job managed identity the `AcrPull` role.
- `IncludeExchange`
  - Ensures the `ExchangeOnlineManagement` module is available at runtime.
  - Grants the Container App Job managed identity the Exchange app permission required for app-only Exchange Online access.
  - Creates/links an Exchange service principal for the managed identity and assigns the Exchange RBAC role `View-Only Configuration` after reviewing the exact existing-state delta.
- `IncludeTeams`
  - Ensures the `MicrosoftTeams` module is available at runtime.
  - Assigns the Entra directory role `Teams Reader` to the Container App Job managed identity.
- `IncludeAzure`
  - Grants Azure RBAC `Reader` to the Container App Job managed identity at one or more scopes.
  - Scopes can be management groups and/or subscriptions.

### Permission behavior

- Azure RBAC, Entra directory roles, Exchange assignments, and Microsoft Graph app-role assignments are separate authorities.
- Some environments already have the required Microsoft Graph permissions consented and assigned. If Graph consent has not been completed previously, the deployment may require a **Global Administrator or Privileged Role Administrator**. See the selected profile and permission sections for solution-specific details.
- Setup uses an administrator-bootstrapped tenant-owned public client and an explicitly selected operator account. It reuses a matching bound Graph session by default.
- Permission changes require review of a versioned plan: interactive approval defaults to No, and noninteractive application requires the exact approved plan hash. Failed or incomplete inventories stop setup before access changes.
- Full is the new wizard default; No selects Minimal. Existing Extended settings retain their legacy role set. Mail and report-setting writes remain separate opt-in capabilities.
- See [setup and consent migration](docs/setup-consent-migration.md) and [Maester 2.3.0 upgrade notes](docs/maester-230-upgrade.md).
- Toggling an option from `Yes` to `No` in a later `azd up` run is additive only and does **not** revoke prior assignments.
- `azd down` checks ownership first and removes only exactly receipted external objects after Azure absence and a fresh cleanup approval.

What this does:

- runs preprovision checks/auth + interactive wizard
- provisions infra and runs postprovision setup + validation hooks

## Modes

- **Quick**: Container App Job + Storage
- **WebApp**: Quick + Web App (Entra auth restricted by security group)

For a manual postprovision retry after a successful provision, run
`./scripts/Setup-PostDeploy.ps1 -EnvironmentName <selected-environment> -SubscriptionId <selected-subscription> -TenantId <selected-tenant> -ResourceGroupName <deployed-resource-group>` to generate a read-only plan. Review it, then rerun with `-Apply -ApprovedPlanHash <reviewed-hash>` or use `-InteractiveConsent`.
Setup reads that environment's exact `containerAppJobName`, `containerAppJobPrincipalId`, `STORAGE_ACCOUNT_NAME` and optional
`WEB_APP_NAME` and `WEB_APP_ENABLED` deployment outputs; a false enablement output skips Easy Auth even
when other Web Apps exist in the resource group. Missing or mismatched targets
stop setup before role assignments or Easy Auth changes. The postprovision
summary uses these exact outputs rather than another resource in the group.

Defaults:

- `PERMISSION_PROFILE=Full` (legacy `Extended` remains distinct)
- `WEB_APP_SKU=F1`
- resource group pattern: `rg-<environment>-<location>` (override with `AZURE_RESOURCE_GROUP`)

## Operations

- Remove environment + Azure resources (with separate owned-lock and postdown cleanup approvals):
  `azd down -e <env>`
- Only after complete cleanup and preserving recovery evidence, optionally remove local azd env:
  `azd env remove <env> --force`

### Cleanup details

`azd down` validates the fresh dedicated resource group's ownership and exact declared inventory. Foreign resources or locks block teardown. Exact owned locks require a separate default-No confirmation; canceling azd afterward leaves those approved locks removed but resources and authorization unchanged.

After Azure deletion, `scripts/Run-AzdPostDown.ps1` proves the bound group/runtime absent, previews the remaining exact external objects, and requires a new default-No confirmation or current plan hash before deletion. Unknown outcomes, foreign dependencies and unsupported restoration of shared changes block cleanup and retain the journal for retry. A generic `--force` does not approve either hook's plan.

Preserve both `.azure/<env>/maester-*-ownership.json` receipts until cleanup is verified. The separately administrator-created setup client and access group remain external prerequisites. Deleting owned accounts removes their stored contents; owned ADO definition deletion also removes associated builds/history/artifacts. See [ownership and recovery limits](docs/owned-setup-cleanup.md) before teardown. Live before/after acceptance is still required.

## Architecture

- No-ACR: pinned official bootstrap image → system managed identity → private `runtime/bundles/<sha256>.zip` → hash/size verification → isolated exact PowerShell engine and locked modules.
- Optional ACR: digest-pinned custom image already contains the runner and locked runtime.
- The job uses its system identity for Graph and optional EXO/Teams, private `archive`/`latest` report blobs, and the optional Web App portal. Neither mode mounts Azure Files.

See [keyless delivery and migration gates](docs/keyless-runtime-migration.md). Existing deployments need an explicitly approved live and canonical-receipt migration; omission from incremental Bicep is not deletion.

## Script map

- azd hooks: `scripts/Run-AzdPreUp.ps1`, `scripts/Run-AzdPreProvision.ps1`, `scripts/Run-AzdPostProvision.ps1`, `scripts/Run-AzdPreDown.ps1`, `scripts/Run-AzdPostDown.ps1`
- Internal setup/validation: `scripts/Setup-PostDeploy.ps1`, `scripts/Invoke-JobValidation.ps1`
- Container runner script (verified runtime bundle or packaged ACR image): `scripts/Invoke-MaesterContainerJob.ps1`
- ACR image build: `scripts/Build-MaesterImage.ps1`, `Dockerfile`

## Runtime behavior

Configuration drift is disabled by default in this host. The runner excludes the
locked Maester drift suite and clears `MAESTER_FOLDER_DRIFT` for ordinary runs,
restoring its prior process value afterward even on failure. A manual operator
can opt in with `-EnableApprovedDrift` and the complete explicit input/tenant/run
binding arguments; the path uses private staging, exact drift/JUnit accounting,
and staged-input cleanup before the existing private blob publication routes.
Owned local reports are removed when the enabled run ends. An
inherited environment variable cannot select unapproved baseline/current files.
The first opt-in refuses configured mail and Web App destinations because their
report audience and delivery boundaries remain unqualified. Native scheduled
enablement, source transport, access, retention, rollback and second-host gates
remain open under MCAJ-010. See [the qualification evidence](docs/drift-isolation.md).

- Trigger mode defaults to `Schedule` (backward-compatible). To provision a job without scheduled assessments, run `azd env set JOB_TRIGGER_TYPE Manual` in the selected environment **before** `azd provision` or `azd up`. `infra/main.parameters.json` passes this setting to Bicep `jobTriggerType`; an unset value defaults to `Schedule`. Only exact `Manual` and `Schedule` values are allowed. Manual mode emits `manualTriggerConfig` and omits `scheduleTriggerConfig` entirely. The trigger setting itself does not start the job or change identity/permissions. **The existing azd postprovision hook still performs setup and explicitly starts a validation execution**, including in Manual mode; Manual is not an assessment-free deployment switch. Infrastructure-only validation must use the separately approved direct ARM/Bicep path with `jobTriggerType=Manual`, rather than running these hooks. Manual starts still require their own authorization. Existing executions are not canceled by changing the trigger. Before native validation, verify the deployed job's trigger is `Manual` and no schedule configuration remains. To restore the weekly trigger deliberately, use `azd env set JOB_TRIGGER_TYPE Schedule` and provision again. See the [Microsoft.App/jobs API contract](https://learn.microsoft.com/azure/templates/microsoft.app/2024-03-01/jobs).
- Weekly schedule (Sunday midnight UTC) when `JOB_TRIGGER_TYPE=Schedule`. To run at a different time or frequency, edit the `cronExpression` in `infra/main.bicep` (e.g. `'30 6 * * 1'` for Monday 6:30 UTC), then re-run `azd provision`.
- Without `IncludeACR`: the digest-pinned official Azure PowerShell Ubuntu 24.04 image is only a bootstrap interpreter. System managed identity downloads a private content-addressed ZIP with externally pinned SHA-256 and size. After verification and safe extraction, that interpreter exits and the runner starts the separately verified exact PowerShell 7.6.6 / .NET 10 engine with isolated locked modules and writable HOME/XDG directories. No customer registry or Files mount is required. Blob storage/download and extraction costs still apply.
- With `IncludeACR`: the Dockerfile installs the same exact PowerShell archive and locked modules, and packages executable runner content under `/opt/maester`. The provisioning placeholder fails closed until postprovision builds and applies the custom image digest. No runtime Blob upload is needed.
- Missing inputs, authorization, hash, extraction, runtime or module failures stop execution. Owned temporary directories are removed on completion/cancellation; neither mode falls back to keys or SAS. Initial empty bundle pins fail closed until publication completes.
- Hosted Linux x64 CI is configured to build the ACR image and qualify both runtime modes, including exact imports and negative tests. The explicit `-ValidateRuntimeOnly` diagnostic stops after imports, before identity authentication; it does not assess or publish. Local host tests do not prove those container checks have passed.
- Native container qualification and approved Azure validation remain required for managed identity, report access, rollback and cleanup. Issue [#26](https://github.com/nathanmcnulty/azd-maester-containerappjob/issues/26) and MCAJ-002 remain open for those gates.
- Runtime provenance: [official PowerShell 7.6.6 release and checksums](https://github.com/PowerShell/PowerShell/releases/tag/v7.6.6). The exact engine archive hash remains shared with the ACR Dockerfile. The bootstrap image is a different pinned base, not a qualified substitute for that assessment engine. Development-only SDK images are not the default.
- Job roles are container-scoped: Reader on `runtime`, Contributor separately on `archive` and `latest`. Explicit setup consent covers the verified publishing operator's Contributor grant on `runtime`; no account key is retrieved.
- Outputs:
  - `archive/maester-report-<timestamp>.html.gz`
  - `latest/latest.html`
- In WebApp mode, latest report is published to Web App `index.html`
- Entra auth via app registration is configured after the setup access plan is explicitly approved. Existing Microsoft Graph consent and app-role assignments are reused; if they are not already present, the first run may require a **Global Administrator or Privileged Role Administrator**.
- Signed-in deployment user is granted `Storage Blob Data Reader` on the solution storage account
- Blob soft delete is enabled for 1 day, with blob versioning disabled
- Archive uploads are gzip compressed and written directly to Cool tier
- Lifecycle policy moves `archive` blobs to Cold tier after 180 days and deletes after 365 days
- Key resources are tagged and protected with `CanNotDelete` locks by default
- Container App Job identity uses `Website Contributor` (least privilege for web content publish) on the optional Web App
- Container resources: 1 vCPU, 2 GiB memory, 1-hour timeout, 1 retry

## Security recommendations

This solution is reasonably secure, but there are additional controls you may choose to implement based on your organization requirements:

- **Storage private networking:** Use Private Endpoint + storage firewall rules to restrict data plane access to approved networks only.
- **Container App Environment networking:** Deploy the environment into a custom VNet for network isolation.
- **Web App private networking:** Use App Service Private Endpoint and access restrictions if your organization requires private-only ingress.
- **Centralized logging:** Send resource logs/metrics to a central Log Analytics workspace (or SIEM) for audit and incident response.
- **Conditional Access:** Apply tenant-wide baseline Conditional Access policies for user sign-in controls (MFA, device/risk posture).

## Reference docs

- Azure Developer CLI overview: https://learn.microsoft.com/azure/developer/azure-developer-cli/
- azd templates: https://learn.microsoft.com/azure/developer/azure-developer-cli/azd-templates
- azd hooks/extensibility: https://learn.microsoft.com/azure/developer/azure-developer-cli/azd-extensibility
- Manage azd environment variables: https://learn.microsoft.com/azure/developer/azure-developer-cli/manage-environment-variables
- Azure Container Apps Jobs: https://learn.microsoft.com/azure/container-apps/jobs
- Azure Container Apps storage: https://learn.microsoft.com/azure/container-apps/storage-mounts
- App Service custom domain: https://learn.microsoft.com/azure/app-service/app-service-web-tutorial-custom-domain

### Explicit deployment target guards

Direct setup, image-build and job-validation calls require `-TenantId` or
`AZURE_TENANT_ID` alongside the selected subscription. Fresh ARM metadata must
confirm the intended tenant and an Enabled subscription before mutations. See
[the canonical guard adoption and validation boundaries](docs/target-guard-adoption.md).

### Assessment validation evidence

The job validator now requires a fresh execution-bound structured receipt, not
only Azure `Succeeded` or an HTML file. Policy failures remain valid findings;
Maester errors, Pester discovery/setup errors and missing core execution fail
validation. The caller needs already-authorized private Blob data access, and
native qualification must use `-RequireNoMail` with mail disabled. Normal
mail-enabled postprovision remains supported; inline mail delivery is explicitly
unverified and outside the helper's validation scope. See the [receipt contract and native
validation boundaries](docs/assessment-evidence.md).

### Isolated runtime-only Azure smoke

See the [opt-in runtime-only smoke guide](docs/runtime-only-smoke.md) for fixture-only
launchers, least-privilege checks and offline regression tests. This is not an
assessment run or automatic deployment.
