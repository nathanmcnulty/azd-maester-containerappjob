Set-StrictMode -Version Latest

function New-MaesterRuntimeStaging {
  [CmdletBinding()]
  param(
    [string]$ProjectRoot = (Split-Path $PSScriptRoot -Parent),
    [switch]$IncludeACR
  )
  $ErrorActionPreference = 'Stop'
  $directory = Join-Path ([IO.Path]::GetTempPath()) ('maester-upload-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $directory | Out-Null
  try {
    $files = @('Invoke-MaesterContainerJob.ps1', 'Install-LockedModules.ps1', 'Start-MaesterContainerJob.sh', 'runtime-packages.lock.json')
    foreach ($file in $files) {
      $source = if ($file -eq 'runtime-packages.lock.json') { Join-Path $ProjectRoot $file } else { Join-Path $ProjectRoot "scripts/$file" }
      Copy-Item -LiteralPath $source -Destination (Join-Path $directory $file) -ErrorAction Stop
    }
    if (-not $IncludeACR) {
      $archive = 'powershell-7.6.6-linux-x64.tar.gz'
      $archivePath = Join-Path $directory $archive
      Invoke-WebRequest -Uri "https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/$archive" -OutFile $archivePath -ErrorAction Stop
      if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -cne 'DDBC4A2D113BBD46D283CFEDCBCD117A70CAEFD7673F41F2B4E0000BADF103BC') {
        throw 'Official PowerShell archive failed SHA-256 verification.'
      }
      $files += $archive
    }
    [pscustomobject]@{ Path = $directory; Files = $files }
  }
  catch {
    Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
    throw
  }
}

function Publish-MaesterRuntimeFiles {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$StorageAccountName,
    [Parameter(Mandatory)][string]$StorageKey,
    [string]$ProjectRoot = (Split-Path $PSScriptRoot -Parent),
    [switch]$IncludeACR
  )
  $ErrorActionPreference = 'Stop'
  $staging = New-MaesterRuntimeStaging -ProjectRoot $ProjectRoot -IncludeACR:$IncludeACR
  try {
    foreach ($file in $staging.Files) {
      & az storage file upload --account-name $StorageAccountName --account-key $StorageKey `
        --share-name scripts --source (Join-Path $staging.Path $file) --path $file --no-progress --output none
      if ($LASTEXITCODE -ne 0) { throw "Failed to upload '$file' to Azure Files share 'scripts'." }
    }
  }
  finally { Remove-Item -LiteralPath $staging.Path -Recurse -Force }
}

Export-ModuleMember -Function New-MaesterRuntimeStaging, Publish-MaesterRuntimeFiles
