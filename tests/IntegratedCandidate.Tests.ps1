# Integration seams between the reviewed runtime, publisher guards and drift stack.
Describe 'Integrated validation candidate' {
  BeforeAll { $root = Split-Path $PSScriptRoot -Parent }
  It 'stages exact drift helper bytes for both production runtime modes without input packages' -ForEach @(@{ ACR = $true }, @{ ACR = $false }) {
    Import-Module (Join-Path $root 'scripts/Maester-RuntimeFiles.psm1') -Force
    Mock Save-MaesterPublicArtifact -ModuleName Maester-RuntimeFiles { param($OutFile) Set-Content $OutFile 'archive fixture' }
    Mock Get-FileHash -ModuleName Maester-RuntimeFiles {
      param($LiteralPath)
      if ($LiteralPath -like '*.tar.gz') { return @{ Hash = 'DDBC4A2D113BBD46D283CFEDCBCD117A70CAEFD7673F41F2B4E0000BADF103BC' } }
      $lockPath = Join-Path (Split-Path (Split-Path $LiteralPath -Parent) -Parent) 'runtime-packages.lock.json'
      $lock = Get-Content $lockPath -Raw | ConvertFrom-Json
      $entry = @($lock.packages | Where-Object { "$($_.name).$($_.version).nupkg" -ceq (Split-Path $LiteralPath -Leaf) })
      if ($entry.Count -ne 1) { throw 'Unexpected package fixture.' }
      @{ Hash = $entry[0].sha256 }
    }
    $staging = New-MaesterRuntimeStaging -ProjectRoot $root -IncludeACR:$ACR
    try {
      $expected = @('Invoke-MaesterContainerJob.ps1', 'Maester.AssessmentEvidence.psm1', 'Maester.DriftInputs.psm1', 'Maester.DriftRun.psm1', 'Install-LockedModules.ps1', 'Start-MaesterContainerJob.sh', 'runtime-packages.lock.json')
      if (-not $ACR) {
        $expected += 'powershell-7.6.6-linux-x64.tar.gz'
        $lock = Get-Content (Join-Path $root 'runtime-packages.lock.json') -Raw | ConvertFrom-Json
        $expected += @($lock.packages | ForEach-Object { "packages/$($_.name).$($_.version).nupkg" })
      }
      ($staging.Files -join ',') | Should -BeExactly ($expected -join ',')
      ((Get-ChildItem $staging.Path -File -Recurse | ForEach-Object { [IO.Path]::GetRelativePath($staging.Path, $_.FullName).Replace('\', '/') }) | Sort-Object) -join ',' | Should -BeExactly (($expected | Sort-Object) -join ',')
      ($staging.Files -join ',') | Should -Not -Match 'tests/|benchmarks/|baseline|DriftInputs/'
      foreach ($helper in 'Maester.DriftInputs.psm1', 'Maester.DriftRun.psm1') {
        [IO.File]::ReadAllText((Join-Path $staging.Path $helper)) | Should -BeExactly ([IO.File]::ReadAllText((Join-Path $root "scripts/$helper")))
      }
    }
    finally { Remove-Item -LiteralPath $staging.Path -Recurse -Force }
    Test-Path $staging.Path | Should -BeFalse
  }
  It 'binds runtime diagnostics and manual drift arguments in one valid parameter block' {
    $errors = $null; $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/Invoke-MaesterContainerJob.ps1'), [ref]$tokens, [ref]$errors)
    $errors.Count | Should -Be 0
    $parameters = @($ast.ParamBlock.Parameters.Name.VariablePath.UserPath)
    $parameters | Should -Contain 'ValidateRuntimeOnly'
    $parameters | Should -Contain 'EnableApprovedDrift'
    @($parameters | Where-Object { $_ -like 'Drift*' }).Count | Should -Be 8
    $enable = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'EnableApprovedDrift' }
    $enable.DefaultValue | Should -BeNullOrEmpty
    $source = $ast.Extent.Text
    $source.IndexOf('The Maester runner requires PowerShell') | Should -BeLessThan $source.IndexOf("Get-Content -LiteralPath `$lockPath")
    $source.IndexOf('if ($ValidateRuntimeOnly)') | Should -BeLessThan $source.IndexOf('Connect-AzAccount -Identity')
  }
  It 'fails closed instead of obtaining missing modules from Gallery during assessment' {
    $source = Get-Content (Join-Path $root 'scripts/Invoke-MaesterContainerJob.ps1') -Raw
    $source | Should -Match 'Required locked modules are missing from the immutable runtime'
    $source | Should -Not -Match '& \$installerPath|Install-Module|Save-Module'
  }
  It 'leaves scheduled infrastructure and bootstrap without drift opt-in' {
    Get-Content (Join-Path $root 'infra/main.bicep') -Raw | Should -Not -Match 'EnableApprovedDrift|DriftInputRoot'
    Get-Content (Join-Path $root 'scripts/Start-MaesterContainerJob.sh') -Raw | Should -Not -Match 'EnableApprovedDrift|DriftInputRoot'
  }
}
