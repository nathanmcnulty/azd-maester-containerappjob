# Configuration-drift isolation

This host does not yet accept approved drift baseline/current artifacts.
Setting `MAESTER_FOLDER_DRIFT` or placing a folder beside the runner cannot enable
drift. The runner excludes the locked upstream drift file before Pester discovery,
clears that environment variable during `Invoke-Maester`, and restores the prior
process value in `finally`. Ordinary assessment and publication behavior remains
host-owned, including genuine security findings and failure propagation.

MCAJ-009 tracks this default-off fix. MCAJ-010 retains optional approved inputs,
provenance/target binding, privacy, report outcomes and live qualification. The
[reviewed integration design](https://github.com/nathanmcnulty/azd-maester/blob/a6e301310ccae0519288b794eb95aae3af43fa08/docs/drift-analysis-design.md)
is the starting contract; disabling accidental discovery does not implement it.

## Upstream qualification

On 2026-10-16, an offline Windows process ran the actual Maester 2.2.0
`Invoke-Maester` and bundled `maester-tests/Maester/Drift/MT1060Drift.tests.ps1`
under PowerShell 7.6.6/Pester 6.2.0. Module SHA-256 was
`53e80f21006fcefffa79f4d2f84d470bbada9207114aaab5ea85edc8cc8bda1e`;
suite SHA-256 was
`4284b8a66d98ea82c3f3d6554f03188ab8dcf5cb6e72f11aec8538e08d5d3096`.
All data was synthetic, telemetry/version checks were disabled, Graph connection
was skipped, and HTTP/authentication tripwires recorded no attempts. This is local
suite/report qualification, not a Container Apps Job, identity or Blob proof.

The suite discovered 44 tests across eleven cases. Its 33 passes and 11 failures
include intentional negatives:

| Synthetic case | Passed / failed | Consequence for optional input support |
| --- | --- | --- |
| Equal objects | 4 / 0 | Normal suite discovery works |
| Changed value | 3 / 1 | Value differences fail |
| Missing property | 3 / 1 | Missing baseline properties fail |
| Malformed current JSON | 0 / 4 | BeforeAll fails; retain container errors |
| Empty current object | 2 / 2 | Empty input and comparison fail |
| Scalar roots `1` and `2` | 4 / 0 | Validate nonempty object roots before invoking the suite |
| Malformed settings JSON | 4 / 0 | Warning alone does not fail; validate settings first |
| Extra current property | 4 / 0 | Comparison covers selected baseline properties |
| Reordered array | 3 / 1 | Ordering matters |
| Excluded property | 4 / 0 | Exclusions need explicit review |
| Missing current file | 2 / 2 | Do not infer valid comparison from an existing baseline |

A second invocation in the same process omitted `DriftRoot` and still discovered
the same 44 tests through the inherited variable. An empty drift root produced a
discovery-container failure and a failed report with TotalCount and ErrorCount
both zero. Consumers must consider the overall result, discovery/container
failures and positive expected/discovered counts, not only ErrorCount.

Actual HTML, JSON and Markdown files were generated. A planted changed-value
canary appeared in the JSON and Markdown details. Arbitrary configuration values
are not automatically safe to publish; local file generation proves neither
privacy nor report access or receipt.

## Fix verification and remaining gates

`tests/DriftIsolation.Tests.ps1` verifies environment isolation/restoration on
success and throw, preserves an unset root, and runs a child Pester 6.2 process
using the production configuration. A drift fixture that writes a marker during
BeforeDiscovery is excluded, while an ordinary assessment test executes.
The two inherited-root cases and discovery case failed against the original
runner and pass with the fix.

A separate actual `Invoke-Maester` qualification used the production configuration
and invocation block, an unchanged hash-verified copy of the bundled suite,
one ordinary synthetic test and the prior unapproved 44-test input folder.
Exactly one ordinary test passed, the upstream drift file stayed excluded, and
the inherited root was restored. No HTTP/authentication tripwire fired. This
does not execute the complete deployed runner or its publisher.

There is no new permission or collector. Enabling drift still needs approved
bounded data-only artifacts, tenant/run/source/freshness/hash validation, reviewed
normalization/exclusions, immutable baseline approval and output privacy checks.
Native job execution, publication/access, rollback and owned cleanup remain
separate gates. Other canonical hosts still need their own isolation fixes.
