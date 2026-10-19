#Requires -Version 7.6
# Offline qualification of the existing explicit drift adapter with synthetic data.
[CmdletBinding()]
param([string]$MaesterManifest)
$ErrorActionPreference = 'Stop'
Import-Module Pester -RequiredVersion 6.2.0 -Force
if ($MaesterManifest) { Import-Module $MaesterManifest -Force }
else { Import-Module Maester -RequiredVersion 2.3.0 -Force }
$module = Get-Module Maester
if ($module.Version -ne [version]'2.3.0') { throw 'Actual Maester 2.3.0 is required.' }
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'scripts/Maester.DriftInputs.psm1') -Force
Import-Module (Join-Path $root 'scripts/Maester.DriftRun.psm1') -Force
$source = Get-Content (Join-Path $root 'scripts/Invoke-MaesterContainerJob.ps1') -Raw
$start = $source.IndexOf('$pesterConfig = [PesterConfiguration]@{')
$end = $source.IndexOf('if (-not $EnableApprovedDrift', $start)
$configBlock = [scriptblock]::Create($source.Substring($start, $end - $start))
$start = $source.IndexOf('Write-Output "Running Invoke-Maester')
$end = $source.IndexOf("Write-Output 'Invoke-Maester execution completed.'", $start)
$invokeBlock = [scriptblock]::Create($source.Substring($start, $end - $start))
$global:Maester230DriftTransportAttempts = 0
foreach ($command in @('Invoke-WebRequest','Invoke-RestMethod','Invoke-MgGraphRequest','Connect-MgGraph','Connect-AzAccount','Connect-ExchangeOnline','Connect-MicrosoftTeams','Install-Module','Send-MtMail','Send-MtTeamsMessage')) {
    Set-Item -Path "function:global:$command" -Value { $global:Maester230DriftTransportAttempts++; throw 'OFFLINE_TRANSPORT_FORBIDDEN' }
}
function Write-FixtureJson($Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
}
$temp = Join-Path ([IO.Path]::GetTempPath()) "maester-230-drift-compat-$([guid]::NewGuid().ToString('N'))"
$oldAmbient = [Environment]::GetEnvironmentVariable('MAESTER_FOLDER_DRIFT','Process')
$checks = [Collections.Generic.List[object]]::new()
try {
    $inputs = Join-Path $temp 'inputs'
    $testsPath = Join-Path $temp 'tests'
    $suiteFolder = Join-Path $testsPath 'Maester/Drift'
    New-Item -ItemType Directory -Path $inputs, $suiteFolder -Force | Out-Null
    $suite = Join-Path $suiteFolder 'MT1060Drift.tests.ps1'
    Copy-Item (Join-Path $module.ModuleBase 'maester-tests/Maester/Drift/MT1060Drift.tests.ps1') $suite
    Assert-MaesterDriftSuite -SuitePath $suite | Out-Null
    "Describe 'Ordinary assessment' { It 'OFFLINE.ORDINARY: Intentional synthetic policy finding.' { 1 | Should -Be 2 } }" | Set-Content (Join-Path $testsPath 'Ordinary.Tests.ps1')
    $tenant = '00000000-0000-0000-0000-000000000001'; $runId = '00000000-0000-0000-0000-000000000002'
    $baseline = @{schemaVersion='1.0';tenantId=$tenant;environment='fixture';host='containerappjob';revision=('b'*40);approvalReference='offline-fixture-only';normalizationRevision='identity.v1';cases=@()}
    $current = @{schemaVersion='1.0';tenantId=$tenant;environment='fixture';host='containerappjob';runId=$runId;baselineManifestSha256=('0'*64);producerId='offline-fixture';producerRevision=('a'*40);normalizationRevision='identity.v1';capturedAt=[datetimeoffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ');cases=@()}
    $schema = @{type='object';properties=@{enabled=@{type='boolean'}};required=@('enabled');additionalProperties=$false}
    foreach ($id in @('equal','changed')) {
        $baselinePath = Join-Path $inputs "$id.baseline.json"
        $currentPath = Join-Path $inputs "$id.current.json"
        Write-FixtureJson $baselinePath @{enabled=$true}
        Write-FixtureJson $currentPath @{enabled=($id -eq 'equal')}
        $baseline.cases += @{id=$id;sha256=(Get-FileHash $baselinePath).Hash.ToLowerInvariant();length=(Get-Item $baselinePath).Length;schemaRevision='fixture.v1';schema=$schema;excludeProperties=@()}
        $current.cases += @{id=$id;sha256=(Get-FileHash $currentPath).Hash.ToLowerInvariant();length=(Get-Item $currentPath).Length}
    }
    Write-FixtureJson (Join-Path $inputs 'baseline-manifest.json') $baseline
    $baselineHash = (Get-FileHash (Join-Path $inputs 'baseline-manifest.json')).Hash.ToLowerInvariant()
    $current.baselineManifestSha256 = $baselineHash
    Write-FixtureJson (Join-Path $inputs 'current-manifest.json') $current
    $originalHashes = @(Get-ChildItem $inputs -File | Sort-Object Name | Get-FileHash | Select-Object Hash | ConvertTo-Json -Compress)
    foreach ($ambient in @('absent','empty','inherited')) {
        $value = switch ($ambient) { 'absent' { [Management.Automation.Language.NullString]::Value }; 'empty' { '' }; 'inherited' { 'unapproved-inherited-fixture' } }
        [Environment]::SetEnvironmentVariable('MAESTER_FOLDER_DRIFT', $value, 'Process')
        $expectedAmbient = [Environment]::GetEnvironmentVariable('MAESTER_FOLDER_DRIFT','Process')
        $approvedDriftRun = New-MaesterDriftRunRoot
        try {
            $approvedDriftReceipt = Initialize-MaesterDriftInput -InputRoot $inputs -StagingParent $approvedDriftRun.StagingParent -ExpectedBaselineManifestSha256 $baselineHash -TenantId $tenant -Environment fixture -RunId $runId -ProducerId offline-fixture -ProducerRevision ('a'*40)
            $tempRoot = $approvedDriftRun.OutputParent
            $junitPath = Join-Path $tempRoot 'pester-junit.xml'
            $EnableApprovedDrift = $true
            . $configBlock
            $maesterInvokeParameters.SkipGraphConnect = $true
            . $invokeBlock
            $r = $approvedDriftRunResult.Result
            if ([string]$r.CurrentVersion -cne '2.3.0' -or $r.TotalCount -ne 9 -or $r.PassedCount -ne 7 -or $r.FailedCount -ne 2 -or $r.ErrorCount -ne 0) { throw 'Unexpected real 2.3.0 drift accounting.' }
            if (Test-Path $approvedDriftReceipt.StageRoot) { throw 'Prepared stage was not cleaned.' }
            $actualAmbient = [Environment]::GetEnvironmentVariable('MAESTER_FOLDER_DRIFT','Process')
            if (($null -eq $actualAmbient) -ne ($null -eq $expectedAmbient) -or $actualAmbient -cne $expectedAmbient) { throw 'Ambient state changed.' }
            $checks.Add([ordered]@{Ambient=$ambient;Total=9;Passed=7;IntentionalFindings=2;Errors=0;StageRemoved=$true})
        } finally {
            Remove-DriftOwnedDirectory -Path $approvedDriftRun.Root -Parent $approvedDriftRun.Parent -LeafPattern ('^'+[regex]::Escape($approvedDriftRun.Leaf)+'\z')
        }
        if (Test-Path $approvedDriftRun.Root) { throw 'Owned run root was not removed.' }
    }
    if ((@(Get-ChildItem $inputs -File | Sort-Object Name | Get-FileHash | Select-Object Hash | ConvertTo-Json -Compress) -join '') -cne ($originalHashes -join '')) { throw 'Original input bytes changed.' }
    if ($global:Maester230DriftTransportAttempts -ne 0) { throw 'Network/authentication boundary was reached.' }
    [ordered]@{Kind='OfflineMaester230ApprovedDriftCompatibility';ModuleVersion='2.3.0';SuiteSha256=(Get-FileHash $suite).Hash.ToLowerInvariant();TransportAttempts=0;OriginalInputsPreserved=$true;Checks=@($checks.ToArray())} | ConvertTo-Json -Depth 5
} finally {
    [Environment]::SetEnvironmentVariable('MAESTER_FOLDER_DRIFT', $(if ($null -eq $oldAmbient) { [Management.Automation.Language.NullString]::Value } else { $oldAmbient }), 'Process')
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
