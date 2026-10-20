# This script runs only in the pinned bootstrap interpreter. It never loads Az.
[CmdletBinding()]
param([string]$Destination = $env:MAESTER_RUNTIME_DESTINATION)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Copy-MaesterBoundedStream {
  param([IO.Stream]$Source, [IO.Stream]$Target, [long]$Limit)
  $buffer = [byte[]]::new(65536)
  [long]$total = 0
  $deadline = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(120))
  try {
    while (($count = $Source.ReadAsync($buffer, 0, $buffer.Length, $deadline.Token).GetAwaiter().GetResult()) -gt 0) {
      $total += $count
      if ($total -gt $Limit) { throw 'Runtime content exceeds its size limit.' }
      $Target.Write($buffer, 0, $count)
    }
  } finally { $deadline.Dispose() }
  return $total
}

function Expand-MaesterRuntimeBundle {
  param([Parameter(Mandatory)][string]$ArchivePath, [Parameter(Mandatory)][string]$Destination)
  # Call only after the whole archive has matched the externally pinned digest.
  $zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
  try {
    $rootFiles = @('Invoke-MaesterContainerJob.ps1', 'Maester.AssessmentEvidence.psm1', 'Maester.DriftInputs.psm1', 'Maester.DriftRun.psm1', 'Install-LockedModules.ps1', 'Start-MaesterContainerJob.sh', 'runtime-packages.lock.json', 'powershell-7.6.6-linux-x64.tar.gz')
    $lockEntries = @($zip.Entries | Where-Object { $_.FullName -ceq 'runtime-packages.lock.json' })
    if ($lockEntries.Count -ne 1 -or $lockEntries[0].Length -gt 65536) { throw 'Invalid runtime lock entry.' }
    $lockStream = $lockEntries[0].Open(); $lockMemory = [IO.MemoryStream]::new()
    try {
      $null = Copy-MaesterBoundedStream -Source $lockStream -Target $lockMemory -Limit 65536
      $lock = [Text.Encoding]::UTF8.GetString($lockMemory.ToArray()) | ConvertFrom-Json
    } finally { $lockStream.Dispose(); $lockMemory.Dispose() }
    if ($lock.schemaVersion -ne 1 -or @($lock.packages).Count -lt 1 -or @($lock.packages).Count -gt 50) { throw 'Invalid runtime package lock.' }
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $rootFiles) { $null = $allowed.Add($name) }
    foreach ($package in $lock.packages) {
      if ($package.name -cnotmatch '^[A-Za-z][A-Za-z0-9.-]*\z' -or $package.version -cnotmatch '^\d+(\.\d+){1,3}\z' -or $package.sha256 -cnotmatch '^[a-fA-F0-9]{64}\z') { throw 'Invalid runtime package lock.' }
      if (-not $allowed.Add("packages/$($package.name).$($package.version).nupkg")) { throw 'Duplicate runtime package.' }
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [long]$expandedSize = 0
    foreach ($entry in $zip.Entries) {
      # ZIP entries must be exact regular filenames, never links or directories.
      $fileType = ($entry.ExternalAttributes -shr 16) -band 0xF000
      if (-not $allowed.Contains($entry.FullName) -or -not $seen.Add($entry.FullName) -or
          ($fileType -ne 0 -and $fileType -ne 0x8000) -or ($entry.ExternalAttributes -band 0x10) -ne 0) { throw 'Unsafe runtime archive entry.' }
      $expandedSize += $entry.Length
      if ($entry.Length -lt 0 -or $expandedSize -gt 1073741824) { throw 'Runtime archive is too large.' }
    }
    if ($seen.Count -ne $allowed.Count) { throw 'Runtime archive is incomplete.' }
    $null = [IO.Directory]::CreateDirectory((Join-Path $Destination 'packages'))
    foreach ($entry in $zip.Entries) {
      $inputStream = $entry.Open()
      $outputStream = [IO.File]::Open((Join-Path $Destination $entry.FullName), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
      try {
        $length = Copy-MaesterBoundedStream -Source $inputStream -Target $outputStream -Limit $entry.Length
        if ($length -ne $entry.Length) { throw 'Truncated runtime archive entry.' }
      } finally { $inputStream.Dispose(); $outputStream.Dispose() }
    }
  } finally { $zip.Dispose() }
}

function New-MaesterRuntimeHttpClient {
  $handler = [Net.Http.HttpClientHandler]::new()
  $handler.AllowAutoRedirect = $false
  $handler.UseProxy = $false
  $client = [Net.Http.HttpClient]::new($handler)
  $client.Timeout = [TimeSpan]::FromSeconds(120)
  return $client
}

function Get-MaesterRuntimeBundle {
  param([Parameter(Mandatory)][string]$Destination)
  $account = $env:MAESTER_RUNTIME_STORAGE_ACCOUNT
  $digest = $env:MAESTER_RUNTIME_SHA256
  $blob = $env:MAESTER_RUNTIME_BLOB_NAME
  [long]$size = 0
  if ($account -cnotmatch '^[a-z0-9]{3,24}\z' -or $digest -cnotmatch '^[a-f0-9]{64}\z' -or
      $blob -cne "bundles/$digest.zip" -or -not [long]::TryParse($env:MAESTER_RUNTIME_SIZE, [ref]$size) -or
      $size -lt 1 -or $size -gt 536870912) { throw 'Missing or invalid pinned runtime bundle configuration.' }
  if (-not [IO.Path]::IsPathFullyQualified($Destination) -or -not [IO.Directory]::Exists($Destination) -or
      [IO.Directory]::EnumerateFileSystemEntries($Destination).GetEnumerator().MoveNext() -or
      ([IO.File]::GetAttributes($Destination) -band [IO.FileAttributes]::ReparsePoint)) { throw 'Runtime destination must be an empty owned directory.' }
  $endpoint = $null
  if (-not [Uri]::TryCreate($env:IDENTITY_ENDPOINT, [UriKind]::Absolute, [ref]$endpoint) -or
      $endpoint.Scheme -cne 'http' -or $endpoint.UserInfo -or $endpoint.Query -or $endpoint.Fragment -or
      $endpoint.AbsolutePath -cne '/msi/token' -or
      ($endpoint.Host -cne 'localhost' -and $endpoint.Host -cne '127.0.0.1' -and $endpoint.Host -cne '[::1]' -and $endpoint.Host -cne '169.254.255.2') -or
      [string]::IsNullOrWhiteSpace($env:IDENTITY_HEADER)) { throw 'Invalid Container Apps managed identity endpoint.' }
  $client = New-MaesterRuntimeHttpClient
  $archive = Join-Path $Destination '.runtime.zip'
  $token = $null
  try {
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, "$($endpoint.AbsoluteUri)?api-version=2019-08-01&resource=https%3A%2F%2Fstorage.azure.com%2F")
    $null = $request.Headers.TryAddWithoutValidation('X-IDENTITY-HEADER', $env:IDENTITY_HEADER)
    try {
      $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
      try {
        if (-not $response.IsSuccessStatusCode) { throw 'Managed identity token request failed.' }
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $memory = [IO.MemoryStream]::new()
        try {
          $null = Copy-MaesterBoundedStream -Source $stream -Target $memory -Limit 65536
          $payload = [Text.Encoding]::UTF8.GetString($memory.ToArray()) | ConvertFrom-Json
          $token = [string]$payload.access_token
          if ([string]::IsNullOrWhiteSpace($token) -or $token.Length -gt 32768 -or $token -match '[\r\n]') { throw 'Invalid managed identity token response.' }
        } finally { $stream.Dispose(); $memory.Dispose() }
      } finally { $response.Dispose() }
    } finally { $request.Dispose() }
    $uri = "https://$account.blob.core.windows.net/runtime/$blob"
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
      $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $uri)
      $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
      $null = $request.Headers.TryAddWithoutValidation('x-ms-version', '2023-11-03')
      try {
        $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        try {
          $status = [int]$response.StatusCode
          if ($status -in @(403,404,429,500,502,503,504) -and $attempt -lt 5) { Start-Sleep -Seconds 5; continue }
          if ($status -ne 200) { throw 'Private runtime bundle request failed.' }
          if ($null -ne $response.Content.Headers.ContentLength -and $response.Content.Headers.ContentLength -ne $size) { throw 'Runtime bundle length does not match its pin.' }
          $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
          $outputStream = [IO.File]::Open($archive, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
          try {
            $length = Copy-MaesterBoundedStream -Source $stream -Target $outputStream -Limit $size
            if ($length -ne $size) { throw 'Runtime bundle is truncated.' }
          } finally { $stream.Dispose(); $outputStream.Dispose() }
        } finally { $response.Dispose() }
      } finally { $request.Dispose() }
      break
    }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $digest) { throw 'Runtime bundle digest does not match its pin.' }
    Expand-MaesterRuntimeBundle -ArchivePath $archive -Destination $Destination
    Remove-Item -LiteralPath $archive -Force
  } catch {
    # Suppress request exceptions, token response bodies and nested diagnostics.
    throw 'Unable to retrieve and verify the pinned private runtime bundle.'
  } finally { $token = $null; $client.Dispose() }
}

if ($MyInvocation.InvocationName -ne '.') { Get-MaesterRuntimeBundle -Destination $Destination }
