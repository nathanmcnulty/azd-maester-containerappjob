#Requires -Version 7.6
BeforeAll {
  $script:viewerRoot = Split-Path $PSScriptRoot -Parent
  Import-Module (Join-Path $script:viewerRoot 'scripts/Maester.ViewerIdentity.psm1') -Force
  . (Join-Path $PSScriptRoot 'helpers/MaesterViewerTemplateFixture.ps1')
  $script:templateBytes=Get-MaesterViewerTestTemplateBytes
  if (-not ('MaesterIdentityTestHandler' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public sealed class MaesterIdentityPlan {
  public HttpStatusCode StatusCode { get; set; } = HttpStatusCode.OK;
  public byte[] Body { get; set; } = Array.Empty<byte>();
  public long? ContentLength { get; set; }
  public int DelayMilliseconds { get; set; }
  public bool StallBody { get; set; }
}
public sealed class MaesterIdentityRequest {
  public string Method { get; set; }
  public string Uri { get; set; }
  public Dictionary<string,string> Headers { get; set; }
}
public sealed class MaesterIdentityTestHandler : HttpMessageHandler {
  public Queue<MaesterIdentityPlan> Plans { get; } = new Queue<MaesterIdentityPlan>();
  public List<MaesterIdentityRequest> Requests { get; } = new List<MaesterIdentityRequest>();
  protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) {
    Requests.Add(new MaesterIdentityRequest { Method=request.Method.Method, Uri=request.RequestUri.AbsoluteUri,
      Headers=request.Headers.ToDictionary(h => h.Key, h => String.Join(",", h.Value), StringComparer.OrdinalIgnoreCase) });
    if (Plans.Count == 0) throw new InvalidOperationException("No plan.");
    MaesterIdentityPlan plan=Plans.Dequeue();
    if (plan.DelayMilliseconds > 0) await Task.Delay(plan.DelayMilliseconds, cancellationToken);
    var response=new HttpResponseMessage(plan.StatusCode); response.Content=plan.StallBody ? new MaesterIdentityStallingContent() : new ByteArrayContent(plan.Body);
    if (plan.ContentLength.HasValue) response.Content.Headers.ContentLength=plan.ContentLength.Value;
    return response;
  }
}
public sealed class MaesterIdentityStallingContent : HttpContent {
  protected override bool TryComputeLength(out long length) { length=0; return false; }
  protected override Task SerializeToStreamAsync(System.IO.Stream stream,TransportContext context) { return Task.Delay(Timeout.Infinite); }
  protected override Task<System.IO.Stream> CreateContentReadStreamAsync() { return Task.FromResult<System.IO.Stream>(new MaesterIdentityStallingStream()); }
  protected override Task<System.IO.Stream> CreateContentReadStreamAsync(CancellationToken cancellationToken) { return Task.FromResult<System.IO.Stream>(new MaesterIdentityStallingStream()); }
}
public sealed class MaesterIdentityStallingStream : System.IO.Stream {
  public override bool CanRead=>true; public override bool CanSeek=>false; public override bool CanWrite=>false;
  public override long Length=>throw new NotSupportedException(); public override long Position { get=>throw new NotSupportedException(); set=>throw new NotSupportedException(); }
  public override void Flush(){} public override long Seek(long offset,System.IO.SeekOrigin origin)=>throw new NotSupportedException();
  public override void SetLength(long value)=>throw new NotSupportedException(); public override void Write(byte[] buffer,int offset,int count)=>throw new NotSupportedException();
  public override int Read(byte[] buffer,int offset,int count)=>throw new NotSupportedException();
  public override async Task<int> ReadAsync(byte[] buffer,int offset,int count,CancellationToken cancellationToken){await Task.Delay(Timeout.Infinite,cancellationToken);return 0;}
  public override async ValueTask<int> ReadAsync(Memory<byte> buffer,CancellationToken cancellationToken=default){await Task.Delay(Timeout.Infinite,cancellationToken);return 0;}
}
public sealed class MaesterIdentityTestTimeProvider : TimeProvider {
  private long ticks;
  public MaesterIdentityTestTimeProvider(DateTimeOffset initial) { ticks=initial.UtcTicks; }
  public override DateTimeOffset GetUtcNow() { return new DateTimeOffset(Interlocked.Read(ref ticks),TimeSpan.Zero); }
  public void Advance(TimeSpan value) { Interlocked.Add(ref ticks,value.Ticks); }
}
'@
  }
  function New-TokenJson([string]$Token='opaque-token', [string]$ClientId='11111111-1111-1111-1111-111111111111', [string]$Resource='https://storage.azure.com/', [string]$Type='Bearer', [long]$ExpiresOn=0) {
    if (-not $ExpiresOn) { $ExpiresOn=[DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds() }
    [Text.Encoding]::UTF8.GetBytes((@{access_token=$Token;client_id=$ClientId;resource=$Resource;token_type=$Type;expires_on="$ExpiresOn"}|ConvertTo-Json -Compress))
  }
  function Add-IdentityPlan($Handler,[byte[]]$Body,[Net.HttpStatusCode]$Status='OK',$Length=$null,[int]$Delay=0,[switch]$StallBody) {
    $plan=[MaesterIdentityPlan]::new();$plan.Body=$Body;$plan.StatusCode=$Status;$plan.DelayMilliseconds=$Delay;$plan.StallBody=$StallBody
    if($null-ne$Length){$plan.ContentLength=[long]$Length};$Handler.Plans.Enqueue($plan)
  }
  function Use-IdentityEnvironment([string]$Endpoint='http://127.0.0.1:40342/msi/token',[string]$Header='platform-secret') {
    $env:IDENTITY_ENDPOINT=$Endpoint;$env:IDENTITY_HEADER=$Header
  }
  function Read-TestToken([Security.SecureString]$Token) {
    $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Token)
    try{[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)}
  }
}

Describe 'Container Apps user-assigned identity credential' {
  BeforeEach {
    $script:originalIdentityEndpoint=[Environment]::GetEnvironmentVariable('IDENTITY_ENDPOINT','Process')
    $script:originalIdentityHeader=[Environment]::GetEnvironmentVariable('IDENTITY_HEADER','Process')
    Use-IdentityEnvironment
  }
  AfterEach {
    [Environment]::SetEnvironmentVariable('IDENTITY_ENDPOINT',$script:originalIdentityEndpoint,'Process')
    [Environment]::SetEnvironmentVariable('IDENTITY_HEADER',$script:originalIdentityHeader,'Process')
  }

  It 'uses only the fixed storage request and exact rotating platform header' {
    $handler=[MaesterIdentityTestHandler]::new();Add-IdentityPlan $handler (New-TokenJson)
    $credential=New-MaesterContainerAppIdentityCredential -ClientId '11111111-1111-1111-1111-111111111111' -HttpMessageHandler $handler
    try {
      Read-TestToken ($credential.GetToken())|Should -BeExactly 'opaque-token'
      $handler.Requests.Count|Should -Be 1;$request=$handler.Requests[0]
      $request.Method|Should -BeExactly 'GET'
      $request.Uri|Should -BeExactly 'http://127.0.0.1:40342/msi/token?api-version=2019-08-01&resource=https%3A%2F%2Fstorage.azure.com%2F&client_id=11111111-1111-1111-1111-111111111111'
      $request.Headers['X-IDENTITY-HEADER']|Should -BeExactly 'platform-secret'
      $request.Headers.ContainsKey('Authorization')|Should -BeFalse
    } finally {$credential.Dispose();$handler.Dispose()}
  }

  It 'reuses one borrowed token only within the bounded cache lifetime then rereads the rotating header' {
    $handler=[MaesterIdentityTestHandler]::new();Add-IdentityPlan $handler (New-TokenJson -Token first);Add-IdentityPlan $handler (New-TokenJson -Token second)
    $clock=[MaesterIdentityTestTimeProvider]::new([DateTimeOffset]::UtcNow)
    $credential=New-MaesterContainerAppIdentityCredential -ClientId '11111111-1111-1111-1111-111111111111' -HttpMessageHandler $handler -TimeProvider $clock
    try {
      $first=$credential.GetToken();Read-TestToken $first|Should -BeExactly first
      $env:IDENTITY_HEADER='rotated';$clock.Advance([TimeSpan]::FromMinutes(9));Read-TestToken ($credential.GetToken())|Should -BeExactly first
      $clock.Advance([TimeSpan]::FromMinutes(2));Read-TestToken ($credential.GetToken())|Should -BeExactly second
      $handler.Requests.Count|Should -Be 2;$handler.Requests[1].Headers['X-IDENTITY-HEADER']|Should -BeExactly rotated
    } finally {$credential.Dispose();$handler.Dispose()}
  }

  It 'fails closed instead of returning an expired cached token when refresh fails' {
    $handler=[MaesterIdentityTestHandler]::new();Add-IdentityPlan $handler (New-TokenJson)
    $clock=[MaesterIdentityTestTimeProvider]::new([DateTimeOffset]::UtcNow)
    $credential=New-MaesterContainerAppIdentityCredential -ClientId '11111111-1111-1111-1111-111111111111' -HttpMessageHandler $handler -TimeProvider $clock
    try{$null=$credential.GetToken();$clock.Advance([TimeSpan]::FromMinutes(11));{$credential.GetToken()}|Should -Throw -ExpectedMessage '*Managed identity token acquisition failed.*'}finally{$credential.Dispose();$handler.Dispose()}
  }

  It 'requires the rotating platform header before dispatch' {
    Remove-Item Env:IDENTITY_HEADER -ErrorAction SilentlyContinue;$handler=[MaesterIdentityTestHandler]::new()
    $credential=New-MaesterContainerAppIdentityCredential -ClientId '11111111-1111-1111-1111-111111111111' -HttpMessageHandler $handler
    try{{$credential.GetToken()}|Should -Throw -ExpectedMessage '*Managed identity token acquisition failed.*';$handler.Requests.Count|Should -Be 0}finally{$credential.Dispose();$handler.Dispose()}
  }

  It 'fails before dispatch for invalid client or platform endpoint <endpoint>' -ForEach @(
    'https://127.0.0.1:40342/msi/token','http://example.com:40342/msi/token','http://127.0.0.1:40342/other',
    'http://user@127.0.0.1:40342/msi/token','http://127.0.0.1:40342/msi/token?secret=x','http://127.0.0.1:40342/msi/token#x'
  ) {
    Use-IdentityEnvironment -Endpoint $endpoint;$handler=[MaesterIdentityTestHandler]::new()
    $credential=New-MaesterContainerAppIdentityCredential -ClientId '11111111-1111-1111-1111-111111111111' -HttpMessageHandler $handler
    try{{$credential.GetToken()}|Should -Throw -ExpectedMessage '*Managed identity token acquisition failed.*';$handler.Requests.Count|Should -Be 0}finally{$credential.Dispose();$handler.Dispose()}
  }

  It 'fails closed for invalid response identity, resource, type, expiry, and token data' {
    $bodies=@(
      (New-TokenJson -ClientId '22222222-2222-2222-2222-222222222222'),
      (New-TokenJson -Resource 'https://management.azure.com/'),
      (New-TokenJson -Type bearer),
      (New-TokenJson -ExpiresOn ([DateTimeOffset]::UtcNow.AddMinutes(1).ToUnixTimeSeconds())),
      (New-TokenJson -Token "secret`nvalue")
    )
    foreach($body in $bodies){
      $handler=[MaesterIdentityTestHandler]::new();Add-IdentityPlan $handler $body
      $credential=New-MaesterContainerAppIdentityCredential -ClientId '11111111-1111-1111-1111-111111111111' -HttpMessageHandler $handler
      try{{$credential.GetToken()}|Should -Throw -ExpectedMessage '*Managed identity token acquisition failed.*'}finally{$credential.Dispose();$handler.Dispose()}
    }
  }

  It 'bounds status, body size, truncation, and total acquisition time' {
    $valid=New-TokenJson
    $cases=@(
      @{name='redirect';status=[Net.HttpStatusCode]::Redirect;body=[byte[]]::new(0);length=$null;delay=0},
      @{name='oversize';status=[Net.HttpStatusCode]::OK;body=[byte[]]::new(65537);length=$null;delay=0},
      @{name='declared oversize';status=[Net.HttpStatusCode]::OK;body=[byte[]](1);length=65537;delay=0},
      @{name='truncated';status=[Net.HttpStatusCode]::OK;body=$valid;length=65000;delay=0},
      @{name='timeout';status=[Net.HttpStatusCode]::OK;body=$valid;length=$null;delay=250}
    )
    foreach($case in $cases){
      $handler=[MaesterIdentityTestHandler]::new();Add-IdentityPlan $handler $case.body $case.status $case.length $case.delay
      $credential=New-MaesterContainerAppIdentityCredential -ClientId '11111111-1111-1111-1111-111111111111' -HttpMessageHandler $handler -AcquisitionTimeout $(if($case.name-eq'timeout'){[TimeSpan]::FromMilliseconds(30)}else{[TimeSpan]::FromSeconds(2)})
      try{{$credential.GetToken()}|Should -Throw -ExpectedMessage '*Managed identity token acquisition failed.*'}finally{$credential.Dispose();$handler.Dispose()}
    }
  }

  It 'applies the same acquisition deadline after response headers while the body stalls' {
    Use-IdentityEnvironment -Endpoint 'http://127.0.0.1:40342/msi/token' -Header 'rotating-secret'
    $handler=[MaesterIdentityTestHandler]::new();Add-IdentityPlan $handler ([byte[]]::new(0)) -StallBody
    $credential=New-MaesterContainerAppIdentityCredential -ClientId '11111111-1111-1111-1111-111111111111' -HttpMessageHandler $handler -AcquisitionTimeout ([TimeSpan]::FromMilliseconds(80))
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try {
      try{$credential.GetToken()|Out-Null;throw 'expected bounded failure'}catch{$watch.Stop();$text=$_|Out-String;$_.Exception.InnerException.Message|Should -BeExactly 'Managed identity token acquisition failed.';$text|Should -Not -Match 'rotating-secret|40342|msi/token'}
      $watch.Elapsed|Should -BeLessThan ([TimeSpan]::FromSeconds(2));$handler.Requests.Count|Should -Be 1
    } finally {$credential.Dispose();$handler.Dispose()}
  }

  It 'returns constant errors without endpoint header body or token data and rejects use after disposal' {
    Use-IdentityEnvironment -Header 'header-secret';$handler=[MaesterIdentityTestHandler]::new();Add-IdentityPlan $handler ([Text.Encoding]::UTF8.GetBytes('{"access_token":"token-secret"}'))
    $credential=New-MaesterContainerAppIdentityCredential -ClientId '11111111-1111-1111-1111-111111111111' -HttpMessageHandler $handler
    try{$credential.GetToken()|Out-Null}catch{$text=$_|Out-String;$_.Exception.InnerException.Message|Should -BeExactly 'Managed identity token acquisition failed.';$text|Should -Not -Match 'header-secret|token-secret|40342|msi/token'}
    $credential.Dispose();{$credential.GetToken()}|Should -Throw;$handler.Dispose()
  }

  It 'configures the production handler without ambient redirect proxy cookie or credentials' {
    InModuleScope Maester.ViewerIdentity {
      $handler=New-MaesterContainerAppIdentityHttpHandler
      try{$handler.AllowAutoRedirect|Should -BeFalse;$handler.UseProxy|Should -BeFalse;$handler.UseCookies|Should -BeFalse;$handler.UseDefaultCredentials|Should -BeFalse;$handler.Credentials|Should -BeNullOrEmpty;$handler.PreAuthenticate|Should -BeFalse}finally{$handler.Dispose()}
    }
  }
}

Describe 'Viewer identity entrypoint composition' {
  BeforeEach {
    $script:originalIdentityEndpoint=[Environment]::GetEnvironmentVariable('IDENTITY_ENDPOINT','Process')
    $script:originalIdentityHeader=[Environment]::GetEnvironmentVariable('IDENTITY_HEADER','Process')
    Use-IdentityEnvironment
  }
  AfterEach {
    [Environment]::SetEnvironmentVariable('IDENTITY_ENDPOINT',$script:originalIdentityEndpoint,'Process')
    [Environment]::SetEnvironmentVariable('IDENTITY_HEADER',$script:originalIdentityHeader,'Process')
  }

  It 'rejects every invalid target setting before identity dispatch or listener creation' {
    $cases=@(
      @{name='storage';StorageAccountName='Bad_account'},@{name='container';ProjectionContainerName='Bad_Container'},
      @{name='tenant';TenantId='missing'},@{name='environment';Environment='bad environment'},
      @{name='identity';UserAssignedIdentityClientId='00000000-0000-0000-0000-000000000000'}
    )
    foreach($case in $cases){
      $probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);try{$probe.Start();$port=$probe.LocalEndpoint.Port}finally{$probe.Stop()}
      $handler=[MaesterIdentityTestHandler]::new();$cts=[Threading.CancellationTokenSource]::new();$cts.Cancel()
      $settings=@{StorageAccountName='vieweraccount';ProjectionContainerName='viewer-projection';TenantId='22222222-2222-2222-2222-222222222222';Environment='test';UserAssignedIdentityClientId='11111111-1111-1111-1111-111111111111';TemplateBytes=$script:templateBytes}
      foreach($key in $case.Keys){if($key-ne'name'){$settings[$key]=$case[$key]}}
      try {
        {Start-MaesterViewerEntrypoint @settings -Port $port -CancellationToken $cts.Token -IdentityHttpMessageHandler $handler}|Should -Throw
        $handler.Requests.Count|Should -Be 0
        $verify=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port);try{$verify.Start();$verify.LocalEndpoint.Port|Should -Be $port}finally{$verify.Stop()}
      } finally {$cts.Dispose();$handler.Dispose()}
    }
  }

  It 'runs the composed entrypoint in a clean process and releases its loopback port' {
    $probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);try{$probe.Start();$port=$probe.LocalEndpoint.Port}finally{$probe.Stop()}
    $ready=Join-Path $TestDrive 'identity-entrypoint.ready';$stop=Join-Path $TestDrive 'identity-entrypoint.stop'
    $fixture=Join-Path $PSScriptRoot 'helpers/Invoke-MaesterViewerIdentityFixture.ps1';$process=$null;$client=$null
    try {
      $info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$info.UseShellExecute=$false;$info.CreateNoWindow=$true
      foreach($argument in @('-NoLogo','-NoProfile','-File',$fixture,'-Root',$script:viewerRoot,'-Port',"$port",'-ReadyPath',$ready,'-StopPath',$stop)){$info.ArgumentList.Add($argument)}
      $process=[Diagnostics.Process]::Start($info);$deadline=[DateTimeOffset]::UtcNow.AddSeconds(8)
      while(-not(Test-Path $ready)-and[DateTimeOffset]::UtcNow-lt$deadline){if($process.HasExited){throw 'Entrypoint fixture exited.'};Start-Sleep -Milliseconds 20}
      $httpHandler=[Net.Http.HttpClientHandler]::new();$httpHandler.UseProxy=$false;$client=[Net.Http.HttpClient]::new($httpHandler,$true);$client.Timeout=[TimeSpan]::FromSeconds(2)
      do{try{$response=$client.GetAsync("http://127.0.0.1:$port/healthz").GetAwaiter().GetResult();$status=[int]$response.StatusCode;$response.Dispose()}catch{$status=0;Start-Sleep -Milliseconds 20}}while($status-ne 200-and[DateTimeOffset]::UtcNow-lt$deadline)
      $status|Should -Be 200
      $response=$client.GetAsync("http://127.0.0.1:$port/readyz").GetAwaiter().GetResult();try{[int]$response.StatusCode|Should -Be 503}finally{$response.Dispose()}
      Set-Content -LiteralPath $stop -Value stop -Encoding ascii;$process.WaitForExit(8000)|Should -BeTrue;$process.ExitCode|Should -Be 0
    } finally {
      if($client){$client.Dispose()};if($process){if(-not$process.HasExited){try{$process.Kill($true);$null=$process.WaitForExit(5000)}catch{}};$process.Dispose()}
    }
    $verify=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port);try{$verify.Start();$verify.LocalEndpoint.Port|Should -Be $port}finally{$verify.Stop()}
  }

  It 'executes the runnable script and rejects invalid settings before metadata contact or listener creation' {
    $canary=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$canary.Start();$canaryPort=$canary.LocalEndpoint.Port;$accept=$canary.AcceptTcpClientAsync()
    $probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);try{$probe.Start();$viewerPort=$probe.LocalEndpoint.Port}finally{$probe.Stop()}
    $env:IDENTITY_ENDPOINT="http://127.0.0.1:$canaryPort/msi/token";$env:IDENTITY_HEADER='metadata-canary-secret'
    $process=$null
    try {
      $scriptPath=Join-Path $script:viewerRoot 'scripts/Start-MaesterViewer.ps1';$info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardError=$true;$info.RedirectStandardOutput=$true
      foreach($argument in @('-NoLogo','-NoProfile','-File',$scriptPath,'-StorageAccountName','vieweraccount','-ProjectionContainerName','viewer-projection','-TenantId','invalid','-Environment','test','-UserAssignedIdentityClientId','11111111-1111-1111-1111-111111111111','-Port',"$viewerPort")){$info.ArgumentList.Add($argument)}
      $process=[Diagnostics.Process]::Start($info);$process.WaitForExit(8000)|Should -BeTrue;$process.ExitCode|Should -Not -Be 0
      $output=$process.StandardOutput.ReadToEnd()+$process.StandardError.ReadToEnd();$output|Should -Not -Match 'metadata-canary-secret'
      $accept.IsCompleted|Should -BeFalse
      $verify=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$viewerPort);try{$verify.Start();$verify.LocalEndpoint.Port|Should -Be $viewerPort}finally{$verify.Stop()}
    } finally {if($process){if(-not$process.HasExited){$process.Kill($true);$null=$process.WaitForExit(5000)};$process.Dispose()};$canary.Stop()}
  }

  It 'cancels the native process owner from SIGTERM on Linux or safely constructs it on Windows' {
    if($IsWindows){$owner=[MaesterViewerProcessCancellation]::new();try{$owner.Token.IsCancellationRequested|Should -BeFalse}finally{$owner.Dispose()};return}
    $ready=Join-Path $TestDrive 'signal-owner.ready';$fixture=Join-Path $PSScriptRoot 'helpers/Invoke-MaesterViewerIdentityFixture.ps1';$process=$null
    try {
      $info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$info.UseShellExecute=$false
      foreach($argument in @('-NoLogo','-NoProfile','-File',$fixture,'-Mode','SignalOwner','-Root',$script:viewerRoot,'-Port','1','-ReadyPath',$ready,'-StopPath',(Join-Path $TestDrive 'unused.stop'))){$info.ArgumentList.Add($argument)}
      $process=[Diagnostics.Process]::Start($info);$deadline=[DateTimeOffset]::UtcNow.AddSeconds(8)
      while(-not(Test-Path $ready)-and[DateTimeOffset]::UtcNow-lt$deadline){if($process.HasExited){throw 'Signal fixture exited before ready.'};Start-Sleep -Milliseconds 20}
      & /bin/kill -TERM $process.Id;if($LASTEXITCODE){throw 'kill failed'};$process.WaitForExit(8000)|Should -BeTrue;$process.ExitCode|Should -Be 0
    } finally {if($process){if(-not$process.HasExited){$process.Kill($true);$null=$process.WaitForExit(5000)};$process.Dispose()}}
  }
}
