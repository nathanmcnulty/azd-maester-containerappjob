BeforeAll {
  $runner=Join-Path $PSScriptRoot '../scripts/Invoke-MaesterContainerJob.ps1'
  $tokens=$null;$parseErrors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$parseErrors)
  $definitions=foreach($name in @('Initialize-MaesterAssessmentTests','Repair-MaesterWhatIfDiscovery')) {
    $ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true).Extent.Text
  }
  $source=Get-Content $runner -Raw
  $start=$source.IndexOf('# BEGIN What-If test preparation');$end=$source.IndexOf('# END What-If test preparation',$start)
  if($parseErrors.Count -or $start -lt 0 -or $end -le $start){throw 'Actual production preparation source missing'}
  $script:preparation=$source.Substring($start,$end-$start)
  $script:definitionText=$definitions -join "`n`n"
  function Invoke-ActualPreparation {
    param([string]$Mode='ordinary',[switch]$Changed,[switch]$ReadOnly)
    $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $source=Join-Path $root 'module/maester-tests';$target=Join-Path $source 'Maester/Entra/Test-ConditionalAccessWhatIf.Tests.ps1'
    $out=Join-Path $root 'output';New-Item -ItemType Directory (Split-Path $target -Parent),$out -Force|Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'fixtures/maester-230/WhatIfDiscovery.ps1') $target
    if($Changed){Add-Content $target '# unknown upstream'}
    if($ReadOnly){(Get-Item $target).IsReadOnly=$true}
    $hash=(Get-FileHash $target).Hash
    $bootstrap=@'
param($testsPath,$tempRoot,$Mode)
$ErrorActionPreference='Continue'
$EnableApprovedDrift=$Mode -ceq 'drift'
'@
    $path=Join-Path $root 'prepare.ps1'
    [IO.File]::WriteAllText($path,($bootstrap+"`n"+$script:definitionText+"`n"+$script:preparation+"`nWrite-Output 'PREPARATION_COMPLETED'`n"),[Text.UTF8Encoding]::new($false))
    $output=& (Get-Process -Id $PID).Path -NoProfile -File $path $source $out $Mode 2>&1
    [pscustomobject]@{exitCode=$LASTEXITCODE;output=($output -join "`n");source=$target;originalHash=$hash;destination=(Join-Path $out 'maester-tests/Maester/Entra/Test-ConditionalAccessWhatIf.Tests.ps1')}
  }
}
Describe 'Container production test preparation under a Continue caller' {
  It 'prepares a private ordinary-assessment copy and preserves read-only installed bytes' {
    $r=Invoke-ActualPreparation -ReadOnly
    $r.exitCode|Should -Be 0
    $r.output|Should -Match 'PREPARATION_COMPLETED'
    $r.output|Should -Match 'MAESTER_TEST_COMPATIBILITY_V1:'
    (Get-FileHash $r.source).Hash|Should -BeExactly $r.originalHash
    (Get-Item $r.source).IsReadOnly|Should -BeTrue
    (Get-FileHash $r.destination).Hash|Should -BeExactly '957AC886DF9FFFBEB75BA5F27CE0735057142F8BEDEA383D80FFE4858D138939'
  }
  It 'stops an unknown ordinary suite before continuing into assessment work' {
    $r=Invoke-ActualPreparation -Changed
    $r.exitCode|Should -Be 1
    $r.output|Should -Match 'assessment.whatIfSourceUnrecognized'
    $r.output|Should -Not -Match 'PREPARATION_COMPLETED|MAESTER_TEST_COMPATIBILITY_V1:'
    (Get-FileHash $r.source).Hash|Should -BeExactly $r.originalHash
  }
  It 'does not prepare or repair the unused ordinary suite during approved drift' {
    $r=Invoke-ActualPreparation -Mode drift -Changed
    $r.exitCode|Should -Be 0
    $r.output|Should -Match 'PREPARATION_COMPLETED'
    $r.output|Should -Not -Match 'MAESTER_TEST_COMPATIBILITY_V1:'
    Test-Path $r.destination|Should -BeFalse
    (Get-FileHash $r.source).Hash|Should -BeExactly $r.originalHash
  }
}
