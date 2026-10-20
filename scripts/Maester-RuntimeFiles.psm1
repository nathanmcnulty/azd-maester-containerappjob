Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'vendor/Azd.MaesterHooks/Maester-SetupHelpers.psm1')

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
    $files = @('Invoke-MaesterContainerJob.ps1', 'Maester.AssessmentEvidence.psm1', 'Maester.DriftInputs.psm1', 'Maester.DriftRun.psm1', 'Install-LockedModules.ps1', 'Start-MaesterContainerJob.sh', 'runtime-packages.lock.json')
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
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TenantId,
    [Parameter(Mandatory)][ValidatePattern('^[\p{L}\p{N}_().-]{1,90}(?<!\.)$')][string]$ResourceGroupName,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]{3,24}$')][string]$StorageAccountName,
    [Parameter(Mandatory)][string]$StorageKey,
    [string]$ProjectRoot = (Split-Path $PSScriptRoot -Parent),
    [switch]$IncludeACR
  )
  $ErrorActionPreference = 'Stop'
  if ([string]::IsNullOrWhiteSpace($TenantId)) { throw 'An explicit expected TenantId is required.' }
  $context = Get-AzCliSubscriptionContext -SubscriptionId $SubscriptionId -TenantId $TenantId
  $SubscriptionId = $context.id
  $TenantId = $context.tenantId
  $storageId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$StorageAccountName"
  $storageJson = & az storage account show --subscription $SubscriptionId --resource-group $ResourceGroupName --name $StorageAccountName --output json 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($storageJson)) { throw 'Unable to verify the selected storage account.' }
  try { $storage = $storageJson | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
  catch { throw 'Invalid storage account ARM metadata.' }
  if ($storage -isnot [System.Collections.IDictionary] -or
      [string]$storage.id -ine $storageId -or
      [string]$storage.name -ine $StorageAccountName -or
      [string]$storage.type -ine 'Microsoft.Storage/storageAccounts' -or
      [string]$storage.resourceGroup -ine $ResourceGroupName) {
    throw 'Storage account ARM identity does not match the selected subscription, resource group and account.'
  }
  $staging = New-MaesterRuntimeStaging -ProjectRoot $ProjectRoot -IncludeACR:$IncludeACR
  try {
    foreach ($file in $staging.Files) {
      # Downloads can be long, and subscription state can change between files.
      Get-AzCliSubscriptionContext -SubscriptionId $SubscriptionId -TenantId $TenantId | Out-Null
      # Scope credentials to the upload child process, never its argument list.
      # An actual empty value overrides storage.connection_string in CLI config;
      # removing the variable would allow that fallback to change the account.
      $previousKey = [Environment]::GetEnvironmentVariable('AZURE_STORAGE_KEY', 'Process')
      $previousConnectionString = [Environment]::GetEnvironmentVariable('AZURE_STORAGE_CONNECTION_STRING', 'Process')
      try {
        [Environment]::SetEnvironmentVariable('AZURE_STORAGE_KEY', $StorageKey, 'Process')
        [Environment]::SetEnvironmentVariable('AZURE_STORAGE_CONNECTION_STRING', '', 'Process')
        if ([Environment]::GetEnvironmentVariable('AZURE_STORAGE_CONNECTION_STRING', 'Process') -cne '' -or
            -not [Environment]::GetEnvironmentVariables('Process').Contains('AZURE_STORAGE_CONNECTION_STRING')) {
          throw 'Unable to isolate upload credentials.'
        }
        & az storage file upload --subscription $SubscriptionId --account-name $StorageAccountName --auth-mode key `
          --share-name scripts --source (Join-Path $staging.Path $file) --path $file --no-progress --output none 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Upload exited unsuccessfully.' }
      }
      catch {
        # Do not forward native diagnostics or invocation exceptions: they may
        # contain credential material. Keep the failure scoped to this file.
        throw "Failed to upload '$file' to Azure Files share 'scripts'."
      }
      finally {
        if ($null -eq $previousKey) { Remove-Item Env:AZURE_STORAGE_KEY -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable('AZURE_STORAGE_KEY', $previousKey, 'Process') }
        if ($null -eq $previousConnectionString) { Remove-Item Env:AZURE_STORAGE_CONNECTION_STRING -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable('AZURE_STORAGE_CONNECTION_STRING', $previousConnectionString, 'Process') }
      }
    }
  }
  finally { Remove-Item -LiteralPath $staging.Path -Recurse -Force }
}

Export-ModuleMember -Function New-MaesterRuntimeStaging, Publish-MaesterRuntimeFiles
