# azd-maester-containerappjob

Deploys a production-style Maester automation solution on Azure with:

- Azure Container App Job (PowerShell 7.6.6 / .NET 10 Linux x64, with optional ACR)
- Managed identity + Graph permissions
- Runner script mounted via Azure Files volume
- Storage-backed report history (`archive`) and latest pointer (`latest/latest.html`)
- Optional Azure Container Registry with pre-built image for faster startup
- Optional App Service + Easy Auth portal in WebApp mode

## Quickstart (recommended)

After `azd init -t nathanmcnulty/azd-maester-containerappjob`, run from the template root:

`azd up`

## Versioning and shared components

This template uses the stable Maester module `2.2.0`. Shared azd hooks,
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

For non-interactive runs (`azd up --no-prompt`), if `AZURE_RESOURCE_GROUP` is set, `preup` creates it automatically when missing.

## Advanced options (optional)

You can optionally enable additional data collection/connectivity for Maester by enabling one or more include options in the `azd up` wizard.

- `IncludeACR`
  - Deploys an Azure Container Registry (Basic SKU).
  - Builds a custom container image with all PowerShell modules pre-installed for significantly faster job startup.
  - Grants the Container App Job managed identity the `AcrPull` role.
- `IncludeExchange`
  - Ensures the `ExchangeOnlineManagement` module is available at runtime.
  - Grants the Container App Job managed identity the Exchange app permission required for app-only Exchange Online access.
  - Creates/links an Exchange service principal for the managed identity and assigns the Exchange RBAC role `View-Only Configuration` (best-effort).
- `IncludeTeams`
  - Ensures the `MicrosoftTeams` module is available at runtime.
  - Assigns the Entra directory role `Teams Reader` to the Container App Job managed identity.
- `IncludeAzure`
  - Grants Azure RBAC `Reader` to the Container App Job managed identity at one or more scopes.
  - Scopes can be management groups and/or subscriptions.

### Permission behavior

- Azure RBAC, Entra directory roles, Exchange assignments, and Microsoft Graph app-role assignments are separate authorities.
- Some environments already have the required Microsoft Graph permissions consented and assigned. If Graph consent has not been completed previously, the deployment may require a **Global Administrator or Privileged Role Administrator**. See the selected profile and permission sections for solution-specific details.
- If a step fails due to missing privileges, the scripts will:
  - Prompt you to **Stop** or **Skip** in interactive runs.
  - Default to **Skip + continue** in non-interactive runs (CI).
- Toggling an option from `Yes` to `No` in a later `azd up` run is additive only and does **not** revoke prior assignments.
- Revocation/best-effort cleanup runs on `azd down` (predown hook).

What this does:

- runs preprovision checks/auth + interactive wizard
- provisions infra and runs postprovision setup + validation hooks

## Modes

- **Quick**: Container App Job + Storage
- **WebApp**: Quick + Web App (Entra auth restricted by security group)

For a manual postprovision retry after a successful provision, run
`./scripts/Setup-PostDeploy.ps1 -EnvironmentName <selected-environment> -SubscriptionId <selected-subscription> -ResourceGroupName <deployed-resource-group>`.
Setup reads that environment's exact `containerAppJobName`, `containerAppJobPrincipalId`, `STORAGE_ACCOUNT_NAME` and optional
`WEB_APP_NAME` and `WEB_APP_ENABLED` deployment outputs; a false enablement output skips Easy Auth even
when other Web Apps exist in the resource group. Missing or mismatched targets
stop setup before role assignments or Easy Auth changes. The postprovision
summary uses these exact outputs rather than another resource in the group.

Defaults:

- `PERMISSION_PROFILE=Extended`
- `WEB_APP_SKU=F1`
- resource group pattern: `rg-<environment>-<location>` (override with `AZURE_RESOURCE_GROUP`)

## Operations

- Remove environment + Azure resources (includes predown cleanup):
  `azd down -e <env> --force --purge`
- Optionally remove local azd env:
  `azd env remove <env> --force`

### Cleanup details

`azd down` runs `scripts/Run-AzdPreDown.ps1`, which performs best-effort cleanup for tenant/scope-level assignments created by advanced options, including:

- Teams directory role assignments (`Teams Reader`) created by this environment
- Azure RBAC role assignments created by this environment (at selected scopes)
- Exchange Online permissions/assignments created by this environment (best-effort)

The generated setup summary in `outputs/<env>-setup-summary.md` includes tracked assignment IDs used for cleanup.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│ Container App Environment                                        │
│   ┌────────────────────────────┐   ┌─────────────────────────┐   │
│   │ Container App Job          │   │ Azure Files Mount       │   │
│   │ (weekly schedule)          │──▶│ /mnt/scripts            │   │
│   │ pwsh -File ...ps1          │   │ Invoke-MaesterContainer │   │
│   │ MI: System-Assigned        │   │ Job.ps1                 │   │
│   └──────┬─────────────────────┘   └─────────────────────────┘   │
│          │                                                       │
└──────────┼───────────────────────────────────────────────────────┘
           │
    ┌──────┼──────────────────────────────────────────────┐
    │      ▼                                              │
    │  ┌──────────┐  ┌──────────┐  ┌──────────┐           │
    │  │ Graph    │  │ Storage  │  │ Web App  │ optional  │
    │  │ + EXO    │  │ archive/ │  │ Easy Auth│           │
    │  │ + Teams  │  │ latest/  │  │ portal   │           │
    │  └──────────┘  └──────────┘  └──────────┘           │
    │                                                     │
    │  ┌──────────┐                                       │
    │  │ ACR      │ optional (pre-built image)            │
    │  └──────────┘                                       │
    └─────────────────────────────────────────────────────┘
```

## Script map

- azd hooks: `scripts/Run-AzdPreUp.ps1`, `scripts/Run-AzdPreProvision.ps1`, `scripts/Run-AzdPostProvision.ps1`, `scripts/Run-AzdPreDown.ps1`
- Internal setup/validation: `scripts/Setup-PostDeploy.ps1`, `scripts/Invoke-JobValidation.ps1`
- Container runner script (uploaded to Azure Files): `scripts/Invoke-MaesterContainerJob.ps1`
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
- Without `IncludeACR`: the digest-pinned Microsoft .NET 10 Ubuntu Noble dependency image starts `/bin/sh /mnt/scripts/Start-MaesterContainerJob.sh nonacr`. Setup downloads the official PowerShell 7.6.6 Linux x64 archive, checks its pinned SHA-256, and uploads it alongside the runner to the existing Azure Files share. Each job copies and verifies the archive again, extracts into an owned local temporary directory, checks the engine, and invokes the maintained runner. No new registry or Azure resource is needed. The tradeoff is archive storage in the existing share and copy/extraction time at startup; the share's ordinary storage/transaction charges still apply.
- With `IncludeACR`: the existing Dockerfile builds PowerShell 7.6.6 / .NET 10 from the same pinned dependency base and verified official archive, with locked modules pre-installed. The mounted bootstrap uses explicit `acr` mode and never installs a runtime or falls back. The public provisioning placeholder intentionally cannot execute an assessment: it fails before the runner until postprovision builds and applies the ACR image digest.
- Missing files, download/hash/extraction/runtime/module failures stop execution. Bootstrap cleanup removes only its owned local temporary directory and leaves mounted source files untouched. Setup similarly removes only its own staging directory. ACR setup does not download or upload the runtime archive.
- Hosted Linux x64 CI exercises the production non-ACR files and invocation: real runtime/module installation, exact five default imports, a subsequent offline run, corruption failures, ACR placeholder rejection, and source/temporary-file checks. It also builds the normal ACR image and checks its mounted invocation offline. The explicit `-ValidateRuntimeOnly` diagnostic stops after imports, before identity authentication; it does not run an assessment or publish a report.
- These source/runtime checks do not qualify native Container App identity, report access, rollback, or cleanup. Issue [#26](https://github.com/nathanmcnulty/azd-maester-containerappjob/issues/26) and MCAJ-002 remain open for those separately authorized Azure gates.
- Runtime provenance: [official PowerShell 7.6.6 release and checksums](https://github.com/PowerShell/PowerShell/releases/tag/v7.6.6). The archive hash and base digest stay aligned with the ACR Dockerfile; tests reject pin drift. Deprecated PowerShell public images and development-only SDK images are not used as the new production default.
- Runner script is always mounted from Azure Files (never baked into image) for easy updates
- Outputs:
  - `archive/maester-report-<timestamp>.html.gz`
  - `latest/latest.html`
- In WebApp mode, latest report is published to Web App `index.html`
- Entra auth via app registration is configured automatically. Existing Microsoft Graph consent and app-role assignments are reused; if they are not already present, the first run may require a **Global Administrator or Privileged Role Administrator**.
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
