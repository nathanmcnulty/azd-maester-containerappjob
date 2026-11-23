# Validation utility only. Execute solely in an isolated approved smoke Job identity.
# MAESTER_RUNTIME_BOOTSTRAP must be the reviewed production bootstrap, base64-encoded.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:POWERSHELL_TELEMETRY_OPTOUT = '1'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$owned = Join-Path ([IO.Path]::GetTempPath()) ('maester-reader-probe-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $owned
$client = $null; $token = $null; $probeName = $null; $writeAttempted = $false
try {
  # Dot-source the same reviewed helper for its bounded streams and redirect-off client.
  $source = Join-Path $owned 'bootstrap.ps1'
  [IO.File]::WriteAllBytes($source, [Convert]::FromBase64String($env:MAESTER_RUNTIME_BOOTSTRAP))
  . $source
  $account = $env:MAESTER_RUNTIME_STORAGE_ACCOUNT
  $hash = $env:MAESTER_RUNTIME_SHA256
  [long]$expectedSize = 0
  if ($account -cnotmatch '^[a-z0-9]{3,24}\z' -or $hash -cnotmatch '^[a-f0-9]{64}\z' -or $env:MAESTER_RUNTIME_BLOB_NAME -cne "bundles/$hash.zip" -or -not [long]::TryParse($env:MAESTER_RUNTIME_SIZE, [ref]$expectedSize) -or $expectedSize -lt 1 -or $expectedSize -gt 536870912) { throw 'Invalid approved runtime pins.' }
  $endpoint = $null
  if (-not [Uri]::TryCreate($env:IDENTITY_ENDPOINT, [UriKind]::Absolute, [ref]$endpoint) -or $endpoint.Scheme -cne 'http' -or $endpoint.UserInfo -or $endpoint.Query -or $endpoint.Fragment -or $endpoint.AbsolutePath -cne '/msi/token' -or $endpoint.Host -notin @('localhost','127.0.0.1','[::1]','169.254.255.2') -or [string]::IsNullOrWhiteSpace($env:IDENTITY_HEADER)) { throw 'Unexpected identity endpoint.' }
  $client = New-MaesterRuntimeHttpClient
  $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, "$($endpoint.AbsoluteUri)?api-version=2019-08-01&resource=https%3A%2F%2Fstorage.azure.com%2F")
  $null = $request.Headers.TryAddWithoutValidation('X-IDENTITY-HEADER', $env:IDENTITY_HEADER)
  try {
    $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    try {
      if ([int]$response.StatusCode -ne 200) { throw 'Token acquisition failed.' }
      $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult(); $memory = [IO.MemoryStream]::new()
      try {
        $null = Copy-MaesterBoundedStream -Source $stream -Target $memory -Limit 65536
        $token = ([Text.Encoding]::UTF8.GetString($memory.ToArray()) | ConvertFrom-Json).access_token
        if ([string]::IsNullOrWhiteSpace($token) -or $token.Length -gt 32768 -or $token -match '[\r\n]') { throw 'Invalid token response.' }
      } finally { $stream.Dispose(); $memory.Dispose() }
    } finally { $response.Dispose() }
  } finally { $request.Dispose() }
  $probeName = 'smoke-write-denial/' + [guid]::NewGuid().ToString('N') + '.txt'
  foreach ($operation in @('read','write')) {
    $uri = if ($operation -eq 'read') { "https://$account.blob.core.windows.net/runtime/bundles/$hash.zip" } else { "https://$account.blob.core.windows.net/runtime/$probeName" }
    $method = if ($operation -eq 'read') { [Net.Http.HttpMethod]::Head } else { [Net.Http.HttpMethod]::Put }
    $request = [Net.Http.HttpRequestMessage]::new($method, $uri)
    $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
    $null = $request.Headers.TryAddWithoutValidation('x-ms-version', '2023-11-03')
    if ($operation -eq 'write') {
      # Emit the destination BEFORE transport so an uncertain write can be inspected without retrying.
      [ordered]@{ validation='runtime-reader-write-denial-attempt'; probeBlob=$probeName; marker='runtime-reader-write-denial-probe' } | ConvertTo-Json -Compress
      $writeAttempted = $true
      $null = $request.Headers.TryAddWithoutValidation('If-None-Match', '*')
      $null = $request.Headers.TryAddWithoutValidation('x-ms-blob-type', 'BlockBlob')
      $request.Content = [Net.Http.ByteArrayContent]::new([Text.Encoding]::UTF8.GetBytes('runtime-reader-write-denial-probe'))
    }
    try {
      $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
      try {
        $status = [int]$response.StatusCode
        if ($operation -eq 'read') {
          if ($status -ne 200 -or $response.Content.Headers.ContentLength -ne $expectedSize) { throw 'Reader control failed; a write denial would not prove isolation.' }
        } else {
          $errorCode = if ($response.Headers.Contains('x-ms-error-code')) { ($response.Headers.GetValues('x-ms-error-code') -join '') } else { '' }
          # Do not accept generic auth/network/account failures as proof of least privilege.
          $passed = $status -eq 403 -and $errorCode -ceq 'AuthorizationPermissionMismatch'
          [ordered]@{ validation='runtime-reader-write-denial'; passed=$passed; readStatus=200; writeStatus=$status; errorCode=$(if ($errorCode -ceq 'AuthorizationPermissionMismatch') { $errorCode } else { 'unexpected-or-missing' }); probeBlob=$probeName } | ConvertTo-Json -Compress
          if (-not $passed) { throw 'Reader write isolation was not proved; stop and preserve the fixture for review.' }
        }
      } finally { $response.Dispose() }
    } finally { $request.Dispose() }
  }
} catch {
  if ($writeAttempted) { [ordered]@{ validation='runtime-reader-write-denial-incomplete'; passed=$false; probeBlob=$probeName; requiresInspection=$true } | ConvertTo-Json -Compress }
  throw 'Runtime Reader smoke probe did not complete successfully. Inspect its sanitized result; never forward token diagnostics.' }
finally { $token = $null; if ($client) { $client.Dispose() }; Remove-Item -LiteralPath $owned -Recurse -Force }
