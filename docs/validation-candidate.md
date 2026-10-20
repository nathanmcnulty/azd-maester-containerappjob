# Container validation candidate (issue #39)

This candidate combines the reviewed runtime/target-guard stack with the manual,
default-off approved-drift stack. It is a source/CI artifact for issue #40, not
native Azure qualification. Original draft branches and historical receipts are
retained. No public or legacy report route is removed.

## Exact source inventory (2026-10-18)

All open source drafts are owned by `nathanmcnulty`. Main was
`1f34605d23e4f0536c9215d21f6368d98f5c30f4`. The working checkout was isolated and
clean before integration; no repository AGENTS.md was present.

| Draft | Exact head | Relationship / disposition |
| --- | --- | --- |
| #48 | `ad11ba68599ae2980ecc04c75aca06bb2e99e877` | First parent; publisher guards |
| #37 | `1d5ee5a3623a6e9a994b579959958ebc663f4117` | Ancestor of #48; canonical target guards |
| #35 | `16471ae721b59df71bffd6f919f1b70e7bb9ebc3` | Ancestor of #37; non-ACR runtime and CI exit fix |
| #32 | `ba7e43d8cf405fe287b2fb5e684845b3e3542219` | Ancestor of #35; ACR runtime |
| #31 | `5132a5320969d15ff8b707b5f4b97e2817aee3f3` | Second parent; approved manual drift |
| #30 | `f8510a3d27cdb328999531c7f2d6bc783413a5fa` | Ancestor of #31; default-disabled isolation |
| #29 | `7abdfa96d340aa9f31da82e22f6b3d12415cee82` | Independent optional viewer; excluded |

The two source stacks diverged from main. Merge ancestry preserves both histories;
no ancestor was cherry-picked again. Existing App Service report publication and
its lifecycle/failure behavior remain present. Optional viewer infrastructure,
images and publication paths from #29 are not part of this candidate.

## Integration seams

- A single runner parameter block supports runtime-only diagnostics and the
  existing explicit manual drift parameters. Linux x64/.NET 10/PowerShell 7.6+
  validation remains before module loading or authentication; runtime-only
  diagnostics still return before identity connection.
- Setup retains the exact guarded publisher from #48. Runtime staging now carries
  the two unchanged drift helper modules in both ACR and non-ACR modes. No input
  package is acquired or uploaded. Each of the six ACR/seven non-ACR uploads gets
  the same fresh canonical tenant/Enabled guard and explicit subscription.
- CI retains bootstrap fault tests, production ACR image checks and non-ACR
  bootstrap/locked-import checks, alongside the complete registered drift suite.
- Scheduled infrastructure and shell bootstrap do not enable drift. The manual
  PowerShell runner opt-in remains separate, requiring approved data and explicit
  selectors. Enabled drift still refuses mail/Web App destinations and preserves
  source-input, private-staging and owned-run cleanup boundaries.

## SHA-256 inventory

| Input | SHA-256 |
| --- | --- |
| runtime-packages.lock.json | `44abde8c67b92536b75dbb9e2b341838b6a6b842b898cc57be162fbc8e229f4a` |
| azd-components.lock.json | `eabeb84e705b53eb9e38377758272c0c9668ef1c506592332744165abeb92040` |
| Dockerfile | `2ce30390bf7275e5cdbbb15c96cd39c0302a74c506d65a1d496d2b6c714c076e` |
| Start-MaesterContainerJob.sh | `ba1100d9e251d57303fa3977630bc00d0430f360de4c0d78ec119b8bd6802394` |
| Invoke-MaesterContainerJob.ps1 | `b5dc7e5e1e660b2ea5da0432be562a1b817b896d5b1ddaa7aa905d79d7487790` |
| Maester-RuntimeFiles.psm1 | `a335061216071ff393239e34bb39eec1b8145639b09be089fa9e8bf6d707fda6` |
| Maester.DriftInputs.psm1 | `e5be767c201de120912d1984334b2704e15c475d1a7f60e9af4fb229aa1b79d4` |
| Maester.DriftRun.psm1 | `3b126e2ea19dae14e171e45d9027f62157fc29b1f2575669acd0ca0892ba6e4b` |

Both lock files, all nine runtime package versions/hashes, all eight canonical
component hashes at Reference revision
`fd26f7351f36c569067ae37edcb35d6b6cc40f29`, and the runtime base/archive pins are
unchanged from #48. Drift modules are byte-identical to #31. The official
PowerShell 7.6.6 archive remains SHA-256
`ddbc4a2d113bbd46d283cfedcbcd117a70caefd7673f41f2b4e0000badf103bc`.
There is no runtime fetch from Reference.

## Validation and remaining gates

Use PowerShell 7.6.6/Pester 6.2.0 with `POWERSHELL_TELEMETRY_OPTOUT=1` and
`DOTNET_CLI_TELEMETRY_OPTOUT=1`:

```powershell
Import-Module Pester -RequiredVersion 6.2.0
Invoke-Pester ./tests -CI
```

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
sh -n scripts/Start-MaesterContainerJob.sh
git diff --check
bicep build infra/main.bicep
```

Parse every `.ps1`/`.psm1`; verify canonical component drift, backlog schema and
generated Markdown, and permission-manifest schema with the maintained Reference
tooling at `96ddbe0867e961f852cd7c920f92f51473fbd64d`. Set
`$PSDefaultParameterValues["ConvertFrom-Json:DateKind"] = "String"` for the
backlog renderer to preserve historical ISO timestamp strings. Set
`DOTNET_BUNDLE_EXTRACT_BASE_DIR` to an owned writable temporary directory when
using the self-contained Bicep CLI. Local tests use fail-closed transport doubles, including an `az` stub
because Azure CLI is absent. Hosted `.github/workflows/validate.yml` additionally
builds the actual ACR image and exercises both production runtime modes. Docker
is unavailable in this local cloud checkout, so those checks require hosted CI.
The draft PR records the exact reviewed tree/head and final test/CI results.

Earlier native receipts remain valid only for their exact earlier bytes and
measured boundaries. Neither those receipts nor this candidate's offline/CI
results prove current keyless Blob delivery, Container App runtime, managed-identity
assessment, real report publication/access/retention, rollback or owned cleanup.
Those are explicit issue #40/sub-mvp owner-run gates. No Azure authentication,
resource mutation, permission grant, merge or release is performed by this work.
