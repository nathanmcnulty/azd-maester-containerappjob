# Assessment integrity and execution receipts

Azure `Succeeded` describes the container process. It is not by itself evidence
that Maester discovered and executed a healthy assessment. A nonempty HTML report
can also contain framework or service errors. The ordinary runner now validates
structured evidence before publishing the HTML to Blob or the optional Web App.

## Bounded qualification contract

The locked Maester 2.2.0 `Invoke-Maester -PassThru` result is captured without
printing its tenant data or test details. Pester 6.2.0 separately writes JUnit XML
under the fresh, runner-owned temporary output directory. Exactly one converted
Maester result is required. Its six outcome counts must reconcile with its test
rows and total, and `ErrorCount` must be zero. The JUnit root `testsuites.errors`
must be zero; Pester defines it as `FailedContainersCount + FailedBlocksCount`,
including discovery and setup/teardown failures. Bounded XML parsing prohibits
DTDs and external resolution. JUnit totals and the range of possible
reclassified failure/disabled counts must reconcile with Maester counts.

Maester does not map every runtime exception to `Error`. The gate therefore also
checks each row's entire `ErrorRecord` set. `Failed` requires nonempty records
whose IDs are all exactly `PesterAssertionFailed`; `Skipped` permits only the
intentional `PesterTestSkipped` marker; `Investigate` permits only explicit
assertion/skip/inconclusive markers. Passed and NotRun rows may carry no errors.
Mixed assertion/runtime records and unclassified errors fail closed. This is
classification by Pester's contract, not by exception message or a growing
allowlist of runtime exception types.

Two unconditional core cases from the pinned suite must each occur exactly once
at their authored path, with `Passed` or `Failed`:

- MT.1068: restrict non-admin tenant creation
- MT.1069: restrict non-admin security-group creation

These sentinels exercise the Entra authorization-policy path. They establish a
minimum executed core assessment, not exhaustive coverage of all Graph roles,
services or tests. Ordinary policy `Failed` findings are valid completed
assessments. `Investigate`, expected `Skipped`, and `NotRun` outcomes are retained
and counted; no arbitrary total or all-tests-passed threshold is imposed.
Maester's default LongRunning, Preview and disconnected Active Directory
exclusions remain intact. Zero discovery, no core execution, unknown labels,
Maester errors and Pester engine errors fail closed.

The runner requests the fixed `assessment.html` filename inside its owned output
directory and matches it to the result's `OutputFiles.OutputHtmlFile`. It never
selects the newest HTML recursively. The receipt binds that file and JUnit by
SHA-256. Detailed reports/JUnit are not included in the receipt or printed by the
validator; normal report destinations remain unchanged.

## Receipt transport and caller requirements

After the ordinary assessment and publication attempts, the runner uploads a
version-1 JSON receipt to the existing private Blob container:

`archive/validation-receipts/<CONTAINER_APP_JOB_EXECUTION_NAME>.json`

Azure supplies the execution name. A missing/invalid name fails before identity
connection. The receipt records the execution, UTC start/completion times,
SHA-256 of the runner, evidence module and runtime package lock, actual loaded
module versions, runtime versions, sanitized counters/core outcomes, artifact
hashes, and separate archive/latest/Web App/mail outcomes. It contains no token,
tenant identity, test descriptions, raw errors or report body. Source hashes are
an attestation by the reviewed runner, not a cryptographic defense against a
compromised Blob writer. Native review must still verify the deployed bytes.

`Invoke-JobValidation.ps1` resolves the one storage destination from the selected
job's ARM template. It uses the operator's current, already-authorized Blob data
access. Before starting a job, it performs a bounded List Blobs request with the
receipt prefix and `maxresults=1`. This verifies that data-read route, not the
future receipt GET itself. After Azure reports `Succeeded`, the helper must GET
the exact execution receipt and validate it against this checkout's expected
source/lock, modules, time window and configured publication destinations. It
never falls back to an earlier receipt, a global latest JSON, HTML, or Azure
status. Blob requests use a validated account name, fixed HTTPS Azure hostname,
and disabled redirects. No role or permission is granted by the helper.

An operator without the existing data access receives a pre-start failure. A
receipt GET denied after preflight, a missing, stale, malformed, duplicate-key,
wrong-execution/source/runtime receipt, or failed required publication remains a
validation failure. `-PassThru` returns `ValidationPassed = true` only with valid
assessment and publication evidence. It also returns their sanitized summaries
and source hashes so policy findings are not confused with infrastructure health.
The archive upload remains best effort for ordinary production execution, but a
failed archive outcome cannot pass the qualification helper. Receipt upload
failure terminates the runner.

## Mail and optional scopes

Upstream Maester sends `MailRecipient` mail *inside* `Invoke-Maester`, before its
result returns. This post-return gate cannot prevent or retract that delivery.
Native qualification must call `Invoke-JobValidation.ps1 -RequireNoMail`; this
explicit switch refuses a nonempty `MAIL_RECIPIENT` before starting a job.

Normal postprovision calls the helper without that switch, preserving existing
mail-enabled deployment behavior. The helper still validates assessment integrity
and Blob/Web App publication, while matching configured inline mail to the
receipt's `UpstreamUnverified` state. Its `ValidationScope` is explicitly
`AssessmentAndBlobWebAppPublication`, and `MailDeliveryVerified` is always false.
A healthy assessment/publication result does not mean mail was delivered, nor
that an unhealthy run could not already have sent mail. Scheduled/direct mail is
unchanged. Mail must remain disabled for native qualification of this contract.
A separate future change would be needed to gate mail before delivery.

The existing explicitly enabled approved-drift adapter is unchanged and retains
its own input/case/JUnit checks. It does not issue this default-core receipt and
is not qualified by it. Neither this receipt nor unit tests attest to Azure
resource/grant cleanup, report audience/retention, scheduled firing, ACR native
hosting, Exchange/Teams coverage or enabled-drift transport. The operator must
retain the exact new head/tree and receipt and separately verify private report
access, report hash (decompress the archive first), approved cleanup and absence.
Do not reuse earlier successful executions to qualify changed source bytes.

This change does not expand the Minimal permission profile, alter test selection,
or repair missing service coverage. A default suite with unsupported-permission
errors will correctly fail the integrity gate. Any future profile-specific test
selection must be a separately explicit, reviewed coverage contract; errors must
not silently become exclusions merely to make qualification green.

## Sources

- [Maester 2.2.0 invocation](https://github.com/maester365/maester/blob/c657a4b8a24267ccd795edb0c7db402e0d440e3b/powershell/public/Invoke-Maester.ps1)
- [Maester result conversion and reclassification](https://github.com/maester365/maester/blob/c657a4b8a24267ccd795edb0c7db402e0d440e3b/powershell/internal/ConvertTo-MtMaesterResult.ps1)
- [Pester 6.2.0 JUnit root counters](https://github.com/pester/Pester/blob/6.2.0/src/functions/TestResults.JUnit4.ps1)
- [Azure built-in execution environment variables](https://learn.microsoft.com/azure/container-apps/environment-variables#built-in-environment-variables)
- [Blob List operation](https://learn.microsoft.com/rest/api/storageservices/list-blobs)

## Related Automation and shared-component follow-up

The Automation runbook/helper has the same status-versus-assessment distinction.
Keep its separate runtime-host patch independent. A focused dependent follow-up
should apply the structured Maester/JUnit health contract to its normal run and
validate a job-ID/source-bound sanitized receipt from Automation's existing job
output API. Preserve its separate import-only diagnostic receipt, no new grants,
policy findings, default-off drift and explicit no-mail qualification boundary. Do not edit
the active host-fix branch to combine these concerns.

If both adapters settle on the same small pure evidence validator, propose that
validator and its fixtures as a versioned Reference component, then adopt exact
hashes through the established component process. Azure-specific transport and
publication remain adapter-local. No cross-repository framework or vendored
Reference file is changed by this fix.
