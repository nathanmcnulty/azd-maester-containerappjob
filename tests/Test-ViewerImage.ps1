#Requires -Version 7.6
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$WorkerImage,
  [Parameter(Mandatory)][string]$CaddyImage,
  [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
if(Test-Path $OutputDirectory){throw 'Output directory must be new.'}
$null=New-Item -ItemType Directory -Path $OutputDirectory
$suffix=[guid]::NewGuid().ToString('N').Substring(0,12)
$metadata="viewer-metadata-$suffix";$worker="viewer-worker-$suffix";$proxy="viewer-caddy-$suffix"
$records=[Collections.Generic.List[object]]::new()
function Invoke-Docker {
  param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments,[switch]$AllowFailure)
  $output=& docker @Arguments 2>&1;$exit=$LASTEXITCODE
  if(-not$AllowFailure-and$exit){throw "Docker command failed: $($Arguments[0])"}
  [pscustomobject]@{ExitCode=$exit;Output=($output-join"`n")}
}
function Add-Record([string]$Name,$Value){$records.Add([pscustomobject]@{name=$Name;value=$Value})}
function Assert-Equal($Actual,$Expected,[string]$Name){if($Actual-cne$Expected){throw "$Name did not match."}}
function Assert-Match([string]$Actual,[string]$Pattern,[string]$Name){if($Actual-cnotmatch$Pattern){throw "$Name did not match."}}
function Assert-Sequence($Actual,$Expected,[string]$Name){if(($Actual-join"`0")-cne($Expected-join"`0")){throw "$Name did not match."}}
try {
  $workerInspect=(Invoke-Docker @('image','inspect',$WorkerImage)).Output|ConvertFrom-Json
  $caddyInspect=(Invoke-Docker @('image','inspect',$CaddyImage)).Output|ConvertFrom-Json
  $workerImageId=[string]$workerInspect[0].Id;$caddyImageId=[string]$caddyInspect[0].Id
  Assert-Match $workerImageId '^sha256:[0-9a-f]{64}$' workerImageId;Assert-Match $caddyImageId '^sha256:[0-9a-f]{64}$' caddyImageId
  Assert-Equal $workerInspect[0].Config.User '65532:65532' workerUser;Assert-Equal $caddyInspect[0].Config.User '65532:65532' caddyUser
  Assert-Sequence $workerInspect[0].Config.Entrypoint @('/opt/microsoft/powershell/7/pwsh','-NoLogo','-NoProfile','-NonInteractive','-File','/opt/maester-viewer/scripts/Start-MaesterViewer.ps1') workerEntrypoint
  Assert-Sequence $caddyInspect[0].Config.Entrypoint @('/usr/local/bin/caddy','run','--config','/etc/caddy/Caddyfile','--adapter','caddyfile') caddyEntrypoint
  $version=(Invoke-Docker @('run','--rm','--entrypoint','/opt/microsoft/powershell/7/pwsh',$WorkerImage,'-NoLogo','-NoProfile','-Command','$PSVersionTable.PSVersion.ToString()')).Output.Trim();Assert-Equal $version '7.6.6' powerShellVersion
  Assert-Equal (Invoke-Docker @('run','--rm','--entrypoint','/usr/bin/id',$WorkerImage,'-u')).Output.Trim() '65532' workerRuntimeUser
  Assert-Match (Invoke-Docker @('run','--rm','--entrypoint','/usr/local/bin/caddy',$CaddyImage,'version')).Output '^v2\.11\.7 ' caddyVersion
  $null=Invoke-Docker @('run','--rm','--read-only','--tmpfs','/tmp:rw,noexec,nosuid,nodev,size=16m','--cap-drop','ALL','--security-opt','no-new-privileges','--entrypoint','/usr/local/bin/caddy',$CaddyImage,'validate','--config','/etc/caddy/Caddyfile','--adapter','caddyfile')

  $identity=@'
{
  admin off
  persist_config off
  auto_https off
}
http://127.0.0.1:40342 {
  respond `{"access_token":"smoke-token","expires_on":"4102444800","resource":"https://storage.azure.com/","token_type":"Bearer","client_id":"11111111-1111-1111-1111-111111111111"}` 200
}
'@
  $identityPath=Join-Path $OutputDirectory 'identity.Caddyfile';[IO.File]::WriteAllText($identityPath,$identity,[Text.UTF8Encoding]::new($false))
  $mount="$($identityPath):/test/identity.Caddyfile:ro"
  $null=Invoke-Docker @('run','--detach','--name',$metadata,'--network','none','--read-only','--tmpfs','/tmp:rw,noexec,nosuid,nodev,size=16m','--cap-drop','ALL','--security-opt','no-new-privileges','--volume',$mount,'--entrypoint','/usr/local/bin/caddy',$CaddyImage,'run','--config','/test/identity.Caddyfile','--adapter','caddyfile')
  $null=Invoke-Docker @('run','--detach','--name',$worker,'--network',"container:$metadata",'--read-only','--tmpfs','/tmp:rw,nosuid,nodev,size=64m','--cap-drop','ALL','--security-opt','no-new-privileges','--env','IDENTITY_ENDPOINT=http://127.0.0.1:40342/msi/token','--env','IDENTITY_HEADER=smoke-header',$WorkerImage,'-StorageAccountName','vieweraccount','-ProjectionContainerName','viewer-projection','-TenantId','22222222-2222-2222-2222-222222222222','-Environment','smoke','-UserAssignedIdentityClientId','11111111-1111-1111-1111-111111111111','-PollIntervalSeconds','1','-MaximumReportAgeSeconds','60')
  $null=Invoke-Docker @('run','--detach','--name',$proxy,'--network',"container:$metadata",'--read-only','--tmpfs','/tmp:rw,noexec,nosuid,nodev,size=16m','--cap-drop','ALL','--security-opt','no-new-privileges',$CaddyImage)
  $deadline=[DateTimeOffset]::UtcNow.AddSeconds(20);$status=$null
  do {
    $query=Invoke-Docker @('exec',$worker,'/opt/microsoft/powershell/7/pwsh','-NoLogo','-NoProfile','-Command','$c=[Net.Http.HttpClient]::new();try{$c.Timeout=[TimeSpan]::FromSeconds(2);$r=$c.GetAsync("http://127.0.0.1:8080/healthz").GetAwaiter().GetResult();[int]$r.StatusCode}catch{0}finally{$c.Dispose()}') -AllowFailure
    $status=($query.Output.Trim()-split"`n")[-1];if($status-ne'200'){Start-Sleep -Milliseconds 200}
  }while($status-ne'200'-and[DateTimeOffset]::UtcNow-lt$deadline)
  Assert-Equal $status '200' healthStatus
  $report=(Invoke-Docker @('exec',$worker,'/opt/microsoft/powershell/7/pwsh','-NoLogo','-NoProfile','-Command','$c=[Net.Http.HttpClient]::new();try{$c.Timeout=[TimeSpan]::FromSeconds(2);$r=$c.GetAsync("http://127.0.0.1:8080/report.html").GetAwaiter().GetResult();[int]$r.StatusCode}finally{$c.Dispose()}')).Output.Trim();Assert-Equal ($report-split"`n")[-1] '503' reportStatus
  Assert-Equal (Invoke-Docker @('exec',$worker,'/usr/bin/id','-u')).Output.Trim() '65532' workerEffectiveUser
  Assert-Equal (Invoke-Docker @('exec',$proxy,'/usr/bin/id','-u')).Output.Trim() '65532' caddyEffectiveUser
  Assert-Equal (Invoke-Docker @('exec',$worker,'/usr/bin/cat','/proc/1/comm')).Output.Trim() 'pwsh' workerPid1
  Assert-Equal (Invoke-Docker @('exec',$proxy,'/usr/bin/cat','/proc/1/comm')).Output.Trim() 'caddy' caddyPid1
  $null=Invoke-Docker @('stop','--time','20',$worker);Assert-Equal ([int](Invoke-Docker @('inspect','--format','{{.State.ExitCode}}',$worker)).Output.Trim()) 0 workerExit
  $null=Invoke-Docker @('stop','--time','20',$proxy);Assert-Equal ([int](Invoke-Docker @('inspect','--format','{{.State.ExitCode}}',$proxy)).Output.Trim()) 0 caddyExit
  Add-Record workerImageId $workerImageId;Add-Record caddyImageId $caddyImageId;Add-Record imageUser '65532:65532';Add-Record powerShell $version;Add-Record healthStatus 200;Add-Record reportStatus 503;Add-Record workerExit 0;Add-Record caddyExit 0
  $records|ConvertTo-Json -Depth 4|Set-Content (Join-Path $OutputDirectory 'result.json') -Encoding utf8
} catch {
  foreach($item in @(@{Name=$worker;File='worker.log'},@{Name=$proxy;File='caddy.log'})){
    if((Invoke-Docker @('inspect',$item.Name) -AllowFailure).ExitCode-eq 0){
      (Invoke-Docker @('logs',$item.Name) -AllowFailure).Output|Set-Content (Join-Path $OutputDirectory $item.File) -Encoding utf8
    }
  }
  throw
} finally {
  foreach($name in $proxy,$worker,$metadata){$null=Invoke-Docker @('rm','--force',$name) -AllowFailure}
  foreach($name in $proxy,$worker,$metadata){if((Invoke-Docker @('inspect',$name) -AllowFailure).ExitCode-eq 0){throw 'Owned container cleanup failed.'}}
}

# Expected negative cleanup probes must not become the caller's native exit status.
$global:LASTEXITCODE=0
