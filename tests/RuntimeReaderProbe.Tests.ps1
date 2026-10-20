BeforeAll {
  $script:probe = Join-Path $PSScriptRoot '../scripts/validation/Test-RuntimeReaderWriteDenial.ps1'
  $script:originalProbeHash = (Get-FileHash $probe).Hash
  $sourceRoot = Split-Path $PSScriptRoot -Parent
  $production = Join-Path $sourceRoot 'scripts/Get-MaesterRuntimeBundle.ps1'
  if (-not (Test-Path -LiteralPath $production -PathType Leaf)) { throw 'Set MAESTER_SOURCE_ROOT to the verified source checkout, or run from its root.' }
  $fixture = (Get-Content $production -Raw) + "`nfunction New-MaesterRuntimeHttpClient { [Net.Http.HttpClient]::new([OfflineReaderProbeHandler]::new()) }`n"
  $script:fixtureBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($fixture))
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public class ProbeRequest {
 public string Method; public string Uri; public string Headers; public string Body;
}
public class OfflineReaderProbeHandler : HttpMessageHandler {
 public static Queue<object> Responses = new Queue<object>();
 public static List<ProbeRequest> Requests = new List<ProbeRequest>();
 protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) {
  Requests.Add(new ProbeRequest { Method=request.Method.ToString(), Uri=request.RequestUri.AbsoluteUri, Headers=request.Headers.ToString(), Body=request.Content==null ? "" : request.Content.ReadAsStringAsync().GetAwaiter().GetResult() });
  if (Responses.Count==0) throw new InvalidOperationException("Unexpected transport request; no actual transport exists.");
  var response=Responses.Dequeue();
  if (response is Exception) throw (Exception)response;
  return Task.FromResult((HttpResponseMessage)response);
 }
}
'@
  function Add-OfflineResponse {
    param([int]$Status=200,[string]$Body='', [string]$ErrorCode='', [Nullable[long]]$Length=$null)
    $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$Status)
    $response.Content = [Net.Http.ByteArrayContent]::new([Text.Encoding]::UTF8.GetBytes($Body))
    if ($null -ne $Length) { $response.Content.Headers.ContentLength = $Length }
    if ($ErrorCode) { $null = $response.Headers.TryAddWithoutValidation('x-ms-error-code',$ErrorCode) }
    [OfflineReaderProbeHandler]::Responses.Enqueue($response)
  }
  function Invoke-OfflineProbe {
    $lines = [Collections.Generic.List[string]]::new(); $failure = $null
    try { & $script:probe 2>&1 | ForEach-Object { $lines.Add([string]$_) } }
    catch { $failure = $_.ToString() }
    [pscustomobject]@{ Lines=@($lines); Failure=$failure; Text=(@($lines) -join "`n") + [string]$failure }
  }
  $script:environmentNames = @('MAESTER_RUNTIME_BOOTSTRAP','MAESTER_RUNTIME_STORAGE_ACCOUNT','MAESTER_RUNTIME_SHA256','MAESTER_RUNTIME_BLOB_NAME','MAESTER_RUNTIME_SIZE','IDENTITY_ENDPOINT','IDENTITY_HEADER')
  $script:savedEnvironment = @{}
  foreach ($name in $environmentNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
}
AfterAll {
  foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name]) }
  (Get-FileHash $probe).Hash | Should -BeExactly $originalProbeHash
}
Describe 'Offline runtime Reader write-denial smoke probe' {
  BeforeEach {
    [OfflineReaderProbeHandler]::Responses.Clear(); [OfflineReaderProbeHandler]::Requests.Clear()
    $env:MAESTER_RUNTIME_BOOTSTRAP = $fixtureBase64
    $env:MAESTER_RUNTIME_STORAGE_ACCOUNT = 'smokefixture'
    $env:MAESTER_RUNTIME_SHA256 = 'a' * 64
    $env:MAESTER_RUNTIME_BLOB_NAME = "bundles/$env:MAESTER_RUNTIME_SHA256.zip"
    $env:MAESTER_RUNTIME_SIZE = '12345'
    $env:IDENTITY_ENDPOINT = 'http://localhost:1234/msi/token'
    $env:IDENTITY_HEADER = 'fixture-identity-secret'
    $script:beforeDirs = @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'maester-reader-probe-*' | Select-Object -ExpandProperty FullName)
  }
  AfterEach {
    @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'maester-reader-probe-*' | Where-Object FullName -NotIn $beforeDirs).Count | Should -Be 0
  }
  It 'accepts only positive exact-size read plus permission-mismatch write denial' {
    Add-OfflineResponse -Body '{"access_token":"fixture-bearer-secret"}'
    Add-OfflineResponse -Length 12345
    Add-OfflineResponse -Status 403 -ErrorCode AuthorizationPermissionMismatch
    $result = Invoke-OfflineProbe
    $result.Failure | Should -BeNullOrEmpty
    $records = @($result.Lines | ConvertFrom-Json)
    $records.Count | Should -Be 2
    $records[0].validation | Should -BeExactly 'runtime-reader-write-denial-attempt'
    $records[1].passed | Should -BeTrue
    $records[1].writeStatus | Should -Be 403
    $records[1].errorCode | Should -BeExactly 'AuthorizationPermissionMismatch'
    $records[0].probeBlob | Should -BeExactly $records[1].probeBlob
    $requests = [OfflineReaderProbeHandler]::Requests
    ($requests.Method -join ',') | Should -BeExactly 'GET,HEAD,PUT'
    $requests[0].Headers | Should -Match 'X-IDENTITY-HEADER: fixture-identity-secret'
    $requests[0].Headers | Should -Not -Match 'Authorization:'
    $requests[1].Uri | Should -BeExactly "https://smokefixture.blob.core.windows.net/runtime/bundles/$env:MAESTER_RUNTIME_SHA256.zip"
    $requests[2].Uri | Should -BeExactly "https://smokefixture.blob.core.windows.net/runtime/$($records[0].probeBlob)"
    $requests[2].Headers | Should -Match 'If-None-Match: \*'
    $requests[2].Headers | Should -Match 'x-ms-blob-type: BlockBlob'
    $requests[2].Headers | Should -Match 'Authorization: Bearer fixture-bearer-secret'
    $requests[2].Body | Should -BeExactly 'runtime-reader-write-denial-probe'
    $result.Text | Should -Not -Match 'fixture-bearer-secret|fixture-identity-secret'
  }
  It 'rejects wrong or missing 403 error code without disclosing response data' -TestCases @(@{ Code='AuthenticationFailed' },@{ Code='fixture-bearer-secret' },@{ Code='' }) {
    param($Code)
    Add-OfflineResponse -Body '{"access_token":"fixture-bearer-secret"}'
    Add-OfflineResponse -Length 12345
    Add-OfflineResponse -Status 403 -ErrorCode $Code -Body 'fixture-identity-secret'
    $result = Invoke-OfflineProbe
    $result.Failure | Should -Match 'did not complete successfully'
    $records = @($result.Lines | ConvertFrom-Json)
    $records[1].passed | Should -BeFalse
    $records[1].errorCode | Should -BeExactly 'unexpected-or-missing'
    $records[-1].requiresInspection | Should -BeTrue
    $result.Text | Should -Not -Match 'fixture-bearer-secret|fixture-identity-secret|AuthenticationFailed'
    [OfflineReaderProbeHandler]::Requests.Count | Should -Be 3
  }
  It 'stops before PUT on failed read or length mismatch' -TestCases @(@{Status=403;Length=12345},@{Status=404;Length=12345},@{Status=200;Length=12344}) {
    param($Status,$Length)
    Add-OfflineResponse -Body '{"access_token":"fixture-bearer-secret"}'
    Add-OfflineResponse -Status $Status -Length $Length
    $result = Invoke-OfflineProbe
    $result.Failure | Should -Match 'did not complete successfully'
    $result.Lines.Count | Should -Be 0
    ([OfflineReaderProbeHandler]::Requests.Method -join ',') | Should -BeExactly 'GET,HEAD'
    $result.Text | Should -Not -Match 'fixture-bearer-secret|fixture-identity-secret'
  }
  It 'treats successful write as failure and preserves exact attempted blob for cleanup review' {
    Add-OfflineResponse -Body '{"access_token":"fixture-bearer-secret"}'
    Add-OfflineResponse -Length 12345
    Add-OfflineResponse -Status 201
    $result = Invoke-OfflineProbe
    $result.Failure | Should -Match 'did not complete successfully'
    $records = @($result.Lines | ConvertFrom-Json)
    $records[1].passed | Should -BeFalse
    $records[1].writeStatus | Should -Be 201
    $records[-1].probeBlob | Should -BeExactly $records[0].probeBlob
    $records[-1].requiresInspection | Should -BeTrue
    [OfflineReaderProbeHandler]::Requests.Count | Should -Be 3
  }
  It 'records intended name before an uncertain write, suppresses exception secrets, and never retries' {
    Add-OfflineResponse -Body '{"access_token":"fixture-bearer-secret"}'
    Add-OfflineResponse -Length 12345
    [OfflineReaderProbeHandler]::Responses.Enqueue([Net.Http.HttpRequestException]::new('fixture-bearer-secret uncertain write fixture-identity-secret'))
    $result = Invoke-OfflineProbe
    $result.Failure | Should -Match 'did not complete successfully'
    $records = @($result.Lines | ConvertFrom-Json)
    $records.Count | Should -Be 2
    $records[0].probeBlob | Should -Match '^smoke-write-denial/[a-f0-9]{32}\.txt$'
    $records[1].requiresInspection | Should -BeTrue
    $records[1].probeBlob | Should -BeExactly $records[0].probeBlob
    $result.Text | Should -Not -Match 'fixture-bearer-secret|fixture-identity-secret'
    [OfflineReaderProbeHandler]::Requests.Count | Should -Be 3
  }
  It 'rejects each missing pin or identity header before transport' -TestCases @(
    @{Name='MAESTER_RUNTIME_STORAGE_ACCOUNT'},@{Name='MAESTER_RUNTIME_SHA256'},@{Name='MAESTER_RUNTIME_BLOB_NAME'},@{Name='MAESTER_RUNTIME_SIZE'},@{Name='IDENTITY_HEADER'}
  ) {
    param($Name)
    [Environment]::SetEnvironmentVariable($Name,$null)
    $result = Invoke-OfflineProbe
    $result.Failure | Should -Match 'did not complete successfully'
    $result.Lines.Count | Should -Be 0
    [OfflineReaderProbeHandler]::Requests.Count | Should -Be 0
  }
  It 'rejects malformed token before data requests without leaking it' -TestCases @(
    @{Body='not json fixture-bearer-secret'},@{Body='{"access_token":""}'},@{Body='{"no_token":"fixture-bearer-secret"}'},@{Body='{"access_token":"fixture-bearer-secret\n"}'}
  ) {
    param($Body)
    Add-OfflineResponse -Body $Body
    $result = Invoke-OfflineProbe
    $result.Failure | Should -Match 'did not complete successfully'
    $result.Text | Should -Not -Match 'fixture-bearer-secret|fixture-identity-secret'
    [OfflineReaderProbeHandler]::Requests.Count | Should -Be 1
  }
}

Describe 'Fixture-only runtime launcher stays aligned with production' {
  It 'changes only comments and the literal validation flag' {
    $root = Split-Path $PSScriptRoot -Parent
    $production = Get-Content (Join-Path $root 'scripts/Start-MaesterRuntimeBootstrap.sh')
    $smoke = Get-Content (Join-Path $root 'scripts/validation/Start-RuntimeOnlySmoke.sh')
    $productionCode = ($production | Where-Object { $_ -notmatch '^#' }) -join "`n"
    $smokeCode = ($smoke | Where-Object { $_ -notmatch '^#' }) -join "`n"
    $smokeCode.Replace(' nonacr -ValidateRuntimeOnly &', ' nonacr &') | Should -BeExactly $productionCode
    ([regex]::Matches($smokeCode, '-ValidateRuntimeOnly')).Count | Should -Be 1
  }
}
