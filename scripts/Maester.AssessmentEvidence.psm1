Set-StrictMode -Version Latest

# Deliberately separate framework health from policy compliance. These are two
# unconditional core tests in the locked Maester 2.2.0 suite, not a coverage claim.
$script:CoreCases = [ordered]@{
  'MT.1068' = 'Maester/Entra/Test-MtTenantCreationRestricted.Tests.ps1'
  'MT.1069' = 'Maester/Entra/Test-MtSecurityGroupCreationRestricted.Tests.ps1'
}

function Get-EvidenceCount {
  param($Value)
  if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string] -or
      $Value -isnot [ValueType] -or $Value -lt 0 -or $Value -gt [int]::MaxValue -or
      [decimal]$Value -ne [math]::Truncate([decimal]$Value)) { throw 'assessment.invalidCount' }
  [int]$Value
}

function Get-MaesterEvidenceSource {
  param([Parameter(Mandatory)][string]$ScriptsRoot, [Parameter(Mandatory)][string]$LockPath)
  [ordered]@{
    RunnerSha256 = (Get-FileHash -LiteralPath (Join-Path $ScriptsRoot 'Invoke-MaesterContainerJob.ps1') -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    GateSha256 = (Get-FileHash -LiteralPath (Join-Path $ScriptsRoot 'Maester.AssessmentEvidence.psm1') -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    PackageLockSha256 = (Get-FileHash -LiteralPath $LockPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
  }
}

function Get-MaesterAssessmentEvidence {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Output,
    [Parameter(Mandatory)][string]$JunitPath,
    [Parameter(Mandatory)][string]$TestsPath,
    [Parameter(Mandatory)][string]$ReportPath
  )
  $ErrorActionPreference = 'Stop'
  # Ignore incidental success-stream strings, but never select one of multiple
  # result objects. No HTML/JavaScript is evaluated to recover missing evidence.
  $results = @($Output | Where-Object { $null -ne $_ -and $_.PSObject.Properties['Tests'] })
  if ($results.Count -ne 1) { throw 'assessment.resultMissingOrAmbiguous' }
  $result = $results[0]
  if ($result.EndOfJson -isnot [string] -or $result.EndOfJson -cne 'EndOfJson' -or
      ($result.CurrentVersion -isnot [string] -and $result.CurrentVersion -isnot [version]) -or
      [string]$result.CurrentVersion -cne '2.2.0') { throw 'assessment.resultInvalid' }
  $tests = @($result.Tests)
  foreach ($test in $tests) {
    if ($null -eq $test -or $test.Result -isnot [string]) { throw 'assessment.resultInvalid' }
  }
  $counts = [ordered]@{}
  foreach ($state in 'Passed','Failed','Error','Investigate','Skipped','NotRun') {
    $name = $state + 'Count'
    $counts[$name] = Get-EvidenceCount $result.$name
    if ($counts[$name] -ne @($tests | Where-Object Result -CEQ $state).Count) { throw 'assessment.countMismatch' }
  }
  $counts.TotalCount = Get-EvidenceCount $result.TotalCount
  $sum = 0L
  foreach ($state in 'Passed','Failed','Error','Investigate','Skipped','NotRun') { $sum += $counts[$state + 'Count'] }
  if ($sum -ne $counts.TotalCount -or $tests.Count -ne $counts.TotalCount -or $sum -eq 0) { throw 'assessment.countMismatch' }
  if ($counts.ErrorCount -ne 0) { throw 'assessment.maesterErrors' }
  # Maester reclassifies only selected exception types. An IOException or a
  # mixed assertion/runtime error can still be labelled Failed (or Investigate).
  # Check every record, never only the first, using Pester's stable marker IDs.
  foreach ($test in $tests) {
    if (-not $test.PSObject.Properties['ErrorRecord']) { throw 'assessment.errorRecordsMissing' }
    $records = @($test.ErrorRecord | Where-Object { $null -ne $_ })
    $allowed = switch ($test.Result) {
      'Failed' { @('PesterAssertionFailed') }
      'Skipped' { @('PesterTestSkipped') }
      'Investigate' { @('PesterAssertionFailed','PesterTestSkipped','PesterTestInconclusive') }
      default { @() }
    }
    if ($test.Result -ceq 'Failed' -and $records.Count -eq 0) { throw 'assessment.unclassifiedFailure' }
    foreach ($record in $records) {
      if ($record.FullyQualifiedErrorId -isnot [string] -or $record.FullyQualifiedErrorId -cnotin $allowed) { throw 'assessment.unclassifiedFailure' }
    }
  }
  $core = [ordered]@{}
  foreach ($id in $script:CoreCases.Keys) {
    $matches = @($tests | Where-Object Id -CEQ $id)
    $expectedPath = [IO.Path]::GetFullPath((Join-Path $TestsPath $script:CoreCases[$id]))
    if ($matches.Count -ne 1 -or $matches[0].Result -cnotin @('Passed','Failed') -or
        [string]::IsNullOrWhiteSpace($matches[0].ScriptBlockFile) -or
        [IO.Path]::GetFullPath($matches[0].ScriptBlockFile) -cne $expectedPath) { throw 'assessment.coreNotExecuted' }
    $core[$id] = $matches[0].Result
  }
  $reader = $null
  try {
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 16777216
    $reader = [Xml.XmlReader]::Create($JunitPath, $settings)
    $document = [Xml.XmlDocument]::new()
    $document.XmlResolver = $null
    $document.Load($reader)
    $root = $document.DocumentElement
    if ($null -eq $root -or $root.get_Name() -cne 'testsuites') { throw 'assessment.junitInvalid' }
    $junit = [ordered]@{}
    foreach ($name in 'tests','errors','failures','disabled') {
      $n = 0
      if (-not $root.HasAttribute($name) -or $root.GetAttribute($name) -cnotmatch '^(0|[1-9][0-9]*)\z' -or
          -not [int]::TryParse($root.GetAttribute($name), [ref]$n)) { throw 'assessment.junitInvalid' }
      $junit[$name] = $n
    }
  }
  catch { throw 'assessment.junitInvalid' }
  finally { if ($null -ne $reader) { $reader.Dispose() } }
  # Pester 6.2.0 root errors = FailedContainersCount + FailedBlocksCount.
  # Maester can reclassify Pester failures/skips as Investigate, so do not equate
  # every Pester failure with a policy finding or reject expected exclusions.
  if ($junit.errors -ne 0) { throw 'assessment.junitErrors' }
  if ($junit.tests -ne $counts.TotalCount -or
      $junit.failures -lt $counts.FailedCount -or $junit.failures -gt ($counts.FailedCount + $counts.InvestigateCount) -or
      $junit.disabled -lt ($counts.SkippedCount + $counts.NotRunCount) -or
      $junit.disabled -gt ($counts.SkippedCount + $counts.NotRunCount + $counts.InvestigateCount) -or
      (($junit.failures - $counts.FailedCount) + ($junit.disabled - $counts.SkippedCount - $counts.NotRunCount)) -gt $counts.InvestigateCount -or
      ($junit.failures + $junit.disabled) -gt $junit.tests) { throw 'assessment.junitCountMismatch' }
  if ([string]::IsNullOrWhiteSpace($result.OutputFiles.OutputHtmlFile) -or [IO.Path]::GetFullPath($result.OutputFiles.OutputHtmlFile) -cne [IO.Path]::GetFullPath($ReportPath)) { throw 'assessment.reportMismatch' }
  if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf) -or (Get-Item -LiteralPath $ReportPath).Length -le 0) { throw 'assessment.reportMissing' }
  [ordered]@{
    Outcome = 'Completed'; Counts = $counts; CoreCases = $core
    JunitErrors = $junit.errors; JunitTests = $junit.tests
    ReportSha256 = (Get-FileHash -LiteralPath $ReportPath -Algorithm SHA256).Hash.ToLowerInvariant()
    JunitSha256 = (Get-FileHash -LiteralPath $JunitPath -Algorithm SHA256).Hash.ToLowerInvariant()
  }
}

function Assert-EvidenceObject {
  param($Value, [string[]]$Keys)
  if ($Value -isnot [Collections.IDictionary] -or $Value.get_Count() -ne $Keys.Count) { throw 'validation.receiptShape' }
  foreach ($key in $Value.Keys) { if ($key -cnotin $Keys) { throw 'validation.receiptShape' } }
}

function Assert-EvidenceStrings {
  param([Collections.IDictionary]$Value, [string[]]$Keys)
  foreach ($key in $Keys) {
    if ($Value[$key] -isnot [string]) { throw 'validation.receiptScalarRequired' }
  }
}

function Assert-MaesterValidationReceipt {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Json,
    [Parameter(Mandatory)][string]$ExecutionName,
    [Parameter(Mandatory)][Collections.IDictionary]$ExpectedSource,
    [Parameter(Mandatory)][Collections.IDictionary]$ExpectedModules,
    [Parameter(Mandatory)][datetimeoffset]$NotBefore,
    [datetimeoffset]$Now = [datetimeoffset]::UtcNow,
    [Parameter(Mandatory)][bool]$ExpectWebApp,
    [bool]$ExpectMail = $false
  )
  $ErrorActionPreference = 'Stop'
  try {
    if ($Json.Length -gt 16384) { throw 'oversized' }
    # JsonDocument rejects malformed input; enumerate properties to reject
    # duplicate keys rather than allowing last-key-wins coercion.
    $doc = [Text.Json.JsonDocument]::Parse($Json)
    try {
      $stack = [Collections.Generic.Stack[Text.Json.JsonElement]]::new()
      $stack.Push($doc.RootElement)
      while ($stack.Count) {
        $element = $stack.Pop()
        if ($element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
          $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
          foreach ($property in $element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) { throw 'duplicate' }
            $stack.Push($property.Value)
          }
        }
        elseif ($element.ValueKind -eq [Text.Json.JsonValueKind]::Array) { foreach ($item in $element.EnumerateArray()) { $stack.Push($item) } }
      }
    }
    finally { $doc.Dispose() }
    $r = ConvertFrom-Json -InputObject $Json -AsHashtable -DateKind String -ErrorAction Stop
    Assert-EvidenceObject $r @('SchemaVersion','Kind','ExecutionName','StartedAt','CompletedAt','Source','Runtime','Assessment','Publication')
    Assert-EvidenceObject $r.Source @('RunnerSha256','GateSha256','PackageLockSha256')
    Assert-EvidenceObject $r.Runtime @('PowerShell','DotNet','Edition','OS','Architecture','Modules')
    Assert-EvidenceObject $r.Runtime.Modules @($ExpectedModules.Keys)
    Assert-EvidenceObject $r.Assessment @('Outcome','Counts','CoreCases','JunitErrors','JunitTests','ReportSha256','JunitSha256')
    Assert-EvidenceObject $r.Assessment.Counts @('TotalCount','PassedCount','FailedCount','ErrorCount','InvestigateCount','SkippedCount','NotRunCount')
    Assert-EvidenceObject $r.Assessment.CoreCases @($script:CoreCases.Keys)
    Assert-EvidenceObject $r.Publication @('Archive','Latest','WebApp','Mail')
    # PowerShell comparison operators filter arrays; an array of matching
    # strings can otherwise pass -cne/-cnotmatch checks. Require scalar leaves.
    Assert-EvidenceStrings $r @('Kind','ExecutionName','StartedAt','CompletedAt')
    Assert-EvidenceStrings $r.Source @($r.Source.Keys)
    Assert-EvidenceStrings $r.Runtime @('PowerShell','DotNet','Edition','OS','Architecture')
    Assert-EvidenceStrings $r.Runtime.Modules @($ExpectedModules.Keys)
    Assert-EvidenceStrings $r.Assessment @('Outcome','ReportSha256','JunitSha256')
    Assert-EvidenceStrings $r.Assessment.CoreCases @($script:CoreCases.Keys)
    Assert-EvidenceStrings $r.Publication @($r.Publication.Keys)
    if ((Get-EvidenceCount $r.SchemaVersion) -ne 1 -or $r.Kind -cne 'MaesterContainerAssessment' -or $r.ExecutionName -cne $ExecutionName) { throw 'identity' }
    $started = [datetimeoffset]::ParseExact($r.StartedAt, 'o', [Globalization.CultureInfo]::InvariantCulture)
    $completed = [datetimeoffset]::ParseExact($r.CompletedAt, 'o', [Globalization.CultureInfo]::InvariantCulture)
    if ($started -lt $NotBefore.AddMinutes(-2) -or $completed -lt $started -or $completed -gt $Now.AddMinutes(2)) { throw 'time' }
    foreach ($name in 'RunnerSha256','GateSha256','PackageLockSha256') {
      if ($r.Source[$name] -cnotmatch '^[0-9a-f]{64}\z' -or $r.Source[$name] -cne $ExpectedSource[$name]) { throw 'source' }
    }
    if ($r.Runtime.Edition -cne 'Core' -or $r.Runtime.OS -cne 'Linux' -or $r.Runtime.Architecture -cne 'X64' -or
        $r.Runtime.PowerShell -cne '7.6.6' -or ([version]$r.Runtime.DotNet).Major -ne 10) { throw 'runtime' }
    foreach ($name in $ExpectedModules.Keys) { if ($r.Runtime.Modules[$name] -cne $ExpectedModules[$name]) { throw 'modules' } }
    $a = $r.Assessment
    if ($a.Outcome -cne 'Completed' -or (Get-EvidenceCount $a.Counts.ErrorCount) -ne 0 -or (Get-EvidenceCount $a.JunitErrors) -ne 0) { throw 'assessment' }
    $sum = 0L
    foreach ($state in 'Passed','Failed','Error','Investigate','Skipped','NotRun') { $sum += Get-EvidenceCount $a.Counts[$state + 'Count'] }
    if ($sum -ne (Get-EvidenceCount $a.Counts.TotalCount) -or $sum -eq 0 -or $sum -ne (Get-EvidenceCount $a.JunitTests) -or
        ($a.Counts.PassedCount + $a.Counts.FailedCount) -lt $script:CoreCases.Count) { throw 'counts' }
    foreach ($id in $script:CoreCases.Keys) { if ($a.CoreCases[$id] -cnotin @('Passed','Failed')) { throw 'core' } }
    foreach ($name in 'ReportSha256','JunitSha256') { if ($a[$name] -cnotmatch '^[0-9a-f]{64}\z') { throw 'hash' } }
    if ($r.Publication.Archive -cne 'Published' -or $r.Publication.Latest -cne 'Published' -or $r.Publication.Mail -cne $(if ($ExpectMail) { 'UpstreamUnverified' } else { 'Disabled' }) -or
        $r.Publication.WebApp -cne $(if ($ExpectWebApp) { 'Published' } else { 'Disabled' })) { throw 'publication' }
    $r
  }
  catch { throw 'validation.receiptInvalidOrMismatched' }
}

Export-ModuleMember -Function Get-MaesterEvidenceSource, Get-MaesterAssessmentEvidence, Assert-MaesterValidationReceipt
