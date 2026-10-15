#Requires -Version 7.6
param(
  [ValidateSet('Entrypoint','SignalOwner')][string]$Mode='Entrypoint',
  [Parameter(Mandatory)][string]$Root,
  [Parameter(Mandatory)][int]$Port,
  [Parameter(Mandatory)][string]$ReadyPath,
  [Parameter(Mandatory)][string]$StopPath
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $Root 'scripts/Maester.ViewerIdentity.psm1') -Force
if($Mode-eq'SignalOwner'){
  $owner=[MaesterViewerProcessCancellation]::new()
  try{Set-Content -LiteralPath $ReadyPath -Value ready -Encoding ascii;if(-not$owner.Token.WaitHandle.WaitOne([TimeSpan]::FromSeconds(15))){exit 2};exit 0}finally{$owner.Dispose()}
}
if(-not('MaesterViewerIdentityFixtureHandler'-as[type])){Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
public sealed class MaesterViewerIdentityFixtureHandler : HttpMessageHandler {
  private readonly bool identity;
  public MaesterViewerIdentityFixtureHandler(bool identity) { this.identity=identity; }
  protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancellationToken) {
    var response=new HttpResponseMessage(identity ? HttpStatusCode.OK : HttpStatusCode.NotFound);
    string body=identity ? "{\"access_token\":\"fixture-token\",\"expires_on\":\"4102444800\",\"resource\":\"https://storage.azure.com/\",\"token_type\":\"Bearer\",\"client_id\":\"11111111-1111-1111-1111-111111111111\"}" : "missing";
    response.Content=new ByteArrayContent(Encoding.UTF8.GetBytes(body)); return Task.FromResult(response);
  }
}
public static class MaesterViewerIdentityFixtureStop {
  public static Task Watch(string path,CancellationTokenSource source){return Task.Run(async()=>{while(!source.IsCancellationRequested&&!System.IO.File.Exists(path))await Task.Delay(20);source.Cancel();});}
}
'@}
$env:IDENTITY_ENDPOINT='http://127.0.0.1:40342/msi/token';$env:IDENTITY_HEADER='fixture-header'
$cts=[Threading.CancellationTokenSource]::new();$watch=[MaesterViewerIdentityFixtureStop]::Watch($StopPath,$cts)
$identity=[MaesterViewerIdentityFixtureHandler]::new($true);$projection=[MaesterViewerIdentityFixtureHandler]::new($false)
Set-Content -LiteralPath $ReadyPath -Value ready -Encoding ascii
try {
  Start-MaesterViewerEntrypoint -StorageAccountName vieweraccount -ProjectionContainerName viewer-projection `
    -TenantId '22222222-2222-2222-2222-222222222222' -Environment fixture `
    -UserAssignedIdentityClientId '11111111-1111-1111-1111-111111111111' -Port $Port `
    -PollInterval ([TimeSpan]::FromMilliseconds(100)) -CancellationToken $cts.Token `
    -IdentityHttpMessageHandler $identity -ProjectionHttpMessageHandler $projection
} finally {
  $cts.Cancel();try{$null=$watch.GetAwaiter().GetResult()}catch{};$identity.Dispose();$projection.Dispose();$cts.Dispose()
}
