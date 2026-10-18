BeforeAll {
  $repoRoot = Split-Path $PSScriptRoot -Parent
  Import-Module (Join-Path $repoRoot 'scripts/Maester-RuntimeFiles.psm1') -Force
  function global:az { throw 'Azure must be mocked in these tests.' }
}
AfterAll { Remove-Item Function:\az -ErrorAction SilentlyContinue }

Describe 'Production runtime staging and uploads' {
  BeforeEach {
    $script:before = @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'maester-upload-*' | Select-Object -ExpandProperty FullName)
    $script:sourceHash = (Get-FileHash (Join-Path $repoRoot 'runtime-packages.lock.json')).Hash
  }
  AfterEach {
    @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'maester-upload-*' | Select-Object -ExpandProperty FullName | Where-Object { $_ -notin $script:before }).Count | Should -Be 0
    (Get-FileHash (Join-Path $repoRoot 'runtime-packages.lock.json')).Hash | Should -Be $script:sourceHash
  }

  It 'uploads every production non-ACR input and removes only owned staging' {
    Mock Invoke-WebRequest -ModuleName Maester-RuntimeFiles { param($Uri, $OutFile) Set-Content -LiteralPath $OutFile -Value 'download fixture' }
    Mock Get-FileHash -ModuleName Maester-RuntimeFiles { @{ Hash = 'DDBC4A2D113BBD46D283CFEDCBCD117A70CAEFD7673F41F2B4E0000BADF103BC' } }
    Mock az -ModuleName Maester-RuntimeFiles { $global:LASTEXITCODE = 0 }
    Publish-MaesterRuntimeFiles -StorageAccountName test -StorageKey fixture -ProjectRoot $repoRoot
    Should -Invoke az -ModuleName Maester-RuntimeFiles -Times 5 -Exactly
    foreach ($file in @('Invoke-MaesterContainerJob.ps1', 'Install-LockedModules.ps1', 'Start-MaesterContainerJob.sh', 'runtime-packages.lock.json', 'powershell-7.6.6-linux-x64.tar.gz')) {
      Should -Invoke az -ModuleName Maester-RuntimeFiles -Times 1 -Exactly -ParameterFilter { $args -contains $file }
    }
    Should -Invoke Invoke-WebRequest -ModuleName Maester-RuntimeFiles -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/powershell-7.6.6-linux-x64.tar.gz' }
  }

  It 'does not download or upload a runtime archive for ACR' {
    Mock Invoke-WebRequest -ModuleName Maester-RuntimeFiles { throw 'ACR must not download.' }
    Mock az -ModuleName Maester-RuntimeFiles { $global:LASTEXITCODE = 0 }
    Publish-MaesterRuntimeFiles -StorageAccountName test -StorageKey fixture -ProjectRoot $repoRoot -IncludeACR
    Should -Invoke az -ModuleName Maester-RuntimeFiles -Times 4 -Exactly
    Should -Invoke Invoke-WebRequest -ModuleName Maester-RuntimeFiles -Times 0 -Exactly
  }

  It 'rejects download failure before any upload and cleans temporary data' {
    Mock Invoke-WebRequest -ModuleName Maester-RuntimeFiles { param($OutFile) Set-Content $OutFile partial; throw 'download failed' }
    Mock az -ModuleName Maester-RuntimeFiles { throw 'Must not upload.' }
    { Publish-MaesterRuntimeFiles -StorageAccountName test -StorageKey fixture -ProjectRoot $repoRoot } | Should -Throw '*download failed*'
    Should -Invoke az -ModuleName Maester-RuntimeFiles -Times 0 -Exactly
  }

  It 'rejects actual wrong archive bytes before any upload' {
    Mock Invoke-WebRequest -ModuleName Maester-RuntimeFiles { param($OutFile) Set-Content $OutFile corrupt }
    Mock az -ModuleName Maester-RuntimeFiles { throw 'Must not upload.' }
    { Publish-MaesterRuntimeFiles -StorageAccountName test -StorageKey fixture -ProjectRoot $repoRoot } | Should -Throw '*SHA-256*'
    Should -Invoke az -ModuleName Maester-RuntimeFiles -Times 0 -Exactly
  }

  It 'fails closed on an upload failure and cleans its staged copies' {
    Mock az -ModuleName Maester-RuntimeFiles { $global:LASTEXITCODE = 7 }
    { Publish-MaesterRuntimeFiles -StorageAccountName test -StorageKey fixture -ProjectRoot $repoRoot -IncludeACR } | Should -Throw '*Failed to upload*'
    Should -Invoke az -ModuleName Maester-RuntimeFiles -Times 1 -Exactly
  }

  It 'uses the real publisher in setup and the shell entry point in Bicep' {
    $setup = Get-Content (Join-Path $repoRoot 'scripts/Setup-PostDeploy.ps1') -Raw
    $setup | Should -Match 'Publish-MaesterRuntimeFiles -StorageAccountName.*-IncludeACR:\$includeACR'
    $infra = Get-Content (Join-Path $repoRoot 'infra/main.bicep') -Raw
    $infra | Should -Match "'/bin/sh'\s+'/mnt/scripts/Start-MaesterContainerJob.sh'\s+includeACR \? 'acr' : 'nonacr'"
    $docker = Get-Content (Join-Path $repoRoot 'Dockerfile') -Raw
    $bootstrap = Get-Content (Join-Path $repoRoot 'scripts/Start-MaesterContainerJob.sh') -Raw
    $staging = Get-Content (Join-Path $repoRoot 'scripts/Maester-RuntimeFiles.psm1') -Raw
    $hash = [regex]::Match($docker, '[A-F0-9]{64}').Value
    $hash | Should -Not -BeNullOrEmpty
    $bootstrap | Should -Match $hash
    $staging | Should -Match $hash
    $infra | Should -Match ([regex]::Escape(([regex]::Match($docker, 'mcr.microsoft.com/[^\s]+')).Value))
  }
}
