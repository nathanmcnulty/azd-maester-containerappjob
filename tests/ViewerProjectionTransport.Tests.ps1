#Requires -Version 7.6
BeforeAll {
  $root = Split-Path $PSScriptRoot -Parent
  Import-Module (Join-Path $root 'scripts/Maester.ViewerProjection.psm1') -Force
  if (-not ('MaesterProjectionTestHandler' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

public sealed class MaesterProjectionResponsePlan {
  public HttpStatusCode StatusCode { get; set; }
  public byte[] Body { get; set; } = Array.Empty<byte>();
  public string ETag { get; set; }
  public long? ContentLength { get; set; }
  public int DelayMilliseconds { get; set; }
  public string ErrorCode { get; set; }
}
public sealed class MaesterProjectionRequestRecord {
  public string Method { get; set; }
  public string Uri { get; set; }
  public Dictionary<string,string> Headers { get; set; }
  public byte[] Body { get; set; }
}
public sealed class MaesterProjectionTestHandler : HttpMessageHandler {
  public Queue<MaesterProjectionResponsePlan> Plans { get; } = new Queue<MaesterProjectionResponsePlan>();
  public List<MaesterProjectionRequestRecord> Requests { get; } = new List<MaesterProjectionRequestRecord>();
  protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) {
    var headers = request.Headers.Concat(request.Content == null ? Enumerable.Empty<KeyValuePair<string,IEnumerable<string>>>() : request.Content.Headers)
      .ToDictionary(h => h.Key, h => string.Join(",", h.Value), StringComparer.OrdinalIgnoreCase);
    var body = request.Content == null ? Array.Empty<byte>() : await request.Content.ReadAsByteArrayAsync(cancellationToken);
    Requests.Add(new MaesterProjectionRequestRecord { Method=request.Method.Method, Uri=request.RequestUri.AbsoluteUri, Headers=headers, Body=body });
    if (Plans.Count == 0) throw new InvalidOperationException("No response plan.");
    var plan = Plans.Dequeue();
    if (plan.DelayMilliseconds > 0) await Task.Delay(plan.DelayMilliseconds, cancellationToken);
    var response = new HttpResponseMessage(plan.StatusCode);
    response.Content = new ByteArrayContent(plan.Body ?? Array.Empty<byte>());
    if (plan.ContentLength.HasValue) response.Content.Headers.ContentLength = plan.ContentLength.Value;
    if (plan.ETag != null) response.Headers.ETag = new System.Net.Http.Headers.EntityTagHeaderValue(plan.ETag);
    if (plan.ErrorCode != null) response.Headers.TryAddWithoutValidation("x-ms-error-code", plan.ErrorCode);
    return response;
  }
}
'@
  }
  function New-TransportStore($Handler, [TimeSpan]$Timeout=[TimeSpan]::FromSeconds(2)) {
    $tokenProvider = { ConvertTo-SecureString 'fixture-token' -AsPlainText -Force }
    New-MaesterAzureBlobProjectionStore -AccountName 'vieweraccount' -ContainerName 'viewer-projection' -TokenProvider $tokenProvider -OperationTimeout $Timeout -HttpMessageHandler $Handler
  }
  function Add-Response($Handler, $Status, [byte[]]$Body=[byte[]]::new(0), $ETag=$null, $Length=$null, $Delay=0, $ErrorCode=$null) {
    $plan = [MaesterProjectionResponsePlan]::new(); $plan.StatusCode=[Net.HttpStatusCode]$Status; $plan.Body=$Body; $plan.DelayMilliseconds=$Delay
    if ($ETag) { $plan.ETag=$ETag }
    if ($null -ne $Length) { $plan.ContentLength=[long]$Length }
    $plan.ErrorCode=$ErrorCode
    $Handler.Plans.Enqueue($plan)
  }
}

Describe 'Azure Blob projection REST transport' {
  It 'configures direct anonymous HTTP plumbing without redirects or ambient credentials' {
    InModuleScope Maester.ViewerProjection {
      $handler = New-MaesterProjectionHttpHandler
      try {
        $handler.AllowAutoRedirect | Should -BeFalse
        $handler.UseProxy | Should -BeFalse
        $handler.UseCookies | Should -BeFalse
        $handler.UseDefaultCredentials | Should -BeFalse
        $handler.Credentials | Should -BeNullOrEmpty
        $handler.PreAuthenticate | Should -BeFalse
      } finally { $handler.Dispose() }
    }
  }

  It 'constructs the fixed Azure Blob URI and preserves conditional ETags' {
    $handler = [MaesterProjectionTestHandler]::new()
    Add-Response $handler Created -ETag '"created"'
    Add-Response $handler PreconditionFailed
    $store = New-TransportStore $handler
    $bytes = [Text.Encoding]::UTF8.GetBytes('{}')
    (& $store -Operation Put -Key 'latest.json' -Bytes $bytes -ContentType 'application/json' -IfNoneMatch '*').status | Should -BeExactly 'created'
    (& $store -Operation Put -Key 'latest.json' -Bytes $bytes -ContentType 'application/json' -IfMatch '"created"').status | Should -BeExactly 'preconditionFailed'
    $handler.Requests[0].Uri | Should -BeExactly 'https://vieweraccount.blob.core.windows.net/viewer-projection/latest.json'
    $handler.Requests[0].Headers['If-None-Match'] | Should -BeExactly '*'
    $handler.Requests[1].Headers['If-Match'] | Should -BeExactly '"created"'
    $handler.Requests[0].Headers['x-ms-blob-type'] | Should -BeExactly 'BlockBlob'
    $handler.Requests[0].Headers['Authorization'] | Should -BeExactly 'Bearer fixture-token'
    [Text.Encoding]::UTF8.GetString($handler.Requests[0].Body) | Should -BeExactly '{}'
  }

  It 'classifies only the specific create-only BlobAlreadyExists conflict <name>' -ForEach @(
    @{ name='create-only collision'; code='BlobAlreadyExists'; operation='Put'; none='*'; match=$null; accepted=$true },
    @{ name='other conflict'; code='LeaseAlreadyPresent'; operation='Put'; none='*'; match=$null; accepted=$false },
    @{ name='missing code'; code=$null; operation='Put'; none='*'; match=$null; accepted=$false },
    @{ name='conditional replacement'; code='BlobAlreadyExists'; operation='Put'; none=$null; match='"etag"'; accepted=$false },
    @{ name='GET conflict'; code='BlobAlreadyExists'; operation='Get'; none=$null; match=$null; accepted=$false }
  ) {
    $handler = [MaesterProjectionTestHandler]::new()
    Add-Response $handler Conflict -ErrorCode $code
    $store = New-TransportStore $handler
    $invoke = { & $store -Operation $operation -Key latest.json -Bytes ([Text.Encoding]::UTF8.GetBytes('{}')) -ContentType application/json -IfNoneMatch $none -IfMatch $match -MaximumBytes 2048 }
    if ($accepted) { (& $invoke).status | Should -BeExactly 'preconditionFailed' }
    else { $invoke | Should -Throw -ExpectedMessage 'Projection storage operation failed.' }
    $handler.Requests.Count | Should -Be 1
  }

  It 'returns only bounded GET bytes and the opaque ETag' {
    $handler = [MaesterProjectionTestHandler]::new(); $body=[Text.Encoding]::UTF8.GetBytes('{"ok":true}')
    Add-Response $handler OK $body '"opaque,etag"' $body.Length
    $store = New-TransportStore $handler
    $result = & $store -Operation Get -Key 'latest.json' -MaximumBytes 2048
    $result.status | Should -BeExactly 'found'
    $result.etag | Should -BeExactly '"opaque,etag"'
    [Convert]::ToHexString($result.bytes) | Should -BeExactly ([Convert]::ToHexString($body))
  }

  It 'maps only an exact GET 404 to missing' {
    $handler = [MaesterProjectionTestHandler]::new(); Add-Response $handler NotFound
    $store = New-TransportStore $handler
    (& $store -Operation Get -Key 'latest.json' -MaximumBytes 2048).status | Should -BeExactly 'missing'
  }

  It 'fails closed for redirect, oversized, truncated, timeout, and unexpected status <name>' -ForEach @(
    @{ name='redirect'; status=[Net.HttpStatusCode]::Redirect; body=[byte[]]::new(0); length=$null; max=2048; delay=0 },
    @{ name='oversized'; status=[Net.HttpStatusCode]::OK; body=[byte[]]::new(9); length=9; max=8; delay=0 },
    @{ name='truncated'; status=[Net.HttpStatusCode]::OK; body=[byte[]](1,2); length=4; max=8; delay=0 },
    @{ name='timeout'; status=[Net.HttpStatusCode]::OK; body=[byte[]](1); length=1; max=8; delay=500 },
    @{ name='server error'; status=[Net.HttpStatusCode]::InternalServerError; body=[byte[]]::new(0); length=$null; max=8; delay=0 }
  ) {
    $handler = [MaesterProjectionTestHandler]::new(); Add-Response $handler $status $body '"etag"' $length $delay
    $timeout = if ($name -eq 'timeout') { [TimeSpan]::FromMilliseconds(50) } else { [TimeSpan]::FromSeconds(2) }
    $store = New-TransportStore $handler $timeout
    { & $store -Operation Get -Key 'latest.json' -MaximumBytes $max } | Should -Throw -ExpectedMessage 'Projection storage operation failed.'
  }

  It 'rejects caller paths and malformed targets before token acquisition or dispatch <name>' -ForEach @(
    @{ name='traversal'; key='../archive/report.html' },
    @{ name='foreign path'; key='archive/report.html' },
    @{ name='query'; key='latest.json?sig=secret' }
  ) {
    $handler = [MaesterProjectionTestHandler]::new(); $calls=0
    $provider = { $calls++; ConvertTo-SecureString 'token' -AsPlainText -Force }.GetNewClosure()
    $store = New-MaesterAzureBlobProjectionStore -AccountName 'vieweraccount' -ContainerName 'viewer-projection' -TokenProvider $provider -HttpMessageHandler $handler
    { & $store -Operation Get -Key $key -MaximumBytes 2048 } | Should -Throw -ExpectedMessage 'Projection storage operation failed.'
    $handler.Requests.Count | Should -Be 0
  }

  It 'returns sanitized errors without target or token details' {
    $handler = [MaesterProjectionTestHandler]::new(); Add-Response $handler InternalServerError
    $store = New-TransportStore $handler
    try { $null = & $store -Operation Get -Key 'latest.json' -MaximumBytes 2048; throw 'expected failure' }
    catch {
      $_.Exception.Message | Should -BeExactly 'Projection storage operation failed.'
      $_ | Out-String | Should -Not -Match 'vieweraccount|fixture-token|blob.core|latest.json'
    }
  }
}
