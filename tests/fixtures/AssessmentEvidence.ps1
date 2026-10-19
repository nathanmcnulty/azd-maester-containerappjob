function New-TestAssessmentResult {
  param([string]$TestsPath)
  [pscustomobject]@{
    EndOfJson = 'EndOfJson'; CurrentVersion = [version]'2.2.0'; TotalCount = 5
    PassedCount = 1; FailedCount = 1; ErrorCount = 0; InvestigateCount = 0; SkippedCount = 1; NotRunCount = 2
    Tests = @(
      [pscustomobject]@{ Id = 'MT.1068'; Result = 'Passed'; ErrorRecord = @(); ScriptBlockFile = (Join-Path $TestsPath 'Maester/Entra/Test-MtTenantCreationRestricted.Tests.ps1') }
      [pscustomobject]@{ Id = 'MT.1069'; Result = 'Failed'; ErrorRecord = @([pscustomobject]@{ FullyQualifiedErrorId = 'PesterAssertionFailed' }); ScriptBlockFile = (Join-Path $TestsPath 'Maester/Entra/Test-MtSecurityGroupCreationRestricted.Tests.ps1') }
      [pscustomobject]@{ Id = 'optional'; Result = 'Skipped'; ErrorRecord = @([pscustomobject]@{ FullyQualifiedErrorId = 'PesterTestSkipped' }); ScriptBlockFile = '' }
      [pscustomobject]@{ Id = 'preview'; Result = 'NotRun'; ErrorRecord = @(); ScriptBlockFile = '' }
      [pscustomobject]@{ Id = 'long'; Result = 'NotRun'; ErrorRecord = @(); ScriptBlockFile = '' }
    )
  }
}
function New-TestValidationReceipt {
  param([string]$Root, [string]$ExecutionName = 'execution-one')
  $source = Get-MaesterEvidenceSource -ScriptsRoot (Join-Path $Root 'scripts') -LockPath (Join-Path $Root 'runtime-packages.lock.json')
  [ordered]@{
    SchemaVersion = 1; Kind = 'MaesterContainerAssessment'; ExecutionName = $ExecutionName
    StartedAt = [datetimeoffset]::UtcNow.ToString('o'); CompletedAt = [datetimeoffset]::UtcNow.ToString('o'); Source = $source
    Runtime = @{ PowerShell = '7.6.6'; DotNet = '10.0.9'; Edition = 'Core'; OS = 'Linux'; Architecture = 'X64'; Modules = @{ 'Az.Accounts' = '5.5.3'; 'Microsoft.Graph.Authentication' = '2.41.0'; Pester = '6.2.0'; Maester = '2.2.0'; 'DnsClient-PS' = '1.2.1' } }
    Assessment = @{ Outcome = 'Completed'; Counts = @{ TotalCount = 5; PassedCount = 1; FailedCount = 1; ErrorCount = 0; InvestigateCount = 0; SkippedCount = 1; NotRunCount = 2 }; CoreCases = @{ 'MT.1068' = 'Passed'; 'MT.1069' = 'Failed' }; JunitErrors = 0; JunitTests = 5; ReportSha256 = 'a' * 64; JunitSha256 = 'b' * 64 }
    Publication = @{ Archive = 'Published'; Latest = 'Published'; WebApp = 'Disabled'; Mail = 'Disabled' }
  }
}
