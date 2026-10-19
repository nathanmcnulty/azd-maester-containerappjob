Describe 'Maintained complete runner entrypoint evidence (offline)' {
  BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    $importModuleCommand = Get-Command Import-Module -CommandType Cmdlet
    $getModuleCommand = Get-Command Get-Module -CommandType Cmdlet
    . (Join-Path $PSScriptRoot 'fixtures/AssessmentEvidence.ps1')
    $staged = Join-Path $TestDrive 'mounted'
    New-Item -ItemType Directory $staged | Out-Null
    foreach ($name in 'Invoke-MaesterContainerJob.ps1','Maester.AssessmentEvidence.psm1') { Copy-Item (Join-Path $repo "scripts/$name") $staged }
    Copy-Item (Join-Path $repo 'runtime-packages.lock.json') $staged
    $moduleRoot = Join-Path $TestDrive 'Maester'
    New-Item -ItemType Directory (Join-Path $moduleRoot 'tests/Maester/Entra') -Force | Out-Null
    Set-Content (Join-Path $moduleRoot 'tests/fixture.Tests.ps1') '# offline fixture, never executed'
    $fixtureVersions = @{}
    (Get-Content (Join-Path $staged 'runtime-packages.lock.json') -Raw | ConvertFrom-Json).packages | ForEach-Object { $fixtureVersions[$_.name]=$_.version }
    $envNames = @('TEMP','TMPDIR','STORAGE_ACCOUNT_NAME','INCLUDE_EXCHANGE','INCLUDE_TEAMS','INCLUDE_AZURE','MAIL_RECIPIENT','WEB_APP_NAME','WEB_APP_RESOURCE_GROUP_NAME','CONTAINER_APP_JOB_EXECUTION_NAME')
    $savedEnv = @{}
    foreach ($name in $envNames) { $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name) }
    $savedFunctions = @{}
    foreach ($name in 'Connect-AzAccount','Connect-MgGraph','Get-MgContext','Get-AzAccessToken','Invoke-Maester') {
      $savedFunctions[$name] = (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue).ScriptBlock
    }
    function global:Connect-AzAccount { param([switch]$Identity) throw 'Unmocked authentication forbidden' }
    function global:Connect-MgGraph { param([switch]$Identity,[switch]$NoWelcome) throw 'Unmocked authentication forbidden' }
    function global:Get-MgContext { throw 'Unmocked Graph forbidden' }
    function global:Get-AzAccessToken { param($ResourceUrl,[switch]$AsSecureString) throw 'Unmocked token forbidden' }
    function global:Invoke-Maester { param($Path,$OutputFolder,$PesterConfiguration,[switch]$NonInteractive,[switch]$PassThru,$OutputFolderFileName,[switch]$DisableTelemetry,[switch]$SkipVersionCheck,$MailRecipient,$MailUserId) throw 'Unmocked assessment forbidden' }
  }
  BeforeEach {
    foreach ($name in $envNames) { [Environment]::SetEnvironmentVariable($name, $null) }
    $env:TEMP = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $env:TEMP | Out-Null
    $env:TMPDIR = $env:TEMP
    $env:STORAGE_ACCOUNT_NAME = 'offlinestorage'
    $env:CONTAINER_APP_JOB_EXECUTION_NAME = 'offline-execution'
    $global:ReceiptRunner = @{ Mode='good'; Uploads=[Collections.Generic.List[string]]::new(); Receipt=$null; ReceiptJson=$null; Auth=0 }
    Mock Get-Module { & $getModuleCommand -Name $Name -ListAvailable:$ListAvailable }
    Mock Get-Module {
      [pscustomobject]@{ Name=$Name; Version=[version]$fixtureVersions[([string]$Name[0])]; Path=(Join-Path $moduleRoot 'Maester.psd1') }
    } -ParameterFilter { $Name -in @('Az.Accounts','Microsoft.Graph.Authentication','Pester','Maester','DnsClient-PS') }
    Mock Import-Module {
      if ([string]$Name -cne (Join-Path $staged 'Maester.AssessmentEvidence.psm1')) { throw 'Unexpected module import' }
      & $importModuleCommand -Name $Name -Force -Global -ErrorAction Stop
    }
    Mock Import-Module {} -ParameterFilter { $Name -in @('Az.Accounts','Microsoft.Graph.Authentication','Pester','Maester','DnsClient-PS') }
    Mock Connect-AzAccount { $global:ReceiptRunner.Auth++ }
    Mock Connect-MgGraph { $global:ReceiptRunner.Auth++ }
    Mock Get-MgContext { [pscustomobject]@{ TenantId='offline-tenant' } }
    Mock Get-AzAccessToken { [pscustomobject]@{ Token=(ConvertTo-SecureString 'offline-token' -AsPlainText -Force) } }
    Mock Invoke-Maester {
      $PassThru | Should -BeTrue
      $DisableTelemetry | Should -BeTrue
      $SkipVersionCheck | Should -BeTrue
      $PesterConfiguration.TestResult.OutputFormat.Value | Should -Be 'JUnitXml'
      $report = Join-Path $OutputFolder 'assessment.html'
      $r = New-TestAssessmentResult $Path
      $r | Add-Member OutputFiles ([pscustomobject]@{ OutputHtmlFile=$report })
      if ($global:ReceiptRunner.Mode -eq 'maester-error') { $r.Tests[0].Result='Error'; $r.PassedCount=0; $r.ErrorCount=1 }
      if ($global:ReceiptRunner.Mode -ne 'no-report') { Set-Content $report '<html>private fixture</html>' }
      $errors = if ($global:ReceiptRunner.Mode -eq 'engine-error') { 1 } else { 0 }
      Set-Content $PesterConfiguration.TestResult.OutputPath.Value "<testsuites tests=`"5`" errors=`"$errors`" failures=`"1`" disabled=`"3`" />"
      $r
    }
    Mock Invoke-RestMethod {
      if ($Method -ne 'Put' -or $Uri -notlike 'https://offlinestorage.blob.core.windows.net/*') { throw 'Unexpected network request' }
      $global:ReceiptRunner.Uploads.Add($Uri)
      if ($global:ReceiptRunner.Mode -eq 'archive-failure' -and $Uri -like '*.gz') { throw 'offline archive failure' }
      if ($global:ReceiptRunner.Mode -eq 'latest-failure' -and $Uri -like '*/latest.html') { throw 'offline latest failure' }
      if ($Uri -like '*/validation-receipts/*') {
        if ($global:ReceiptRunner.Mode -eq 'receipt-failure') { throw 'offline receipt failure' }
        $global:ReceiptRunner.ReceiptJson = Get-Content -LiteralPath $InFile -Raw
        $global:ReceiptRunner.Receipt = $global:ReceiptRunner.ReceiptJson | ConvertFrom-Json -AsHashtable -DateKind String
      }
    }
  }
  AfterEach {
    foreach ($name in $envNames) { [Environment]::SetEnvironmentVariable($name,$savedEnv[$name]) }
  }
  AfterAll {
    foreach ($name in $savedFunctions.Keys) {
      Remove-Item "function:$name" -ErrorAction SilentlyContinue
      if ($savedFunctions[$name]) { Set-Item "function:global:$name" $savedFunctions[$name] }
    }
    Remove-Variable ReceiptRunner -Scope Global
  }
  It 'emits the real test-host receipt and validates an explicit production-runtime fixture' {
    $output = & (Join-Path $staged 'Invoke-MaesterContainerJob.ps1')
    $global:ReceiptRunner.Uploads.Count | Should -Be 3
    $global:ReceiptRunner.Uploads[2] | Should -Be 'https://offlinestorage.blob.core.windows.net/archive/validation-receipts/offline-execution.json'
    $r = $global:ReceiptRunner.Receipt
    $r.Assessment.Counts.FailedCount | Should -Be 1
    $r.Source.RunnerSha256 | Should -Be ((Get-FileHash (Join-Path $staged 'Invoke-MaesterContainerJob.ps1')).Hash.ToLowerInvariant())
    $r.Publication.Archive | Should -Be 'Published'
    $r.Publication.Mail | Should -Be 'Disabled'
    $r.Runtime.PowerShell | Should -BeExactly $PSVersionTable.PSVersion.ToString()
    $expected = @{ ExecutionName='offline-execution'; ExpectedSource=$r.Source; ExpectedModules=$r.Runtime.Modules; NotBefore=[datetimeoffset]::UtcNow.AddMinutes(-1); ExpectWebApp=$false }
    # Hosted repository tests may use a newer 7.6 patch than the exact production
    # image. Preserve its real emitted evidence: a different host must not pass
    # the production gate. The image/runtime jobs qualify the actual locked host.
    if ($PSVersionTable.PSVersion.ToString() -ceq '7.6.6') {
      (Assert-MaesterValidationReceipt -Json $global:ReceiptRunner.ReceiptJson @expected).Runtime.PowerShell | Should -BeExactly '7.6.6'
    } else {
      { Assert-MaesterValidationReceipt -Json $global:ReceiptRunner.ReceiptJson @expected } | Should -Throw '*validation.receiptInvalidOrMismatched*'
    }
    # Only this explicitly synthetic verification fixture supplies the reviewed
    # production version. Never rewrite the emitted/uploaded receipt or the gate.
    $productionFixture = $global:ReceiptRunner.ReceiptJson | ConvertFrom-Json -AsHashtable -DateKind String
    $productionFixture.Runtime.PowerShell = '7.6.6'
    $verified = Assert-MaesterValidationReceipt -Json ($productionFixture | ConvertTo-Json -Depth 20) @expected
    $verified.Assessment.Outcome | Should -Be 'Completed'
    $global:ReceiptRunner.Receipt.Runtime.PowerShell | Should -BeExactly $PSVersionTable.PSVersion.ToString()
    ($output -join "`n") | Should -Not -Match 'private fixture|offline-token|offline-tenant'
    Should -Invoke Invoke-Maester -Times 1 -Exactly
  }
  It 'rejects an unreviewed production PowerShell version <_>' -ForEach @('7.6.7','7.7.0') {
    $null = & (Join-Path $staged 'Invoke-MaesterContainerJob.ps1')
    $r = $global:ReceiptRunner.ReceiptJson | ConvertFrom-Json -AsHashtable -DateKind String
    $r.Runtime.PowerShell = $_
    { Assert-MaesterValidationReceipt -Json ($r | ConvertTo-Json -Depth 20) -ExecutionName 'offline-execution' -ExpectedSource $r.Source -ExpectedModules $r.Runtime.Modules -NotBefore ([datetimeoffset]::UtcNow.AddMinutes(-1)) -ExpectWebApp $false } | Should -Throw '*validation.receiptInvalidOrMismatched*'
  }
  It 'preserves upstream inline mail configuration while attesting no delivery guarantee' {
    $env:MAIL_RECIPIENT = 'recipient@example.invalid'
    $null = & (Join-Path $staged 'Invoke-MaesterContainerJob.ps1')
    $global:ReceiptRunner.Receipt.Publication.Mail | Should -Be 'UpstreamUnverified'
    Should -Invoke Invoke-Maester -Times 1 -Exactly -ParameterFilter { $MailRecipient -eq 'recipient@example.invalid' -and $MailUserId -eq $MailRecipient }
  }
  It 'rejects <_> before any report or receipt upload' -ForEach @('maester-error','engine-error','no-report') {
    $global:ReceiptRunner.Mode = $_
    { & (Join-Path $staged 'Invoke-MaesterContainerJob.ps1') } | Should -Throw '*assessment.*'
    $global:ReceiptRunner.Uploads.Count | Should -Be 0
  }
  It 'records archive failure without claiming required publication succeeded' {
    $global:ReceiptRunner.Mode = 'archive-failure'
    $null = & (Join-Path $staged 'Invoke-MaesterContainerJob.ps1')
    $global:ReceiptRunner.Receipt.Publication.Archive | Should -Be 'Failed'
    $global:ReceiptRunner.Receipt.Publication.Latest | Should -Be 'Published'
  }
  It 'terminates on <_> without a successful receipt' -ForEach @('latest-failure','receipt-failure') {
    $global:ReceiptRunner.Mode = $_
    { & (Join-Path $staged 'Invoke-MaesterContainerJob.ps1') } | Should -Throw '*offline*failure*'
    $global:ReceiptRunner.Receipt | Should -BeNullOrEmpty
  }
  It 'returns runtime-only diagnostics before execution metadata and authentication' {
    $env:CONTAINER_APP_JOB_EXECUTION_NAME = $null
    $output = & (Join-Path $staged 'Invoke-MaesterContainerJob.ps1') -ValidateRuntimeOnly
    ($output -join "`n") | Should -Match 'runtime-only'
    $global:ReceiptRunner.Auth | Should -Be 0
    $global:ReceiptRunner.Uploads.Count | Should -Be 0
    Should -Invoke Invoke-Maester -Times 0 -Exactly
  }
  It 'rejects missing or newline-suffixed execution identity before authentication' -ForEach @($null, "offline-execution`n") {
    $env:CONTAINER_APP_JOB_EXECUTION_NAME = $_
    { & (Join-Path $staged 'Invoke-MaesterContainerJob.ps1') } | Should -Throw '*executionIdentityMissing*'
    $global:ReceiptRunner.Auth | Should -Be 0
  }
}
