Describe 'Maester runner result boundary' {
  AfterAll {
    foreach ($name in 'RUNNER_TEST_TEMP_ROOT', 'RUNNER_TEST_MODE', 'RUNNER_TEST_STORAGE', 'RUNNER_TEST_FAIL_UPLOAD', 'RUNNER_TEST_VIEWER', 'RUNNER_TEST_MODULE_ROOT', 'RUNNER_TEST_TOKEN_MARKER', 'RUNNER_TEST_RAW_REPORT', 'RUNNER_TEST_STORE_LOG', 'RUNNER_TEST_AZ_TENANT', 'RUNNER_TEST_GRAPH_TENANT') {
      [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
  }
  BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $runnerPath = Join-Path $repoRoot 'scripts/Invoke-MaesterContainerJob.ps1'
    $source = Get-Content -LiteralPath $runnerPath -Raw
    $tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$parseErrors)
    if($parseErrors){throw 'Runner source did not parse.'}
    $bindingNode=$ast.Find({param($node)$node-is[Management.Automation.Language.IfStatementAst]-and$node.Extent.Text.Contains('Assert-MaesterViewerRunnerTenantBinding')},$true)
    $bindingFunction=$ast.Find({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-eq'Assert-MaesterViewerRunnerTenantBinding'},$true)
    if(-not$bindingNode-or-not$bindingFunction){throw 'Runner tenant binding boundary was not found.'}
    $start = $source.IndexOf('Write-Output "Running Invoke-Maester')
    $end = $source.IndexOf('# Publish to web app', $start)
    if ($start -lt 0 -or $end -le $start -or $bindingNode.Extent.StartOffset -ge $start) { throw 'Could not isolate the ordered production tenant and report boundaries.' }
    $runBlock = $source.Substring($start, $end - $start)
    $harness = @'
$ErrorActionPreference = 'Continue'
$maesterInvokeParameters = @{}
$tempRoot = $env:RUNNER_TEST_TEMP_ROOT
$StorageAccountName = $env:RUNNER_TEST_STORAGE
$ExportContainer = 'archive'
$DashboardContainer = 'latest'
$viewerProjectionEnabled = $env:RUNNER_TEST_VIEWER -eq '1'
$viewerTenantId = '11111111-1111-1111-1111-111111111111'
$viewerEnvironment = 'runner-test'
$viewerStorageAccount = 'vieweraccount'
$viewerContainer = 'viewer-projection'
$moduleRoot = $env:RUNNER_TEST_MODULE_ROOT
$tenantId = $env:RUNNER_TEST_GRAPH_TENANT
function Get-AzContext { [pscustomobject]@{Tenant=[pscustomobject]@{Id=$env:RUNNER_TEST_AZ_TENANT}} }
function Write-Step { param([string] $Message) }
function Invoke-Maester {
  if ($env:RUNNER_TEST_MODE -eq 'throw') { throw 'simulated execution failure' }
  if ($env:RUNNER_TEST_MODE -eq 'result') {
    Set-Content -LiteralPath (Join-Path $tempRoot 'report.html') -Value '<html>security finding</html>'
  }
  if ($env:RUNNER_TEST_MODE -eq 'qualified') { Copy-Item -LiteralPath $env:RUNNER_TEST_RAW_REPORT -Destination (Join-Path $tempRoot 'report.html') }
}

function Get-PlainToken { 'test-token' }
function Add-RunnerEvent([string]$Value){Add-Content -LiteralPath $env:RUNNER_TEST_STORE_LOG -Value $Value}
function Get-AzAccessToken { Set-Content -LiteralPath $env:RUNNER_TEST_TOKEN_MARKER -Value called;Add-RunnerEvent token;[pscustomobject]@{Token=(ConvertTo-SecureString 'fixture-token' -AsPlainText -Force)} }
function ConvertTo-MaesterViewerRunnerProjection {param([byte[]]$ReportBytes,[byte[]]$TemplateBytes);$value=ConvertTo-MaesterViewerReportProjection -ReportBytes $ReportBytes -TemplateBytes $TemplateBytes -ErrorAction Stop;Add-RunnerEvent qualified;$value}
function New-MaesterViewerRunnerProjectionStore {
  param($AccountName,$ContainerName,[scriptblock]$TokenProvider)
  $null=& $TokenProvider;$items=@{};$counter=0;$log=$env:RUNNER_TEST_STORE_LOG
  return {
    param($Operation,$Key,[byte[]]$Bytes,$ContentType,$IfMatch,$IfNoneMatch,$MaximumBytes)
    Add-Content -LiteralPath $log -Value "$Operation $Key"
    if($Operation-eq'Get'){
      if(-not$items.ContainsKey($Key)){return [pscustomobject]@{status='missing';etag=$null;bytes=$null}}
      return [pscustomobject]@{status='found';etag=$items[$Key].etag;bytes=[byte[]]$items[$Key].bytes}
    }
    $counter++;$etag='"runner-'+$counter+'"';$items[$Key]=[pscustomobject]@{etag=$etag;bytes=[byte[]]$Bytes};[pscustomobject]@{status='created';etag=$etag}
  }.GetNewClosure()
}
function Compress-GzipFile { param($InputPath, $OutputPath) }
function Set-BlobContent {
  param($AccountName, $Container, $BlobName, $SourcePath, $StorageToken, $ContentType, $AccessTier, $ContentEncoding)
  if ($BlobName -eq 'latest.html') {
    Add-RunnerEvent legacy-latest
    Set-Content -LiteralPath (Join-Path $tempRoot 'latest-attempted') -Value 'yes'
    if ($env:RUNNER_TEST_FAIL_UPLOAD -eq '1') { throw 'simulated upload failure' }
  }
}
'@ + "`n" + $bindingFunction.Extent.Text + "`n" + $bindingNode.Extent.Text + "`n" + $runBlock + "`nWrite-Output 'RUNNER_SUCCESS'`n"
    $harnessPath = Join-Path $TestDrive 'runner-harness.ps1'
    Set-Content -LiteralPath $harnessPath -Value $harness
    Copy-Item (Join-Path $repoRoot 'scripts/Maester.ViewerContent.psm1') $TestDrive
    Copy-Item (Join-Path $repoRoot 'scripts/Maester.ViewerProjection.psm1') $TestDrive
    $moduleRoot=Join-Path $TestDrive 'maester';$null=New-Item -ItemType Directory -Path (Join-Path $moduleRoot 'assets')
    Copy-Item $env:MAESTER_VIEWER_TEMPLATE_PATH (Join-Path $moduleRoot 'assets/ReportTemplate.html')
    $env:RUNNER_TEST_MODULE_ROOT=$moduleRoot
    $env:RUNNER_TEST_TOKEN_MARKER=Join-Path $TestDrive 'viewer-token-called'
    $env:RUNNER_TEST_STORE_LOG=Join-Path $TestDrive 'viewer-store.log'
    $env:RUNNER_TEST_AZ_TENANT='11111111-1111-1111-1111-111111111111';$env:RUNNER_TEST_GRAPH_TENANT=$env:RUNNER_TEST_AZ_TENANT
    Import-Module (Join-Path $repoRoot 'scripts/Maester.ViewerContent.psm1') -Force
    . (Join-Path $PSScriptRoot 'helpers/MaesterViewerTemplateFixture.ps1')
    $templateBytes=Get-MaesterViewerTestTemplateBytes
    $env:RUNNER_TEST_RAW_REPORT=Join-Path $TestDrive 'qualified-raw.html'
    [IO.File]::WriteAllBytes($env:RUNNER_TEST_RAW_REPORT,(New-MaesterViewerRawTestReport $templateBytes '{"Name":"runner-qualified","EndOfJson":"EndOfJson"}'))
  }

  It 'exits nonzero and never creates success HTML when Invoke-Maester throws' {
    $env:RUNNER_TEST_TEMP_ROOT = Join-Path $TestDrive 'throw'
    $env:RUNNER_TEST_MODE = 'throw'
    $env:RUNNER_TEST_STORAGE = ''
    $env:RUNNER_TEST_FAIL_UPLOAD = '0'
    New-Item -ItemType Directory -Path $env:RUNNER_TEST_TEMP_ROOT | Out-Null
    $output = & pwsh -NoProfile -File $harnessPath 2>&1
    $LASTEXITCODE | Should -Be 1 -Because (@($output)-join"`n")
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
    $LASTEXITCODE | Should -Be 1 -Because (@($output)-join"`n")
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
    $LASTEXITCODE | Should -Be 0 -Because (@($output)-join"`n")
    @($output) -join "`n" | Should -Match 'RUNNER_SUCCESS'
    Get-Content -LiteralPath (Join-Path $env:RUNNER_TEST_TEMP_ROOT 'report.html') -Raw | Should -Match 'security finding'
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

  It 'rejects unqualified viewer content before token, projection, or legacy writes' {
    $env:RUNNER_TEST_TEMP_ROOT = Join-Path $TestDrive 'viewer-reject'
    $env:RUNNER_TEST_MODE = 'result';$env:RUNNER_TEST_STORAGE = 'legacy-account';$env:RUNNER_TEST_FAIL_UPLOAD = '0';$env:RUNNER_TEST_VIEWER='1'
    New-Item -ItemType Directory -Path $env:RUNNER_TEST_TEMP_ROOT | Out-Null
    $output=& pwsh -NoProfile -File $harnessPath 2>&1
    $LASTEXITCODE|Should -Be 1 -Because (@($output)-join"`n")
    Test-Path $env:RUNNER_TEST_TOKEN_MARKER|Should -BeFalse
    Test-Path (Join-Path $env:RUNNER_TEST_TEMP_ROOT 'latest-attempted')|Should -BeFalse
    @($output)-join"`n"|Should -Not -Match 'Published qualified|RUNNER_SUCCESS'
    $env:RUNNER_TEST_VIEWER='0'
  }

  It 'qualifies and publishes before preserving legacy writes when explicitly enabled' {
    $env:RUNNER_TEST_TEMP_ROOT=Join-Path $TestDrive 'viewer-success';$env:RUNNER_TEST_MODE='qualified';$env:RUNNER_TEST_STORAGE='legacy-account';$env:RUNNER_TEST_FAIL_UPLOAD='0';$env:RUNNER_TEST_VIEWER='1'
    Remove-Item $env:RUNNER_TEST_TOKEN_MARKER,$env:RUNNER_TEST_STORE_LOG -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $env:RUNNER_TEST_TEMP_ROOT|Out-Null
    $output=& pwsh -NoProfile -File $harnessPath 2>&1
    $LASTEXITCODE|Should -Be 0 -Because (@($output)-join"`n")
    Test-Path $env:RUNNER_TEST_TOKEN_MARKER|Should -BeTrue
    @(Get-Content $env:RUNNER_TEST_STORE_LOG).Count|Should -Be 7
    (Get-Content $env:RUNNER_TEST_STORE_LOG -Raw)|Should -Match 'qualified\s+token\s+Put runs/.+/report\.html\s+Put runs/.+/manifest\.json\s+Get latest\.json\s+Put latest\.json\s+legacy-latest'
    Test-Path (Join-Path $env:RUNNER_TEST_TEMP_ROOT 'latest-attempted')|Should -BeTrue
    @($output)-join"`n"|Should -Match 'Published qualified private viewer projection|RUNNER_SUCCESS'
    $env:RUNNER_TEST_VIEWER='0'
  }

  It 'executes the actual tenant binding block before any runner action' {
    $env:RUNNER_TEST_TEMP_ROOT=Join-Path $TestDrive 'viewer-mismatch';$env:RUNNER_TEST_MODE='qualified';$env:RUNNER_TEST_STORAGE='legacy-account';$env:RUNNER_TEST_VIEWER='1'
    $env:RUNNER_TEST_AZ_TENANT='22222222-2222-2222-2222-222222222222';$env:RUNNER_TEST_GRAPH_TENANT='11111111-1111-1111-1111-111111111111'
    Remove-Item $env:RUNNER_TEST_TOKEN_MARKER,$env:RUNNER_TEST_STORE_LOG -ErrorAction SilentlyContinue;New-Item -ItemType Directory -Path $env:RUNNER_TEST_TEMP_ROOT|Out-Null
    $output=& pwsh -NoProfile -File $harnessPath 2>&1
    $LASTEXITCODE|Should -Be 1 -Because (@($output)-join"`n")
    Test-Path (Join-Path $env:RUNNER_TEST_TEMP_ROOT 'report.html')|Should -BeFalse
    Test-Path $env:RUNNER_TEST_TOKEN_MARKER|Should -BeFalse;Test-Path $env:RUNNER_TEST_STORE_LOG|Should -BeFalse
    Test-Path (Join-Path $env:RUNNER_TEST_TEMP_ROOT 'latest-attempted')|Should -BeFalse
    $env:RUNNER_TEST_VIEWER='0';$env:RUNNER_TEST_AZ_TENANT=$env:RUNNER_TEST_GRAPH_TENANT
  }
}

Describe 'Maester runner viewer target boundary' {
  BeforeAll {
    $runnerPath=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Invoke-MaesterContainerJob.ps1'
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($runnerPath,[ref]$tokens,[ref]$errors)
    if($errors){throw 'Runner source did not parse.'}
    foreach($name in 'Get-MaesterViewerRunnerConfiguration','Assert-MaesterViewerRunnerTenantBinding'){
      $function=$ast.Find({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-eq$name},$true)
      . ([scriptblock]::Create($function.Extent.Text))
    }
  }
  It 'keeps the projection disabled when the setting is absent' {
    (Get-MaesterViewerRunnerConfiguration -Enabled $null).Enabled|Should -BeFalse
  }
  It 'rejects malformed enabled projection targets before authority is available' -ForEach @(
    @{Enabled='TRUE';TenantId='11111111-1111-1111-1111-111111111111';Environment='test';StorageAccount='vieweraccount';Container='viewer-projection'},
    @{Enabled='true';TenantId='bad';Environment='test';StorageAccount='vieweraccount';Container='viewer-projection'},
    @{Enabled='true';TenantId='11111111-1111-1111-1111-111111111111';Environment='bad env';StorageAccount='vieweraccount';Container='viewer-projection'},
    @{Enabled='true';TenantId='11111111-1111-1111-1111-111111111111';Environment='test';StorageAccount='Bad_account';Container='viewer-projection'},
    @{Enabled='true';TenantId='11111111-1111-1111-1111-111111111111';Environment='test';StorageAccount='vieweraccount';Container='x'},
    @{Enabled='true';TenantId='11111111-1111-1111-1111-111111111111';Environment='test';StorageAccount='vieweraccount';Container='bad--container'}
  ) {
    {Get-MaesterViewerRunnerConfiguration @PSItem}|Should -Throw
  }
  It 'requires both authenticated contexts to equal the configured tenant' {
    {Assert-MaesterViewerRunnerTenantBinding -ConfiguredTenantId '11111111-1111-1111-1111-111111111111' -AzTenantId '11111111-1111-1111-1111-111111111111' -GraphTenantId '22222222-2222-2222-2222-222222222222'}|Should -Throw '*tenant binding*'
    {Assert-MaesterViewerRunnerTenantBinding -ConfiguredTenantId '11111111-1111-1111-1111-111111111111' -AzTenantId '11111111-1111-1111-1111-111111111111' -GraphTenantId '11111111-1111-1111-1111-111111111111'}|Should -Not -Throw
  }
}
