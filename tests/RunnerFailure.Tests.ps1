Describe 'Maester runner result boundary' {
  AfterAll {
    foreach ($name in 'RUNNER_TEST_ROOT', 'RUNNER_TEST_TEMP_ROOT', 'RUNNER_TEST_MODE', 'RUNNER_TEST_STORAGE', 'RUNNER_TEST_FAIL_UPLOAD') {
      [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
  }
  BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $env:RUNNER_TEST_ROOT = $repoRoot
    $runnerPath = Join-Path $repoRoot 'scripts/Invoke-MaesterContainerJob.ps1'
    $source = Get-Content -LiteralPath $runnerPath -Raw
    $start = $source.IndexOf('Write-Output "Running Invoke-Maester')
    $end = $source.IndexOf('# Publish to web app', $start)
    if ($start -lt 0 -or $end -le $start) { throw 'Could not isolate the production Maester run and report block.' }
    $runBlock = $source.Substring($start, $end - $start)
    $harness = @'
$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $env:RUNNER_TEST_ROOT 'scripts/Maester.AssessmentEvidence.psm1') -Force
. (Join-Path $env:RUNNER_TEST_ROOT 'tests/fixtures/AssessmentEvidence.ps1')
$maesterInvokeParameters = @{}
$tempRoot = $env:RUNNER_TEST_TEMP_ROOT
$testsPath = Join-Path $tempRoot 'tests'
$junitPath = Join-Path $tempRoot 'pester-junit.xml'
$StorageAccountName = $env:RUNNER_TEST_STORAGE
$ExportContainer = 'archive'
$DashboardContainer = 'latest'
function Write-Step { param([string] $Message) }
function Invoke-Maester {
  if ($env:RUNNER_TEST_MODE -eq 'throw') { throw 'simulated execution failure' }
  if ($env:RUNNER_TEST_MODE -eq 'result') {
    Set-Content -LiteralPath (Join-Path $tempRoot 'assessment.html') -Value '<html>security finding</html>'
    Set-Content -LiteralPath $junitPath -Value '<testsuites tests="5" errors="0" failures="1" disabled="3" />'
    $result = New-TestAssessmentResult $testsPath
    $result | Add-Member OutputFiles ([pscustomobject]@{ OutputHtmlFile = (Join-Path $tempRoot 'assessment.html') })
    return $result
  }
}
function Get-PlainToken { 'test-token' }
function Compress-GzipFile { param($InputPath, $OutputPath) }
function Set-BlobContent {
  param($AccountName, $Container, $BlobName, $SourcePath, $StorageToken, $ContentType, $AccessTier, $ContentEncoding)
  if ($BlobName -eq 'latest.html') {
    Set-Content -LiteralPath (Join-Path $tempRoot 'latest-attempted') -Value 'yes'
    if ($env:RUNNER_TEST_FAIL_UPLOAD -eq '1') { throw 'simulated upload failure' }
  }
}
'@ + "`n" + $runBlock + "`nWrite-Output 'RUNNER_SUCCESS'`n"
    $harnessPath = Join-Path $TestDrive 'runner-harness.ps1'
    Set-Content -LiteralPath $harnessPath -Value $harness
  }

  It 'exits nonzero and never creates success HTML when Invoke-Maester throws' {
    $env:RUNNER_TEST_TEMP_ROOT = Join-Path $TestDrive 'throw'
    $env:RUNNER_TEST_MODE = 'throw'
    $env:RUNNER_TEST_STORAGE = ''
    $env:RUNNER_TEST_FAIL_UPLOAD = '0'
    New-Item -ItemType Directory -Path $env:RUNNER_TEST_TEMP_ROOT | Out-Null
    $output = & pwsh -NoProfile -File $harnessPath 2>&1
    $LASTEXITCODE | Should -Be 1
    @($output) -join "`n" | Should -Not -Match 'RUNNER_SUCCESS|Maester Run Completed'
    @(Get-ChildItem -LiteralPath $env:RUNNER_TEST_TEMP_ROOT -Filter '*.html').Count | Should -Be 0
  }

  It 'exits nonzero when Maester produces no report' {
    $env:RUNNER_TEST_TEMP_ROOT = Join-Path $TestDrive 'missing'
    $env:RUNNER_TEST_MODE = 'missing'
    $env:RUNNER_TEST_STORAGE = ''
    $env:RUNNER_TEST_FAIL_UPLOAD = '0'
    New-Item -ItemType Directory -Path $env:RUNNER_TEST_TEMP_ROOT | Out-Null
    $output = & pwsh -NoProfile -File $harnessPath 2>&1
    $LASTEXITCODE | Should -Be 1
    @($output) -join "`n" | Should -Not -Match 'RUNNER_SUCCESS|Maester Run Completed'
    @(Get-ChildItem -LiteralPath $env:RUNNER_TEST_TEMP_ROOT -Filter '*.html').Count | Should -Be 0
  }

  It 'preserves genuine test findings as a successful runner result' {
    $env:RUNNER_TEST_TEMP_ROOT = Join-Path $TestDrive 'finding'
    $env:RUNNER_TEST_MODE = 'result'
    $env:RUNNER_TEST_STORAGE = ''
    $env:RUNNER_TEST_FAIL_UPLOAD = '0'
    New-Item -ItemType Directory -Path $env:RUNNER_TEST_TEMP_ROOT | Out-Null
    $output = & pwsh -NoProfile -File $harnessPath 2>&1
    $LASTEXITCODE | Should -Be 0
    @($output) -join "`n" | Should -Match 'RUNNER_SUCCESS'
    Get-Content -LiteralPath (Join-Path $env:RUNNER_TEST_TEMP_ROOT 'assessment.html') -Raw | Should -Match 'security finding'
  }

  It 'exits nonzero when publishing the latest report fails' {
    $env:RUNNER_TEST_TEMP_ROOT = Join-Path $TestDrive 'upload'
    $env:RUNNER_TEST_MODE = 'result'
    $env:RUNNER_TEST_STORAGE = 'test-account'
    $env:RUNNER_TEST_FAIL_UPLOAD = '1'
    New-Item -ItemType Directory -Path $env:RUNNER_TEST_TEMP_ROOT | Out-Null
    $output = & pwsh -NoProfile -File $harnessPath 2>&1
    $LASTEXITCODE | Should -Be 1
    (Test-Path -LiteralPath (Join-Path $env:RUNNER_TEST_TEMP_ROOT 'latest-attempted')) | Should -BeTrue
    @($output) -join "`n" | Should -Not -Match 'RUNNER_SUCCESS'
  }
}
