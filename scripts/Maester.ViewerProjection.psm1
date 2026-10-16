#Requires -Version 7.6
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Maester.ViewerContent.psm1') -Force

$script:PointerKey = 'latest.json'
$script:ManifestMaximumBytes = 8192
$script:PointerMaximumBytes = 2048
$script:DefaultHtmlMaximumBytes = 20MB
$script:AbsoluteHtmlMaximumBytes = 64MB

function Assert-MaesterProjectionIdentity {
  param([string]$TenantId, [string]$Environment, [AllowNull()][string]$RunId, [switch]$TenantEnvironmentOnly)
  $tenant = [guid]::Empty
  if (-not [guid]::TryParseExact($TenantId, 'D', [ref]$tenant) -or $tenant -eq [guid]::Empty -or
      $TenantId -cne $tenant.ToString('D')) { throw 'Projection identity is invalid.' }
  if (-not $TenantEnvironmentOnly) {
    $run = [guid]::Empty
    if (-not [guid]::TryParseExact($RunId, 'D', [ref]$run) -or $run -eq [guid]::Empty -or
        $RunId -cne $run.ToString('D')) { throw 'Projection identity is invalid.' }
  }
  if ($Environment -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z') { throw 'Projection identity is invalid.' }
}

function Get-MaesterProjectionGeneration {
  param([Parameter(Mandatory)][DateTimeOffset]$RunStartedAtUtc)
  if ($RunStartedAtUtc.Offset -ne [TimeSpan]::Zero) { throw 'RunStartedAtUtc must be UTC.' }
  return $RunStartedAtUtc.UtcTicks.ToString('D20', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-MaesterProjectionHash { param([byte[]]$Bytes) [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)) }
function ConvertTo-MaesterProjectionJson { param([object]$Value) [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 8 -Compress)) }
function Test-MaesterProjectionBytesEqual {
  param([byte[]]$Left, [byte[]]$Right)
  $Left.Length -eq $Right.Length -and [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($Left, $Right)
}

function Assert-MaesterProjectionPropertySet {
  param([object]$Value, [string[]]$Names)
  if ($null -eq $Value -or $Value -isnot [pscustomobject]) { throw 'Projection document is invalid.' }
  $actual = @($Value.PSObject.Properties.Name)
  if ($actual.Count -ne $Names.Count -or @($actual | Where-Object { $_ -cnotin $Names }).Count -ne 0) {
    throw 'Projection document is invalid.'
  }
}

function ConvertFrom-MaesterProjectionDocument {
  param([byte[]]$Bytes, [ValidateSet('pointer','manifest')][string]$Kind)
  try {
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
    $value = $text | ConvertFrom-Json -Depth 8 -DateKind String -ErrorAction Stop
    Assert-MaesterProjectionPropertySet $value @('schemaVersion','tenantId','environment','runId','generation',$(if ($Kind -eq 'pointer') {'manifest'} else {'html'}))
    if ($value.schemaVersion -isnot [string] -or $value.schemaVersion -cne '1.0' -or
        $value.tenantId -isnot [string] -or $value.environment -isnot [string] -or $value.runId -isnot [string] -or
        $value.generation -isnot [string] -or $value.generation -cnotmatch '\A[0-9]{20}\z') { throw 'invalid' }
    $ticks = [long]0
    if (-not [long]::TryParse($value.generation, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$ticks) -or
        $ticks -lt 0 -or $ticks -gt [DateTimeOffset]::MaxValue.UtcTicks) { throw 'invalid' }
    Assert-MaesterProjectionIdentity $value.tenantId $value.environment $value.runId
    $binding = if ($Kind -eq 'pointer') { $value.manifest } else { $value.html }
    Assert-MaesterProjectionPropertySet $binding @('key','length','sha256')
    if ($binding.key -isnot [string] -or $binding.length -isnot [long] -and $binding.length -isnot [int] -or
        [long]$binding.length -lt 1 -or $binding.sha256 -isnot [string] -or $binding.sha256 -cnotmatch '\A[A-F0-9]{64}\z') { throw 'invalid' }
    $expectedKey = "runs/$($value.runId)/$(if ($Kind -eq 'pointer') {'manifest.json'} else {'report.html'})"
    if ($binding.key -cne $expectedKey) { throw 'invalid' }
    return $value
  } catch { throw 'Projection document is invalid.' }
}

function Invoke-MaesterStoreGet {
  param([scriptblock]$Store, [string]$Key, [int64]$MaximumBytes)
  $result = & $Store -Operation Get -Key $Key -MaximumBytes $MaximumBytes
  if ($null -eq $result -or $result.status -notin @('found','missing')) { throw 'Projection storage operation failed.' }
  if ($result.status -eq 'found' -and ($result.bytes -isnot [byte[]] -or $result.bytes.Length -gt $MaximumBytes -or
      $result.etag -isnot [string] -or [string]::IsNullOrWhiteSpace($result.etag))) { throw 'Projection storage operation failed.' }
  return $result
}

function Invoke-MaesterStorePut {
  param([scriptblock]$Store, [string]$Key, [byte[]]$Bytes, [string]$ContentType, [string]$IfMatch, [string]$IfNoneMatch)
  $result = & $Store -Operation Put -Key $Key -Bytes $Bytes -ContentType $ContentType -IfMatch $IfMatch -IfNoneMatch $IfNoneMatch
  if ($null -eq $result -or $result.status -notin @('created','preconditionFailed')) { throw 'Projection storage operation failed.' }
  return $result
}

function Write-MaesterImmutableProjectionObject {
  param([scriptblock]$Store, [string]$Key, [byte[]]$Bytes, [string]$ContentType, [int64]$MaximumBytes)
  $put = Invoke-MaesterStorePut $Store $Key $Bytes $ContentType $null '*'
  if ($put.status -eq 'created') { return }
  $existing = Invoke-MaesterStoreGet $Store $Key $MaximumBytes
  if ($existing.status -ne 'found' -or -not (Test-MaesterProjectionBytesEqual $existing.bytes $Bytes)) {
    throw 'Immutable projection object collision.'
  }
}

function Publish-MaesterViewerProjection {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][byte[]]$HtmlBytes,
    [Parameter(Mandatory)][byte[]]$TemplateBytes,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$Environment,
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][DateTimeOffset]$RunStartedAtUtc,
    [Parameter(Mandatory)][scriptblock]$Store,
    [ValidateRange(1, 67108864)][int64]$MaximumHtmlBytes = $script:DefaultHtmlMaximumBytes
  )
  Assert-MaesterProjectionIdentity $TenantId $Environment $RunId
  $null=Assert-MaesterViewerReportProjection -HtmlBytes $HtmlBytes -TemplateBytes $TemplateBytes
  if ($MaximumHtmlBytes -gt $script:AbsoluteHtmlMaximumBytes -or $HtmlBytes.Length -eq 0 -or $HtmlBytes.Length -gt $MaximumHtmlBytes) {
    throw 'Projection HTML is invalid.'
  }
  try {
    $html = [Text.UTF8Encoding]::new($false, $true).GetString($HtmlBytes)
    if ($html -notmatch '(?is)\A\s*(?:<!doctype\s+html\b|<html\b)') { throw 'invalid' }
  } catch { throw 'Projection HTML is invalid.' }

  $generation = Get-MaesterProjectionGeneration $RunStartedAtUtc
  $htmlKey = "runs/$RunId/report.html"
  $manifestKey = "runs/$RunId/manifest.json"
  $htmlHash = Get-MaesterProjectionHash $HtmlBytes
  $manifest = [ordered]@{
    schemaVersion='1.0'; tenantId=$TenantId; environment=$Environment; runId=$RunId; generation=$generation
    html=[ordered]@{ key=$htmlKey; length=[long]$HtmlBytes.Length; sha256=$htmlHash }
  }
  $manifestBytes = ConvertTo-MaesterProjectionJson $manifest
  if ($manifestBytes.Length -gt $script:ManifestMaximumBytes) { throw 'Projection manifest is invalid.' }
  $pointer = [ordered]@{
    schemaVersion='1.0'; tenantId=$TenantId; environment=$Environment; runId=$RunId; generation=$generation
    manifest=[ordered]@{ key=$manifestKey; length=[long]$manifestBytes.Length; sha256=(Get-MaesterProjectionHash $manifestBytes) }
  }
  $pointerBytes = ConvertTo-MaesterProjectionJson $pointer
  if ($pointerBytes.Length -gt $script:PointerMaximumBytes) { throw 'Projection pointer is invalid.' }

  Write-MaesterImmutableProjectionObject $Store $htmlKey $HtmlBytes 'text/html; charset=utf-8' $MaximumHtmlBytes
  Write-MaesterImmutableProjectionObject $Store $manifestKey $manifestBytes 'application/json' $script:ManifestMaximumBytes

  for ($attempt = 1; $attempt -le 3; $attempt++) {
    $current = Invoke-MaesterStoreGet $Store $script:PointerKey $script:PointerMaximumBytes
    $condition = @{ IfMatch=$null; IfNoneMatch='*' }
    if ($current.status -eq 'found') {
      $currentPointer = ConvertFrom-MaesterProjectionDocument $current.bytes pointer
      if ($currentPointer.tenantId -cne $TenantId -or $currentPointer.environment -cne $Environment) {
        throw 'Projection pointer identity mismatch.'
      }
      $comparison = [string]::CompareOrdinal($generation, [string]$currentPointer.generation)
      if ($comparison -lt 0) {
        return [pscustomobject][ordered]@{ published=$false; disposition='older'; tenantId=$TenantId; environment=$Environment; runId=$RunId; generation=$generation; htmlSha256=$htmlHash }
      }
      if ($comparison -eq 0) {
        if ($currentPointer.runId -ceq $RunId -and $currentPointer.manifest.sha256 -ceq $pointer.manifest.sha256) {
          return [pscustomobject][ordered]@{ published=$true; disposition='idempotent'; tenantId=$TenantId; environment=$Environment; runId=$RunId; generation=$generation; htmlSha256=$htmlHash }
        }
        throw 'Projection generation collision.'
      }
      $condition = @{ IfMatch=$current.etag; IfNoneMatch=$null }
    }
    $updated = Invoke-MaesterStorePut $Store $script:PointerKey $pointerBytes 'application/json' $condition.IfMatch $condition.IfNoneMatch
    if ($updated.status -eq 'created') {
      return [pscustomobject][ordered]@{ published=$true; disposition='advanced'; tenantId=$TenantId; environment=$Environment; runId=$RunId; generation=$generation; htmlSha256=$htmlHash }
    }
  }
  throw 'Projection pointer update did not converge.'
}

function Read-MaesterViewerProjection {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$Environment,
    [Parameter(Mandatory)][byte[]]$TemplateBytes,
    [Parameter(Mandatory)][scriptblock]$Store,
    [ValidateRange(1, 67108864)][int64]$MaximumHtmlBytes = $script:DefaultHtmlMaximumBytes
  )
  Assert-MaesterProjectionIdentity $TenantId $Environment $null -TenantEnvironmentOnly
  Assert-MaesterViewerContentTemplate -TemplateBytes $TemplateBytes
  if ($MaximumHtmlBytes -gt $script:AbsoluteHtmlMaximumBytes) { throw 'Projection size limit is invalid.' }
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    $pointerRead = Invoke-MaesterStoreGet $Store $script:PointerKey $script:PointerMaximumBytes
    if ($pointerRead.status -ne 'found') { throw 'Projection snapshot is unavailable.' }
    $pointer = ConvertFrom-MaesterProjectionDocument $pointerRead.bytes pointer
    if ($pointer.tenantId -cne $TenantId -or $pointer.environment -cne $Environment -or
        [long]$pointer.manifest.length -gt $script:ManifestMaximumBytes) { throw 'Projection snapshot identity mismatch.' }

    $manifestRead = Invoke-MaesterStoreGet $Store $pointer.manifest.key $script:ManifestMaximumBytes
    if ($manifestRead.status -ne 'found' -or $manifestRead.bytes.Length -ne [long]$pointer.manifest.length -or
        (Get-MaesterProjectionHash $manifestRead.bytes) -cne $pointer.manifest.sha256) { throw 'Projection snapshot manifest is invalid.' }
    $manifest = ConvertFrom-MaesterProjectionDocument $manifestRead.bytes manifest
    if ($manifest.tenantId -cne $TenantId -or $manifest.environment -cne $Environment -or
        $manifest.runId -cne $pointer.runId -or $manifest.generation -cne $pointer.generation -or
        [long]$manifest.html.length -gt $MaximumHtmlBytes) { throw 'Projection snapshot manifest is invalid.' }

    $htmlRead = Invoke-MaesterStoreGet $Store $manifest.html.key $MaximumHtmlBytes
    if ($htmlRead.status -ne 'found' -or $htmlRead.bytes.Length -ne [long]$manifest.html.length -or
        (Get-MaesterProjectionHash $htmlRead.bytes) -cne $manifest.html.sha256) { throw 'Projection snapshot HTML is invalid.' }
    try { $null=Assert-MaesterViewerReportProjection -HtmlBytes $htmlRead.bytes -TemplateBytes $TemplateBytes }
    catch { throw 'Projection snapshot HTML is invalid.' }

    $confirm = Invoke-MaesterStoreGet $Store $script:PointerKey $script:PointerMaximumBytes
    if ($confirm.status -eq 'found' -and $confirm.etag -ceq $pointerRead.etag -and
        (Test-MaesterProjectionBytesEqual $confirm.bytes $pointerRead.bytes)) {
      return [pscustomobject][ordered]@{
        verified=$true; tenantId=$TenantId; environment=$Environment; runId=$pointer.runId; generation=$pointer.generation
        htmlLength=[long]$htmlRead.bytes.Length; htmlSha256=$manifest.html.sha256; htmlBytes=$htmlRead.bytes
      }
    }
  }
  throw 'Projection snapshot changed during read.'
}

function Test-MaesterProjectionBlobKey {
  param([string]$Key)
  $Key -ceq 'latest.json' -or $Key -cmatch '\Aruns/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/(?:report\.html|manifest\.json)\z'
}

function New-MaesterProjectionHttpHandler {
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Creates an in-memory HTTP handler and does not change external state.')]
  [CmdletBinding()]
  param()
  $handler = [Net.Http.HttpClientHandler]::new()
  $handler.AllowAutoRedirect = $false
  $handler.UseProxy = $false
  $handler.UseCookies = $false
  $handler.UseDefaultCredentials = $false
  $handler.Credentials = $null
  $handler.PreAuthenticate = $false
  return $handler
}

function New-MaesterAzureBlobProjectionStore {
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Creates a callback; storage changes occur only when the callback is explicitly invoked.')]
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$AccountName,
    [Parameter(Mandatory)][string]$ContainerName,
    [Parameter(Mandatory)][scriptblock]$TokenProvider,
    [ValidateScript({ $_ -gt [TimeSpan]::Zero -and $_ -le [TimeSpan]::FromSeconds(15) })]
    [TimeSpan]$OperationTimeout = [TimeSpan]::FromSeconds(15),
    [Net.Http.HttpMessageHandler]$HttpMessageHandler
  )
  if ($AccountName -cnotmatch '\A[a-z0-9]{3,24}\z' -or $ContainerName -cnotmatch '\A[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])\z' -or $ContainerName -match '--') {
    throw 'Projection storage target is invalid.'
  }
  $baseUri = "https://$AccountName.blob.core.windows.net/$ContainerName/"
  $fixedKeyPattern = '\A(?:latest\.json|runs/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/(?:report\.html|manifest\.json))\z'
  $absoluteMaximumBytes = $script:AbsoluteHtmlMaximumBytes
  $capturedTokenProvider = $TokenProvider
  $capturedOperationTimeout = $OperationTimeout
  $injectedHandler = $HttpMessageHandler
  $defaultHandlerFactory = {
    $created = [Net.Http.HttpClientHandler]::new()
    $created.AllowAutoRedirect = $false; $created.UseProxy = $false; $created.UseCookies = $false
    $created.UseDefaultCredentials = $false; $created.Credentials = $null; $created.PreAuthenticate = $false
    return $created
  }

  return {
    param([string]$Operation, [string]$Key, [byte[]]$Bytes, [string]$ContentType, [string]$IfMatch, [string]$IfNoneMatch, [int64]$MaximumBytes)
    if ($Operation -notin @('Get','Put') -or $Key -cnotmatch $fixedKeyPattern) { throw 'Projection storage operation failed.' }
    if ($Operation -eq 'Put' -and ($Bytes -isnot [byte[]] -or $Bytes.Length -eq 0 -or $Bytes.Length -gt $absoluteMaximumBytes)) { throw 'Projection storage operation failed.' }
    if ($Operation -eq 'Get' -and ($MaximumBytes -lt 1 -or $MaximumBytes -gt $absoluteMaximumBytes)) { throw 'Projection storage operation failed.' }
    $token = $null; $tokenPointer = [IntPtr]::Zero; $handler = $null; $client = $null; $request = $null; $response = $null; $stream = $null; $buffered = $null; $deadline = $null
    try {
      $secureToken = & $capturedTokenProvider
      if ($secureToken -isnot [Security.SecureString]) { throw 'invalid token' }
      $tokenPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
      $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPointer)
      if ([string]::IsNullOrWhiteSpace($token)) { throw 'invalid token' }
      $segments = $Key -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }
      $uri = $baseUri + ($segments -join '/')
      $handler = if ($injectedHandler) { $injectedHandler } else { & $defaultHandlerFactory }
      $client = [Net.Http.HttpClient]::new($handler, $null -eq $injectedHandler)
      $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
      $method = if ($Operation -eq 'Get') { [Net.Http.HttpMethod]::Get } else { [Net.Http.HttpMethod]::Put }
      $request = [Net.Http.HttpRequestMessage]::new($method, $uri)
      $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
      $request.Headers.Add('x-ms-version', '2023-11-03')
      $request.Headers.Add('x-ms-date', [DateTimeOffset]::UtcNow.ToString('R', [Globalization.CultureInfo]::InvariantCulture))
      if ($IfMatch) { $request.Headers.TryAddWithoutValidation('If-Match', $IfMatch) | Out-Null }
      if ($IfNoneMatch) { $request.Headers.TryAddWithoutValidation('If-None-Match', $IfNoneMatch) | Out-Null }
      if ($Operation -eq 'Put') {
        $request.Headers.Add('x-ms-blob-type', 'BlockBlob')
        $request.Content = [Net.Http.ByteArrayContent]::new($Bytes)
        $request.Content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::Parse($ContentType)
      }
      $deadline = [Threading.CancellationTokenSource]::new($capturedOperationTimeout)
      $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $deadline.Token).GetAwaiter().GetResult()
      if ($Operation -eq 'Put') {
        if ($response.StatusCode -eq [Net.HttpStatusCode]::Created) { return [pscustomobject]@{ status='created'; etag=$(if ($response.Headers.ETag) {$response.Headers.ETag.ToString()} else {$null}) } }
        if ($response.StatusCode -eq [Net.HttpStatusCode]::PreconditionFailed) { return [pscustomobject]@{ status='preconditionFailed'; etag=$null } }
        if ($response.StatusCode -eq [Net.HttpStatusCode]::Conflict -and $IfNoneMatch -ceq '*' -and -not $IfMatch -and
            $response.Headers.Contains('x-ms-error-code')) {
          $codes = @($response.Headers.GetValues('x-ms-error-code'))
          if ($codes.Count -eq 1 -and $codes[0] -ceq 'BlobAlreadyExists') {
            return [pscustomobject]@{ status='preconditionFailed'; etag=$null }
          }
        }
        throw 'unexpected status'
      }
      if ($response.StatusCode -eq [Net.HttpStatusCode]::NotFound) { return [pscustomobject]@{ status='missing'; etag=$null; bytes=$null } }
      if ($response.StatusCode -ne [Net.HttpStatusCode]::OK -or -not $response.Headers.ETag) { throw 'unexpected status' }
      $length = $response.Content.Headers.ContentLength
      if ($null -ne $length -and ($length -lt 1 -or $length -gt $MaximumBytes)) { throw 'invalid length' }
      $stream = $response.Content.ReadAsStreamAsync($deadline.Token).GetAwaiter().GetResult()
      $buffered = [IO.MemoryStream]::new(); $buffer = [byte[]]::new(8192); $total = 0
      while (($read = $stream.ReadAsync($buffer, 0, $buffer.Length, $deadline.Token).GetAwaiter().GetResult()) -gt 0) {
        if ($total + $read -gt $MaximumBytes) { throw 'too large' }
        $buffered.Write($buffer, 0, $read); $total += $read
      }
      if ($total -eq 0 -or ($null -ne $length -and $total -ne $length)) { throw 'invalid body' }
      return [pscustomobject]@{ status='found'; etag=$response.Headers.ETag.ToString(); bytes=$buffered.ToArray() }
    } catch { throw 'Projection storage operation failed.' }
    finally {
      $token = $null
      if ($tokenPointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPointer) }
      if ($buffered) { $buffered.Dispose() }; if ($stream) { $stream.Dispose() }; if ($response) { $response.Dispose() }
      if ($request) { $request.Dispose() }; if ($deadline) { $deadline.Dispose() }
      if ($client) { $client.Dispose() }
      elseif ($handler -and $null -eq $injectedHandler) { $handler.Dispose() }
    }
  }.GetNewClosure()
}

Export-ModuleMember -Function Publish-MaesterViewerProjection, Read-MaesterViewerProjection, New-MaesterAzureBlobProjectionStore
