Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'vendor/Azd.MaesterHooks/Maester-SetupHelpers.psm1')

function Save-MaesterPublicArtifact {
  param([Parameter(Mandatory)][uri]$Uri, [Parameter(Mandatory)][string]$OutFile)
  if ($Uri.Scheme -cne 'https' -or $Uri.Host -notin @('github.com', 'www.powershellgallery.com')) { throw 'Unexpected public artifact source.' }
  $handler = [Net.Http.HttpClientHandler]::new()
  $handler.MaxAutomaticRedirections = 5
  $client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [TimeSpan]::FromSeconds(300)
  $response = $null; $source = $null; $target = $null
  $cts = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(300))
  try {
    $response = $client.GetAsync($Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token).GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode -or $response.RequestMessage.RequestUri.Scheme -cne 'https' -or $response.Content.Headers.ContentLength -gt 268435456) { throw 'Public artifact acquisition failed.' }
    $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $target = [IO.File]::Open($OutFile, [IO.FileMode]::CreateNew)
    $buffer = [byte[]]::new(65536); $total = 0L
    while (($count = $source.ReadAsync($buffer, 0, $buffer.Length, $cts.Token).GetAwaiter().GetResult()) -gt 0) {
      $total += $count
      if ($total -gt 268435456) { throw 'Public artifact exceeds the 256 MiB acquisition limit.' }
      $target.Write($buffer, 0, $count)
    }
  } finally { if ($target) { $target.Dispose() }; if ($source) { $source.Dispose() }; if ($response) { $response.Dispose() }; $cts.Dispose(); $client.Dispose(); $handler.Dispose() }
}

function New-MaesterRuntimeStaging {
  [CmdletBinding()]
  param([string]$ProjectRoot = (Split-Path $PSScriptRoot -Parent), [switch]$IncludeACR, [string]$PackageDirectory, [string]$PowerShellArchive)
  $ErrorActionPreference = 'Stop'
  $directory = Join-Path ([IO.Path]::GetTempPath()) ('maester-upload-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $directory | Out-Null
  try {
    $files = @('Invoke-MaesterContainerJob.ps1', 'Maester.AssessmentEvidence.psm1', 'Maester.DriftInputs.psm1', 'Maester.DriftRun.psm1', 'Install-LockedModules.ps1', 'Start-MaesterContainerJob.sh', 'runtime-packages.lock.json')
    foreach ($file in $files) {
      $source = if ($file -eq 'runtime-packages.lock.json') { Join-Path $ProjectRoot $file } else { Join-Path $ProjectRoot "scripts/$file" }
      Copy-Item -LiteralPath $source -Destination (Join-Path $directory $file)
    }
    if (-not $IncludeACR) {
      $archive = 'powershell-7.6.6-linux-x64.tar.gz'
      $archivePath = Join-Path $directory $archive
      if ($PowerShellArchive) { Copy-Item -LiteralPath $PowerShellArchive -Destination $archivePath }
      else { Save-MaesterPublicArtifact -Uri "https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/$archive" -OutFile $archivePath }
      if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -cne 'DDBC4A2D113BBD46D283CFEDCBCD117A70CAEFD7673F41F2B4E0000BADF103BC') { throw 'Official PowerShell archive failed SHA-256 verification.' }
      $files += $archive
      $stagingSize = (Get-Item -LiteralPath $archivePath).Length
      New-Item -ItemType Directory -Path (Join-Path $directory 'packages') | Out-Null
      $lock = Get-Content (Join-Path $directory 'runtime-packages.lock.json') -Raw | ConvertFrom-Json
      if ($lock.schemaVersion -ne 1 -or @($lock.packages).Count -eq 0) { throw 'Invalid runtime lock.' }
      foreach ($package in $lock.packages) {
        if ($package.name -cnotmatch '^[A-Za-z][A-Za-z0-9.-]*$' -or $package.version -cnotmatch '^\d+(\.\d+){1,3}$' -or $package.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid runtime package identity.' }
        $leaf = "$($package.name).$($package.version).nupkg"
        $path = Join-Path $directory "packages/$leaf"
        if ($PackageDirectory) { Copy-Item -LiteralPath (Join-Path $PackageDirectory $leaf) -Destination $path }
        else { Save-MaesterPublicArtifact -Uri "https://www.powershellgallery.com/api/v2/package/$($package.name)/$($package.version)" -OutFile $path }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $package.sha256) { throw "Locked package '$leaf' failed SHA-256 verification." }
        $stagingSize += (Get-Item -LiteralPath $path).Length
        if ($stagingSize -gt 536870912) { throw 'Runtime inputs exceed the 512 MiB bundle limit.' }
        $files += "packages/$leaf"
      }
    }
    [pscustomobject]@{ Path = $directory; Files = $files }
  } catch { Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue; throw }
}

function New-MaesterRuntimeBundle {
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Staging)
  $path = Join-Path $Staging.Path 'runtime.zip'
  $zip = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($file in @($Staging.Files | Sort-Object -CaseSensitive)) {
      $entry = $zip.CreateEntry($file, [IO.Compression.CompressionLevel]::NoCompression)
      $entry.LastWriteTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
      $inputStream = [IO.File]::OpenRead((Join-Path $Staging.Path $file)); $outputStream = $entry.Open()
      try { $inputStream.CopyTo($outputStream) } finally { $inputStream.Dispose(); $outputStream.Dispose() }
    }
  } finally { $zip.Dispose() }
  $size = (Get-Item -LiteralPath $path).Length
  if ($size -le 0 -or $size -gt 536870912) { throw 'Runtime bundle exceeds the 512 MiB limit.' }
  $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
  [pscustomobject]@{ Path = $path; Sha256 = $hash; Size = $size; BlobName = "bundles/$hash.zip" }
}

function Get-MaesterPublisherToken {
  param([string]$SubscriptionId, [string]$TenantId, [string]$OperatorObjectId, [string]$Resource = 'https://storage.azure.com/')
  $null = Get-AzCliSubscriptionContext -SubscriptionId $SubscriptionId -TenantId $TenantId
  $token = (& az account get-access-token --subscription $SubscriptionId --tenant $TenantId --resource $Resource --query accessToken --output tsv --only-show-errors 2>$null) -join ''
  try {
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) { throw 'Token unavailable.' }
    $parts = $token.Split('.')
    if ($parts.Length -ne 3) { throw 'Invalid token.' }
    $encoded = $parts[1].Replace('-', '+').Replace('_', '/')
    $encoded = $encoded.PadRight($encoded.Length + ((4 - $encoded.Length % 4) % 4), '=')
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
    # The CLI acquired the token from Entra; decoding here binds its identity and
    # audience, it is not a replacement for service-side signature validation.
    if ($claims.tid -ine $TenantId -or $claims.oid -ine $OperatorObjectId -or
        ([string]$claims.aud).TrimEnd('/') -ine $Resource.TrimEnd('/') -or
        [long]$claims.exp -lt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 300) { throw 'Unexpected token identity or audience.' }
    return $token
  } catch { throw 'Cannot acquire an unexpired Entra token for the approved publishing operator and tenant.' }
}

function Invoke-MaesterBlobRequest {
  param([Parameter(Mandatory)][ValidateSet('PUT','GET')][string]$Method, [Parameter(Mandatory)][uri]$Uri,
    [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)]$Bundle)
  $handler = [Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect = $false
  $client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [TimeSpan]::FromMinutes(5)
  $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $Uri)
  $response = $null; $source = $null
  try {
    $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
    $null = $request.Headers.TryAddWithoutValidation('x-ms-version', '2023-11-03')
    $null = $request.Headers.TryAddWithoutValidation('x-ms-date', [DateTime]::UtcNow.ToString('R'))
    if ($Method -eq 'PUT') {
      $null = $request.Headers.TryAddWithoutValidation('If-None-Match', '*')
      $null = $request.Headers.TryAddWithoutValidation('x-ms-blob-type', 'BlockBlob')
      $source = [IO.File]::OpenRead($Bundle.Path)
      $request.Content = [Net.Http.StreamContent]::new($source)
      $request.Content.Headers.ContentLength = $Bundle.Size
    }
    $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    $status = [int]$response.StatusCode
    if ($Method -eq 'GET' -and $status -eq 200) {
      if ($response.Content.Headers.ContentLength -ne $Bundle.Size) { throw 'Unexpected bundle length.' }
      $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
      $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
      $cts = [Threading.CancellationTokenSource]::new([TimeSpan]::FromMinutes(5))
      try {
        $buffer = [byte[]]::new(65536); $total = 0L
        while (($count = $stream.ReadAsync($buffer, 0, $buffer.Length, $cts.Token).GetAwaiter().GetResult()) -gt 0) {
          $total += $count
          if ($total -gt $Bundle.Size) { throw 'Oversized bundle.' }
          $hash.AppendData($buffer, 0, $count)
        }
        $actual = [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
        if ($total -ne $Bundle.Size -or $actual -cne $Bundle.Sha256) { throw 'Bundle readback mismatch.' }
      } finally { $stream.Dispose(); $hash.Dispose(); $cts.Dispose() }
    }
    return $status
  } catch { throw 'Runtime Blob transfer or verified readback failed; no credentials or response body are logged.' }
  finally { if ($response) { $response.Dispose() }; $request.Dispose(); if ($source) { $source.Dispose() }; $client.Dispose(); $handler.Dispose() }
}

function Publish-MaesterRuntimeFiles {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][guid]$SubscriptionId, [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][ValidatePattern('^[\p{L}\p{N}_().-]{1,90}(?<!\.)$')][string]$ResourceGroupName,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]{3,24}$')][string]$StorageAccountName,
    [Parameter(Mandatory)][guid]$OperatorObjectId,
    [string]$ProjectRoot = (Split-Path $PSScriptRoot -Parent), [string]$PackageDirectory, [string]$PowerShellArchive
  )
  $ErrorActionPreference = 'Stop'
  $null = Get-AzCliSubscriptionContext -SubscriptionId $SubscriptionId -TenantId $TenantId
  $storageId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$StorageAccountName"
  $storageJson = & az storage account show --subscription $SubscriptionId --resource-group $ResourceGroupName --name $StorageAccountName --output json 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($storageJson)) { throw 'Unable to verify the selected storage account.' }
  try { $storage = $storageJson | ConvertFrom-Json -AsHashtable } catch { throw 'Invalid storage account ARM metadata.' }
  if ($storage.id -ine $storageId -or $storage.name -ine $StorageAccountName -or $storage.type -ine 'Microsoft.Storage/storageAccounts' -or $storage.resourceGroup -ine $ResourceGroupName -or $storage.allowSharedKeyAccess -ne $false) { throw 'Storage identity or Shared Key policy does not match the approved keyless target.' }
  $staging = New-MaesterRuntimeStaging -ProjectRoot $ProjectRoot -PackageDirectory $PackageDirectory -PowerShellArchive $PowerShellArchive
  try {
    $bundle = New-MaesterRuntimeBundle -Staging $staging
    $uri = [uri]"https://$StorageAccountName.blob.core.windows.net/runtime/$($bundle.BlobName)"
    # At most six 10-second retry delays; transfers are bounded separately. Never use keys or SAS.
    for ($attempt = 0; $attempt -lt 7; $attempt++) {
      $token = Get-MaesterPublisherToken -SubscriptionId $SubscriptionId -TenantId $TenantId -OperatorObjectId $OperatorObjectId
      $status = Invoke-MaesterBlobRequest -Method PUT -Uri $uri -Token $token -Bundle $bundle
      if ($status -in @(201, 409, 412)) { break }
      if ($status -notin @(403, 429, 500, 503) -or $attempt -eq 6) { throw "Runtime bundle publication failed (HTTP $status)." }
      Start-Sleep -Seconds 10
    }
    # Existing content-addressed blobs are accepted ONLY after byte-for-byte hash
    # and size verification. A conflict is never overwritten.
    $status = Invoke-MaesterBlobRequest -Method GET -Uri $uri -Token $token -Bundle $bundle
    if ($status -ne 200) { throw "Runtime bundle readback failed (HTTP $status)." }
    [pscustomobject]@{ StorageAccountName = $StorageAccountName; BlobName = $bundle.BlobName; Sha256 = $bundle.Sha256; Size = $bundle.Size }
  } finally { $token = $null; Remove-Item -LiteralPath $staging.Path -Recurse -Force }
}

function Set-MaesterRuntimeBundlePin {
  [CmdletBinding()]
  param([Parameter(Mandatory)][guid]$SubscriptionId, [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][guid]$OperatorObjectId, [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]*$')][string]$JobName,
    [Parameter(Mandatory)][guid]$RuntimePrincipalId, [Parameter(Mandatory)]$Bundle)
  $ErrorActionPreference = 'Stop'
  if ($ResourceGroupName -notmatch '^[\p{L}\p{N}_().-]{1,90}(?<!\.)$' -or
      $Bundle.StorageAccountName -cnotmatch '^[a-z0-9]{3,24}$' -or $Bundle.Sha256 -cnotmatch '^[a-f0-9]{64}$' -or
      $Bundle.BlobName -cne "bundles/$($Bundle.Sha256).zip" -or $Bundle.Size -le 0 -or $Bundle.Size -gt 536870912) { throw 'Invalid runtime pin target.' }
  $token = Get-MaesterPublisherToken -SubscriptionId $SubscriptionId -TenantId $TenantId -OperatorObjectId $OperatorObjectId -Resource 'https://management.azure.com/'
  $headers = @{ Authorization = "Bearer $token" }
  $id = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.App/jobs/$JobName"
  $uri = "https://management.azure.com${id}?api-version=2024-03-01"
  try {
    $job = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -MaximumRedirection 0 -ConnectionTimeoutSeconds 120 -OperationTimeoutSeconds 120
    if ($job.id -ine $id -or $job.identity.principalId -ine $RuntimePrincipalId -or @($job.properties.template.containers).Count -ne 1 -or $job.properties.template.containers[0].name -cne 'maester') { throw 'Job target changed.' }
    $beforeTemplate = $job.properties.template | ConvertTo-Json -Depth 50 -Compress
    $values = @{
      MAESTER_RUNTIME_STORAGE_ACCOUNT = $Bundle.StorageAccountName
      MAESTER_RUNTIME_BLOB_NAME = $Bundle.BlobName
      MAESTER_RUNTIME_SHA256 = $Bundle.Sha256
      MAESTER_RUNTIME_SIZE = [string]$Bundle.Size
    }
    $container = $job.properties.template.containers[0]
    $container.env = @($container.env | Where-Object { $_.name -notin $values.Keys }) + @($values.Keys | Sort-Object | ForEach-Object { @{ name = $_; value = $values[$_] } })
    $body = @{ properties = @{ template = $job.properties.template } } | ConvertTo-Json -Depth 50 -Compress
    $null = Get-AzCliSubscriptionContext -SubscriptionId $SubscriptionId -TenantId $TenantId
    # Jobs 2024-03-01 has no documented ETag/CAS contract. Updates must be serialized.
    $fresh = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -MaximumRedirection 0 -ConnectionTimeoutSeconds 120 -OperationTimeoutSeconds 120
    if ($fresh.id -ine $id -or $fresh.identity.principalId -ine $RuntimePrincipalId -or ($fresh.properties.template | ConvertTo-Json -Depth 50 -Compress) -cne $beforeTemplate) { throw 'Job changed during activation.' }
    $null = Invoke-RestMethod -Method PATCH -Uri $uri -Headers $headers -Body $body -ContentType 'application/json' -MaximumRedirection 0 -ConnectionTimeoutSeconds 120 -OperationTimeoutSeconds 120
    $verified = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $token" } -MaximumRedirection 0 -ConnectionTimeoutSeconds 120 -OperationTimeoutSeconds 120
    if ($verified.id -ine $id -or $verified.identity.principalId -ine $RuntimePrincipalId -or @($verified.properties.template.containers).Count -ne 1 -or $verified.properties.template.containers[0].name -cne 'maester') { throw 'Job identity changed during activation.' }
    foreach ($name in $values.Keys) {
      $actual = @($verified.properties.template.containers[0].env | Where-Object name -CEQ $name)
      if ($actual.Count -ne 1 -or $actual[0].value -cne $values[$name]) { throw 'Pin verification failed.' }
    }
  } catch { throw 'Runtime job pin update or verification failed. Inspect the selected job before retrying; publication may already be pinned.' }
  finally { $token = $null; $headers.Clear() }
}
Export-ModuleMember -Function New-MaesterRuntimeStaging, New-MaesterRuntimeBundle, Publish-MaesterRuntimeFiles, Set-MaesterRuntimeBundlePin
