# Keyless runtime delivery and migration gate

## New deployments

No customer ACR is required by default. The job uses the digest-pinned official Azure PowerShell Ubuntu 24.04 image only as a bootstrap interpreter. This image is not the qualified Maester PowerShell engine: the verified private bundle contains the exact PowerShell 7.6.6 archive, which retains its independent SHA-256 check. Bootstrap exits before the isolated engine starts. Writable HOME/XDG directories and isolated module paths prevent the base image's installed Az modules from entering the assessment process.

The publisher uses the verified operator's Entra OAuth token, not account keys, SAS, CLI storage credential fallback, or a public download. It creates `runtime/bundles/<sha256>.zip` with create-only semantics, verifies existing conflicts and readback, then pins the blob name, SHA-256 and size together in the job template. There is no moving `latest` runtime manifest. Initial empty pins fail closed. Re-provisioning clears pins and requires publication again. A schedule may attempt execution before publication, but cannot run unverified content.

Activation must have one operator at a time. The [Jobs 2024-03-01 PATCH API](https://learn.microsoft.com/rest/api/resource-manager/containerapps/jobs/update?view=rest-resource-manager-containerapps-2024-03-01) does not document an ETag/If-Match compare-and-swap contract. The publisher rechecks the exact job identity and unchanged template immediately before submitting all four pins in one PATCH, preserves unrelated template values, and verifies identity/pins afterward. This keeps the pin tuple coherent but cannot prevent a concurrent writer racing between the read and write. An uncertain activation is reported for inspection, never automatically repeated.

The optional ACR image packages its runner, helper modules and lock under `/opt/maester` alongside its installed exact engine/modules. It does not use Azure Files or runtime Blob storage to load executable code. Its immutable image digest remains the code pin.

New storage accounts disable Shared Key. The job receives Blob Data Reader on `runtime`, and separate Blob Data Contributor assignments on `archive` and `latest`. Runtime publication requires the explicitly reviewed operator Blob Data Contributor grant on `runtime` only, handled by setup consent, not an implicit Bicep publisher grant. No additional Graph rights are required.

## Existing environments: stop, inventory, approve

Removing declarations from an incremental Bicep deployment does **not** remove old resources or assignments. In particular, adding Reader on `runtime` does not limit an inherited account-wide Contributor. Old environment storage registrations also retain account keys independently of the new template.

Pre-provisioning therefore blocks legacy keyed/mounted configurations, Shared Key enabled accounts, and broad job Blob Contributor/Owner assignments before wizard or ownership writes. Failed or incomplete inventory is not permission to proceed. The check is read-only and preserves ownership receipts. A retained `scripts` share is data, not authorization to delete it. The guard conservatively inventories the entire selected resource group, so unrelated storage accounts or jobs in a shared group can block provisioning; prefer a dedicated fresh fixture. Its built-in-role checks are not a complete effective authorization audit of custom roles, group membership and inherited permissions. Do not claim live runtime write isolation until independently validated.

This change does not migrate a live environment automatically. Prepare a target-specific plan containing:

1. Verified tenant, subscription, resource group, job, environment and storage account IDs; identity principal IDs; exact current role assignment IDs and scopes; locks; and current schedule/executions.
2. An export of the job template, environment `scriptstorage` registration metadata (never its key), and the existing ownership/setup receipts. Preserve legacy ownership IDs and recorded resource/grant IDs; do not overwrite or reclassify old receipts to claim resources were removed.
3. The proposed scoped job roles and operator runtime role, and exact broad assignment removals. Check inherited grants above the account too. An unrelated broad grant requires its own owner review; do not remove it simply to satisfy this template.
4. The proposed removal of the job's SMB volume/mount and the environment storage registration, then disabling Shared Key. Review dependencies and running executions first. Removing a stored-key registration is different from deleting the underlying share.
5. A preservation plan for the old `scripts` share and any fixtures/report data. Do not delete the share, account, report blobs, receipts or unrelated locks as part of this migration. Keep retained resource ownership in the historical receipt/cleanup inventory.
6. Exact live approval for each grant/removal/configuration change, including temporary lock changes if needed. Code approval or a general preference for keyless access is not that approval.
7. A rollback plan that does not silently re-enable keys or restore broad rights. If keyless startup fails, stop and diagnose; do not fall back to Files/SAS/account keys.

Existing canonical ownership receipts also bind the infrastructure source hash. This source change cannot initialize or complete against an old receipt merely by removing the live blockers: a separately reviewed canonical receipt migration is still required. Never edit the receipt hash, manufacture ownership, or discard recorded legacy resource IDs to bypass that check. Migration for existing environments remains planning-only, not deploy-ready. Fresh environments are unaffected by that historical receipt constraint.

Only after approved changes, readback and a separately approved receipt migration may provisioning continue for an existing environment. Record the migration result separately and reconcile receipt ownership explicitly. No automatic deletion or repair is performed by this candidate.

## Required qualification before rollout

Local compilation and host-level tests do not qualify the official base container's native dependencies. Run the actual pinned image with the full locked module set, verify the exact PowerShell/.NET/platform contract and isolation, exercise malicious/partial bundles, and check cancellation/exit propagation. Then perform approved Azure validation of managed identity, Blob permissions, create-only publication/readback and the final template pins. Until those gates pass, this is a validation candidate, not a production-ready migration.

References: [Microsoft recommends Entra authorization for Blob data](https://learn.microsoft.com/azure/storage/blobs/authorize-access-azure-active-directory), [prevent Shared Key authorization](https://learn.microsoft.com/azure/storage/common/shared-key-authorization-prevent), [Azure PowerShell container guidance](https://learn.microsoft.com/powershell/azure/azureps-in-docker).
