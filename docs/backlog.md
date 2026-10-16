# Backlog: nathanmcnulty/azd-maester-containerappjob

> Generated from `docs/backlog.json`. Edit the JSON source and regenerate this file.
> Standard: [azd agent backlog standard](https://github.com/nathanmcnulty/azd-reference/blob/main/standards/agent-backlogs.md). This link is review guidance, not a runtime dependency.

- **Schema version:** 1.0.0
- **Repository:** nathanmcnulty/azd-maester-containerappjob
- **Source revision:** `1f34605d23e4f0536c9215d21f6368d98f5c30f4`
- **Captured:** 2026-10-16
- **Items:** 10

## MCAJ-001: Reconcile this backlog with current source and active work

- **Kind:** discovery
- **Priority:** P1
- **Status:** done
- **Wave:** 0
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Plans and implementation evidence are spread across files; the captured source can change while other tasks work.

**Scope:**

- docs/backlog.json
- docs/backlog.md
- Existing roadmap, execution status, open issues and pull requests &lpar;read-only&rpar;

**Acceptance:**

- Classify each candidate as implemented, still open, superseded or awaiting evidence; retain source links and reasons.
- Inspect dirty state, remotes, worktrees and local environment presence without reading secrets; avoid duplicate work with active owners.
- Resolve the actual offline validation commands and record exact current default-branch/working-tree provenance; do not copy historical live passes to newer code.

**Validation:**

- git status --short
- git remote -v
- git worktree list --porcelain
- Read the applicable instructions and validation workflow; read gh issue list and gh pr list for the named repository using nathanmcnulty. Do not create or modify issues/PRs.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- README.md

**Evidence:**

- Reconciled later reviewed metadata tip 2a6bbcbc81bd0600ea4665d99368ba532c4ac8dd against freshly fetched origin/main 6288ccefab8faba0b54b85be9fb3a2ec3230c45a. Current main adds reviewed source fixes from pull request&lpar;s&rpar; &num;16, &num;17, &num;19 and &num;21; no dirty canonical bytes or unrelated branch history were copied.
- Current repository issues and pull requests were read on 2026-10-04&colon; none are open. Items MCAJ-002, MCAJ-003 remain proposed because their component, host-specific live, or shared azd-maester issue gates are not satisfied by source merges alone; completed issue-backed fixes retain exact issue and pull-request evidence.
- Full current-source offline Pester validation passed 43/43 tests with zero failures. Canonical backlog schema and generated-Markdown checks also passed; no Azure, Graph, deployment, report publication or other live operation was performed.

**Review and authorization note:**

Review MCAJ-001 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MCAJ-006: Pin custom image base packages and deploy the resolved image digest

- **Kind:** discovery
- **Priority:** P1
- **Status:** done
- **Wave:** 0
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

The report captured on 2026-10-03 is closed after the reviewed fix merged; this record preserves the original trigger and validation boundary.

**Scope:**

- Linked issue and current source &lpar;read-only&rpar;
- Repository-local backlog evidence

**Acceptance:**

- Read the linked issue and current default branch; classify the exact defect, current owner and evidence gap.
- Record a current PR or verified resolution before selecting any implementation; preserve broader feature and live acceptance gates.

**Validation:**

- Read current issue and PR state using nathanmcnulty; do not modify or close issues during reconciliation.
- Inspect dirty state and worktrees; resolve the exact current revision and relevant offline commands before implementation.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-maester-containerappjob/issues/12

**Evidence:**

- GitHub issue &num;12 is closed by merged pull request &num;14; current origin/main 6288ccefab8faba0b54b85be9fb3a2ec3230c45a contains the reviewed fix. Source closure does not claim a new live deployment, report publication, or human-visible result.

**Review and authorization note:**

Review MCAJ-006 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MCAJ-004: Maester invocation errors can become successful container jobs with fabricated reports

- **Kind:** maintenance
- **Priority:** P1
- **Status:** done
- **Wave:** 1
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

The report captured on 2026-10-03 is closed after the reviewed fix merged; this record preserves the original trigger and validation boundary.

**Scope:**

- Paths and trigger cited in the linked issue
- Focused offline regression tests
- docs/
- docs/backlog.json
- docs/backlog.md
- BACKLOG.md

**Acceptance:**

- Classify the report as still reproducible, already fixed, superseded or requiring live evidence; record the exact current revision.
- For a reproducible defect, demonstrate the linked trigger with an offline regression and apply the smallest fix preserving tenant/target/ownership and failure semantics.
- For a feature, produce a bounded design with compatibility, optional permissions, acceptance and rollout gates before implementation; no live mutation or automatic issue closure.

**Validation:**

- Read the issue body and current source/PRs; capture the exact reproduction and existing registered offline validation command.
- Use deterministic fixtures for the described trigger and negative boundary; retain current-source results. Do not rerun production or tenant operations to reproduce it.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-maester-containerappjob/issues/10
- README.md

**Evidence:**

- Merged fix&colon; https&colon;//github.com/nathanmcnulty/azd-maester-containerappjob/pull/13 closed issue &num;10 at e38b3080346278bfd6ea0afdd16f3e89a62a0394; the fix is present on current main d5efff3998af6a2f889d6da71ee0fa46fa88d537.
- Current-head source propagates invocation errors, rejects missing genuine output and fails required latest publication&colon; https&colon;//github.com/nathanmcnulty/azd-maester-containerappjob/blob/d5efff3998af6a2f889d6da71ee0fa46fa88d537/scripts/Invoke-MaesterContainerJob.ps1&num;L362-L410
- Deterministic regression coverage includes thrown invocation, missing report, genuine findings and failed publication&colon; https&colon;//github.com/nathanmcnulty/azd-maester-containerappjob/blob/d5efff3998af6a2f889d6da71ee0fa46fa88d537/tests/RunnerFailure.Tests.ps1&num;L43-L88 and https&colon;//github.com/nathanmcnulty/azd-maester-containerappjob/blob/d5efff3998af6a2f889d6da71ee0fa46fa88d537/tests/WebAppFailure.Tests.ps1&num;L43-L56
- Exact current-main validation passed&colon; https&colon;//github.com/nathanmcnulty/azd-maester-containerappjob/actions/runs/37143199420/job/111261716692
- Live evidence gap preserved&colon; PR &num;13 leaves Container Apps Job platform status propagation as an integration follow-up; this reconciliation claims no live container or tenant run.
- GitHub issue &num;10 is closed by merged pull request &num;13; current origin/main 6288ccefab8faba0b54b85be9fb3a2ec3230c45a contains the reviewed fix. Source closure does not claim a new live deployment, report publication, or human-visible result.

**Review and authorization note:**

Review MCAJ-004 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MCAJ-005: Optional ACR build targets a job name that differs from the deployed resource

- **Kind:** maintenance
- **Priority:** P1
- **Status:** done
- **Wave:** 1
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

The report captured on 2026-10-03 is closed after the reviewed fix merged; this record preserves the original trigger and validation boundary.

**Scope:**

- Paths and trigger cited in the linked issue
- Focused offline regression tests
- docs/

**Acceptance:**

- Classify the report as still reproducible, already fixed, superseded or requiring live evidence; record the exact current revision.
- For a reproducible defect, demonstrate the linked trigger with an offline regression and apply the smallest fix preserving tenant/target/ownership and failure semantics.
- For a feature, produce a bounded design with compatibility, optional permissions, acceptance and rollout gates before implementation; no live mutation or automatic issue closure.

**Validation:**

- Read the issue body and current source/PRs; capture the exact reproduction and existing registered offline validation command.
- Use deterministic fixtures for the described trigger and negative boundary; retain current-source results. Do not rerun production or tenant operations to reproduce it.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-maester-containerappjob/issues/9
- README.md

**Evidence:**

- GitHub issue &num;9 is closed by merged pull request &num;11; current origin/main 6288ccefab8faba0b54b85be9fb3a2ec3230c45a contains the reviewed fix. Source closure does not claim a new live deployment, report publication, or human-visible result.

**Review and authorization note:**

Review MCAJ-005 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MCAJ-003: Reconcile shared hook/webapp versions and host permission deltas

- **Kind:** maintenance
- **Priority:** P2
- **Status:** done
- **Wave:** 1
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Existing adoption must be updated through hashes and host-specific validation rather than blindly reinstalling components.

**Scope:**

- azd-components.lock.json
- azd-permissions.json
- scripts/
- infra/
- docs/

**Acceptance:**

- Compare lock pins with canonical manifests and current-source drift before proposing an update.
- Run target-context negative cases and compare minimal versus optional-feature permissions.
- Keep Maester execution and reporting host-specific; record exact source hashes and candidate/pilot status.

**Validation:**

- Invoke-Pester ./tests/TargetContext.Tests.ps1 -CI
- Read and compare lock hashes with canonical reference source; do not overwrite drift.

**Dependencies:**

- _none_

**Components:**

- maester-azd-hooks
- maester-report-webapp

**Sources:**

- README.md
- azd-components.lock.json

**Evidence:**

- Adopted pilot maester-azd-hooks 0.1.6 from immutable azd-reference revision a09cac311aac7362f56d2a31833ed90ce5812649. All eight managed targets match the component manifest and lock; only Maester-UpWizard.psm1 changed from 0.1.5, to require a non-empty GUID before persisting the optional Web App group Object ID.
- Preserved maester-report-webapp 0.1.1 at immutable revision 79f0608c672639aae0f0ed96d160b1eb17cfc08f with exact vendored hash 4b12708c76489f3f20e031fdafc706a3062276ef4a83fda7f5109f4cbd902972.
- Added a schema-valid partial permission manifest with exactly 24 source-proven declarations&colon; eight Minimal runtime roles, eleven additional default Extended roles, four deployment-operator scopes, and optional Mail.Send. Working and raw-index comparisons returned 8/19/20/4 permissions with no evidence findings; comparisonComplete remains false and explicit gaps preserve unmodeled Azure RBAC, optional feature, operator and cleanup authority.
- The 0.1.6 permission helper is byte-identical to 0.1.5 at SHA-256 e43b6e4ce60c9adef30355cc126519e5f754c01630c94fca9d85c04aebde3548; this adoption adds no declared scope or grant and claims no effective tenant permission.
- Offline validation passed&colon; TargetContext 5/5, full host suite 43/43, PowerShell parse 26 files with zero errors, Bicep compilation to valid JSON SHA-256 9528dbc49a4ab436111553c59ee26c3c0ea2a214ed86f31a42a1db02a0d0dd58, canonical permission comparison tests 9/9, component/lock drift checks, backlog schema, generated Markdown and diff checks.
- No Azure, Graph, deployment, report publication or live host operation was performed. Host-specific live execution, report access and cleanup remain under item 002 and are unchanged.

**Review and authorization note:**

Review MCAJ-003 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MCAJ-002: Qualify Container Apps Job execution and optional report-webapp lifecycle

- **Kind:** verification
- **Priority:** P1
- **Status:** proposed
- **Wave:** 2
- **Authorization:** azure-deployment
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Shared pilots are already vendored; host-specific execution and report access still need independently bound evidence.

**Scope:**

- scripts/Invoke-JobValidation.ps1
- docs/
- infra/
- tests/TargetContext.Tests.ps1

**Acceptance:**

- Record exact Maester/runtime/component revisions and host execution output under the selected tenant.
- Validate optional webapp identity, report publishing, Easy Auth and feature-specific permission delta.
- Disabled web hosting works independently; cleanup preserves adopted objects and records exact owned resources.

**Validation:**

- Invoke-Pester ./tests/TargetContext.Tests.ps1 -CI
- After separate authorization use ./scripts/Invoke-JobValidation.ps1 against the exact owned host; retain report access and cleanup evidence.

**Dependencies:**

- _none_

**Components:**

- maester-azd-hooks
- maester-report-webapp

**Sources:**

- README.md
- scripts/Invoke-JobValidation.ps1

**Evidence:**

- _none_

**Review and authorization note:**

Review MCAJ-002 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MCAJ-009: Keep configuration drift disabled and isolated by default

- **Kind:** maintenance
- **Priority:** P1
- **Status:** done
- **Wave:** 3
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Omitting DriftRoot leaves upstream Maester able to discover unapproved input from an inherited process environment variable.

**Scope:**

- scripts/Invoke-MaesterContainerJob.ps1
- tests/DriftIsolation.Tests.ps1
- .github/workflows/validate.yml
- docs/drift-isolation.md

**Acceptance:**

- Exclude the locked upstream drift file before Pester discovery and clear its ambient environment during invocation, restoring prior process state on success and failure.
- Preserve ordinary assessment, genuine findings, publication and failure semantics; do not enable drift, fetch data or add permissions.
- Prove the original inherited-input defect and corrected isolation with exact production configuration/invocation tests plus actual locked suite/report qualification.

**Validation:**

- PowerShell 7.6+ and Pester 6.2&colon; Invoke-Pester ./tests -CI
- Parse all PowerShell; canonical backlog schema/render checks; fixtures are not native job or publisher proof.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- docs/drift-isolation.md
- https&colon;//github.com/nathanmcnulty/azd-maester/blob/a6e301310ccae0519288b794eb95aae3af43fa08/docs/drift-analysis-design.md

**Evidence:**

- Actual Maester 2.2.0/Pester 6.2 invocation discovered 44 tests again when DriftRoot was omitted in a reused process. Controlled regression tests failed against original source for inherited-root success/failure and pre-discovery exclusion, then passed with isolation. An actual upstream-suite copy plus ordinary synthetic test using the production blocks executed exactly one ordinary test, restored the inherited root and recorded no HTTP/authentication tripwire attempts. See docs/drift-isolation.md; no deployed-job, identity, Blob or recipient proof is claimed.
- Full repository validation passed 72/72 on PowerShell 7.6.6/Pester 6.2.0. Parser and differential analyzer checks found no new issue; permission/backlog schemas and rendered backlog parity passed. Azure resources, identities, permissions and assignments were not mutated.

**Review and authorization note:**

Review MCAJ-009 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MCAJ-007: Implement optional Caddy Container App report viewer

- **Kind:** feature
- **Priority:** P2
- **Status:** proposed
- **Wave:** 4
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

The shared viewer design is complete, but this standalone Container App Job runner has no Caddy provider implementation.

**Scope:**

- infra/
- scripts/
- docs/
- azd-permissions.json

**Acceptance:**

- Add exact -IncludeContainerWebApp mapping, default-off and exclusive with both other viewer flags, including legacy -IncludeWebApp; preserve existing hooks and deployment-validation behavior.
- Use only an immutable signed image/SBOM and reviewed versioned azd-reference component pin; publish a private bounded HTML projection plus manifest with ETag/conditional pointer, BlobDataContributor only where required, and viewer managed identity read-only.
- Bound Caddy paths, fixed loopback GET/HEAD routes with no shared report volume, size/poll/LKG/atomic switch, HTTPS and native tenant/audience group authorization; reject missing/overage groups, foreign tenant, forged headers and host bypass. Record owned rollback/deletion receipts and validate with offline fixtures before authorized lab writes.
- Use a dedicated viewer-projection container with immutable HTML/manifest versions and an ordered ETag-conditional latest pointer. Assume all app containers can use attached identities; expose no archive, Graph or resource-write privilege to the viewer.
- Before feature completion, pass the design native gates in the authorized lab with concrete tenant/subscription/group/test users&colon; allowed and denied report/asset/host access, exact report bytes, concurrency/staleness, provider-specific rotation/cold start, rollback and ownership-aware cleanup. Preserve failed evidence; no live success claim from fixtures.

**Validation:**

- Run the existing standalone validation workflow and new offline native fixtures; fixtures do not prove live auth, provider acceptance or report receipt.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-maester/blob/main/docs/report-viewer-design.md
- https&colon;//github.com/nathanmcnulty/azd-maester/issues/5

**Evidence:**

- _none_

**Review and authorization note:**

Review MCAJ-007 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MCAJ-008: Implement optional Static Web Apps Standard report viewer

- **Kind:** feature
- **Priority:** P2
- **Status:** proposed
- **Wave:** 4
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

The shared viewer design is complete, but this standalone Container App Job runner has no Static Web Apps provider implementation.

**Scope:**

- infra/
- scripts/
- docs/
- azd-permissions.json

**Acceptance:**

- Add exact -IncludeStaticWebApp mapping, default-off and exclusive with both other viewer flags, including legacy -IncludeWebApp; preserve existing hooks and deployment-validation behavior.
- Use Standard/custom tenant issuer and a reviewed Report.Reader role-source function/claim mapping with fail-closed missing, invalid and overage claim behavior; do not add tenant-wide Graph reads.
- Keep end-user UAMI/FIC distinct from the high-trust deployment-token publisher; bind fixed safe HTML, auth config, hash, revocation/reset and owned teardown receipts. Validate offline before authorized lab writes.
- Qualify the documented preview/support posture of function-based role assignment. Keep site-deployment authority and token access out of Maester runners&colon; a separate trusted publisher must bind fixed auth/function config hashes and reject report-supplied config or code.
- Before feature completion, pass the design native gates in the authorized lab with concrete tenant/subscription/group/test users&colon; allowed and denied report/asset/host access, exact report bytes, concurrency/staleness, provider-specific rotation/cold start, rollback and ownership-aware cleanup. Preserve failed evidence; no live success claim from fixtures.

**Validation:**

- Run the existing standalone validation workflow and new offline native fixtures; no deployment or delivery claim is made.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-maester/blob/main/docs/report-viewer-design.md
- https&colon;//github.com/nathanmcnulty/azd-maester/issues/4

**Evidence:**

- _none_

**Review and authorization note:**

Review MCAJ-008 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## MCAJ-010: Implement approved data-only configuration drift inputs

- **Kind:** feature
- **Priority:** P2
- **Status:** proposed
- **Wave:** 4
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Upstream drift comparison exists, but this host has no approved artifact/target/privacy contract or live qualification.

**Scope:**

- scripts/Invoke-MaesterContainerJob.ps1
- tests/
- docs/
- azd-permissions.json

**Acceptance:**

- Follow the reviewed MCAT-011 design&colon; explicitly enabled data-only artifacts, immutable approved baseline, tenant/environment/run/source/hash/freshness binding, bounded JSON/path/link/duplicate validation and reviewed schemas, normalization and exclusions.
- Use the actual locked upstream suite with expected positive case counts and fail on missing suite, zero cases, malformed/scalar/settings inputs, comparison errors and container failures; preserve default-off isolation and reused-process environment restoration.
- Inspect actual HTML/JSON/Markdown/logs for planted sensitive values; preserve separate comparison, report and publication outcomes and rollback. Add no automatic capture, baseline update or remediation.
- Independently review the adapter and qualify authorized native job execution, report access, rollback and exact owned cleanup; coordinate a second host before shared extraction.

**Validation:**

- PowerShell 7.6+/Pester 6.2 registered tests and actual locked suite/report fixtures.
- Separate authorized native host/report/access/cleanup qualification; local metadata grants no live authority.

**Dependencies:**

- MCAJ-009

**Components:**

- _none_

**Sources:**

- docs/drift-isolation.md
- https&colon;//github.com/nathanmcnulty/azd-maester/blob/a6e301310ccae0519288b794eb95aae3af43fa08/docs/drift-analysis-design.md
- https&colon;//github.com/nathanmcnulty/azd-maester/issues/2

**Evidence:**

- _none_

**Review and authorization note:**

Review MCAJ-010 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.
