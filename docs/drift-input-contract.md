# Approved drift input preparation

`scripts/Maester.DriftInputs.psm1` implements the input boundary for MCAJ-010.
It validates and stages data for the locked Maester drift suite. It does not yet
enable that suite in the Container Apps Job runner, upload inputs, collect
configuration, approve a baseline, publish reports or change permissions. The
runner retains its default-disabled isolation. MCAT-011 coordinates the wider
host rollout; this host task remains in progress.

Use PowerShell 7.6+ and import the module from this checkout. The exported
`Initialize-MaesterDriftInput` command requires:

| Argument | Authority and meaning |
| --- | --- |
| `InputRoot` | Existing directory containing only the files below. |
| `StagingParent` | Existing caller-owned normal directory outside InputRoot, protected from untrusted replacement; a fresh private child is allocated. |
| `ExpectedBaselineManifestSha256` | Lowercase SHA-256 supplied from an independently reviewed approval record, outside the artifact. |
| `TenantId`, `Environment`, `RunId` | Exact expected target/environment and selected run. GUIDs must be nonzero. |
| `ProducerId`, `ProducerRevision` | Expected export producer label and immutable lowercase Git revision. |
| `MaxAgeMinutes` | Current-input age bound, 1–60 minutes; default 30. At most one minute of future clock skew is tolerated. |
| `Now` | Evaluation clock, default UTC now; injectable for deterministic tests. Production callers must use the trusted host clock. |

The caller must obtain the expected digest and target/producer context from its
trusted orchestration configuration. Computing the expected digest from an
untrusted incoming package does not approve that package. A digest proves bytes,
not who collected them, permission to collect, completeness, provenance or actual
administrator approval. Manifest labels remain producer assertions. The helper
does not authenticate those assertions or acquire a trusted clock.

## Package

All files are UTF-8 JSON without BOM, comments or trailing commas. There are
exactly two manifests and two fixed files per case. Case IDs match
`[a-z][a-z0-9-]{0,31}` and are unique. No directories, scripts, links/reparse
points, extra files or path fields are accepted. Existing ancestor links are
also rejected. JSON property names cannot repeat or collide by case.

```text
baseline-manifest.json
current-manifest.json
case-1.baseline.json
case-1.current.json
```

`baseline-manifest.json` has exactly these fields:

```json
{
  "schemaVersion": "1.0",
  "tenantId": "00000000-0000-0000-0000-000000000001",
  "environment": "fixture",
  "host": "containerappjob",
  "revision": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "approvalReference": "fixture-only",
  "normalizationRevision": "identity.v1",
  "cases": [{
    "id": "case-1",
    "sha256": "REPLACE_WITH_BASELINE_FILE_SHA256",
    "length": 16,
    "schemaRevision": "fixture.v1",
    "schema": {
      "type": "object",
      "properties": {"enabled": {"type": "boolean"}},
      "required": ["enabled"],
      "additionalProperties": false
    },
    "excludeProperties": []
  }]
}
```

This is a synthetic format illustration, not approval evidence. SHA placeholders
must be replaced with actual lowercase digests before validation.

`current-manifest.json` has exactly `schemaVersion`, `tenantId`, `environment`,
`host`, `runId`, `baselineManifestSha256`, `producerId`, `producerRevision`,
`normalizationRevision`, `capturedAt` and `cases`. Binding values must match the
explicit caller and approved baseline. `capturedAt` is an explicit UTC `Z`
timestamp. All binding headers must be strings and match by ordinal comparison;
JSON booleans, numbers and culture-equivalent text are not accepted. Each case
has exactly `id`, `sha256` and `length`, for the matching
`<id>.current.json`. Baseline and current cases have complete one-to-one parity.
Both file hashes and byte lengths are checked before staging.

The approved baseline digest covers the baseline bytes, schema, normalization
revision, exclusions, immutable source revision and approval reference. Every
input must validate against the approved schema. Root values must be nonempty
objects. This helper validates declared normalization; export producers perform
the actual normalization before creating their JSON.

## Bounds and schemas

Limits are 32 cases, 1 MiB per file including manifests, 16 MiB total including
manifests, and JSON depth 32. Reads use a bounded buffer; verified byte snapshots
are copied, without reopening source data after validation. Changing a source
file later does not change the prepared copy.

Schemas use a closed, reference-free subset: `type`, optional `enum` (1–64
entries), object `properties`/optional `required`/`additionalProperties: false`,
array `items`/`maxItems` (1–256), and string `maxLength` (1–4096). Object schemas
have 1–128 properties. Property/exclusion names are bounded ASCII identifiers
matching `[A-Za-z_][A-Za-z0-9_.-]{0,63}`. Only object, array, string, number,
integer, boolean and null types are accepted. Other keywords, including `$ref`,
patterns and remote schemas, are refused. Upstream comparison still has its
documented limits, including ignoring additional current-only properties;
schema validation does not turn it into a complete bidirectional comparator.

Export producers and approval reviewers must remove secrets, tokens, personal
data and sensitive descriptions before packaging. This is not a general
redactor. The helper emits safe failure codes and no source values, but Maester
comparison reports can include approved input values and differences. Schema
approval must therefore include the privacy of permitted values. Initial suite
qualification uses non-sensitive synthetic data only.

## Owned copies and remaining integration

The returned receipt contains the fresh `StageRoot`, case count/IDs, manifest
digests and run ID. Only `<id>/baseline.json`, `current.json` and generated
`settings.json` are staged. Windows staging disables inherited ACLs and grants
only the current identity full control; Unix uses mode 0700. Source artifacts
and the process drift environment variable are not changed. A failed preparation
cleans only its freshly allocated child. Successful copies remain caller-owned;
the future host lifecycle must delete that exact receipt-bound directory after
invocation, while preserving input baselines and other runs.

Next host integration must use only the locked built-in suite, require four
positive-discovery checks per expected case, preserve ordinary assessment and
genuine finding/report/publication failure semantics, restore ambient process
state on every exit, and bind private output/access/retention/rollback/cleanup.
No native job, workload identity, report access or live collection is qualified
by this local helper or its fixtures. A second real host integration is required
before extracting a shared adapter into `azd-reference`.

If partial-stage deletion fails, preparation throws `drift.stagingCleanupFailed`.
The private generated path is retained in `Exception.Data['StageRoot']` for the
trusted caller's recovery; it is not included in the safe error message. Callers
must preserve that recovery context privately and verify cleanup instead of
claiming success. Input errors that occur before allocation never delete a
pre-existing staging-name collision. Trailing directory separators are normalized
before overlap and cleanup checks.
