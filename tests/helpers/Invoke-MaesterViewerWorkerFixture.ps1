#Requires -Version 7.6
param(
    [Parameter(Mandatory)][ValidateSet('valid', 'missing', 'corruptRefresh', 'switchSnapshot', 'future', 'expire', 'slowClient')][string]$Case,
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][string]$StopPath,
    [Parameter(Mandatory)][string]$ReadyPath
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $Root 'scripts/Maester.ViewerWorker.psm1') -Force
Import-Module (Join-Path $Root 'scripts/Maester.ViewerProjection.psm1') -Force

if (-not ('MaesterViewerFixtureStop' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
public sealed class MaesterViewerManualTimeProvider : TimeProvider {
    private long utcTicks;
    public MaesterViewerManualTimeProvider(DateTimeOffset initialUtc) { utcTicks = initialUtc.UtcTicks; }
    public override DateTimeOffset GetUtcNow() { return new DateTimeOffset(Interlocked.Read(ref utcTicks), TimeSpan.Zero); }
    public void SetUtcNow(DateTimeOffset value) { Interlocked.Exchange(ref utcTicks, value.UtcTicks); }
    public void Advance(TimeSpan value) { Interlocked.Add(ref utcTicks, value.Ticks); }
}

public static class MaesterViewerFixtureStop {
  public static Task Watch(string path, CancellationTokenSource source) {
    return Task.Run(async () => { while (!source.IsCancellationRequested && !File.Exists(path)) await Task.Delay(20); source.Cancel(); });
  }
}
'@
}

function New-FixtureStore {
    $state = [pscustomobject]@{ Items = @{}; Counter = 0; LatestReads = 0; Before = $null; Transitioned = $false }
    $store = {
        param($Operation, $Key, [byte[]]$Bytes, $ContentType, $IfMatch, $IfNoneMatch, $MaximumBytes)
        if ($state.Before) {
            $override = & $state.Before $state $Operation $Key
            if ($null -ne $override) { return $override }
        }
        if ($Operation -eq 'Get') {
            if (-not $state.Items.ContainsKey($Key)) { return [pscustomobject]@{status = 'missing'; etag = $null; bytes = $null } }
            $item = $state.Items[$Key]; return [pscustomobject]@{status = 'found'; etag = $item.etag; bytes = [byte[]]$item.bytes.Clone() }
        }
        $existing = $state.Items[$Key]
        if (($IfNoneMatch -eq '*' -and $existing) -or ($IfMatch -and (-not $existing -or $existing.etag -cne $IfMatch))) {
            return [pscustomobject]@{status = 'preconditionFailed'; etag = $null }
        }
        $state.Counter++; $etag = '"fixture-{0}"' -f $state.Counter
        $state.Items[$Key] = [pscustomobject]@{bytes = [byte[]]$Bytes.Clone(); etag = $etag; contentType = $ContentType }
        [pscustomobject]@{status = 'created'; etag = $etag }
    }.GetNewClosure()
    [pscustomobject]@{State = $state; Store = $store }
}

$tenant = '11111111-1111-1111-1111-111111111111'; $environment = 'worker-test'
$run1 = '22222222-2222-2222-2222-222222222222'; $run2 = '33333333-3333-3333-3333-333333333333'
$now = [DateTimeOffset]'2026-10-15T23:00:00Z'
$manual = [MaesterViewerManualTimeProvider]::new($now)
$workerModule = Get-Module Maester.ViewerWorker
& $workerModule { param($provider) $script:MaesterViewerTimeProvider = $provider } $manual
$fixture = New-FixtureStore
$old = [Text.Encoding]::UTF8.GetBytes('<html><body>old-snapshot</body></html>')
$new = [Text.Encoding]::UTF8.GetBytes('<html><body>new-snapshot</body></html>')
if ($Case -eq 'slowClient') {
    $old = [byte[]]::new(20MB)
    [Array]::Fill[byte]($old, [byte]120)
    [Text.Encoding]::ASCII.GetBytes('<html>').CopyTo($old, 0)
    [Text.Encoding]::ASCII.GetBytes('</html>').CopyTo($old, $old.Length - 7)
}
if ($Case -ne 'missing') {
    $started = if ($Case -eq 'future') { $now.AddMinutes(1) } else { $now.AddMinutes(-5) }
    $null = Publish-MaesterViewerProjection -HtmlBytes $old -TenantId $tenant -Environment $environment -RunId $run1 -RunStartedAtUtc $started -Store $fixture.Store
}
if ($Case -eq 'future') {
    $fixture.State.Before = {
        param($state, $operation, $key)
        if ($operation -eq 'Get' -and $key -eq 'latest.json') {
            $state.LatestReads++
            if ($state.LatestReads -ge 3) {
                if ($state.LatestReads -eq 3) {
                    # The first full read/worker cycle completed. Move beyond the future
                    # generation while preventing another install: a wrongly retained
                    # future snapshot would now become visible to the HTTP test.
                    $manual.Advance([TimeSpan]::FromMinutes(2))
                    Set-Content -LiteralPath "$ReadyPath.future-read" -Value 'post-cycle-clock-advanced'
                }
                return [pscustomobject]@{status='missing';etag=$null;bytes=$null}
            }
        }
    }.GetNewClosure()
}
elseif ($Case -eq 'corruptRefresh') {
    $fixture.State.Before = {
        param($state, $operation, $key)
        if ($operation -eq 'Get' -and $key -eq 'latest.json') { $state.LatestReads++ }
        if ($state.LatestReads -ge 3 -and $operation -eq 'Get' -and $key -eq "runs/$run1/report.html") {
            return [pscustomobject]@{status = 'found'; etag = '"corrupt"'; bytes = [Text.Encoding]::UTF8.GetBytes('<html>corrupt</html>') }
        }
    }
}
elseif ($Case -eq 'switchSnapshot') {
    $newer = New-FixtureStore
    $null = Publish-MaesterViewerProjection -HtmlBytes $new -TenantId $tenant -Environment $environment -RunId $run2 -RunStartedAtUtc $now.AddMinutes(-1) -Store $newer.Store
    $fixture.State.Before = {
        param($state, $operation, $key)
        if ($operation -eq 'Get' -and $key -eq 'latest.json') {
            $state.LatestReads++
            if (-not $state.Transitioned -and (Test-Path "$ReadyPath.advance")) {
                foreach ($entry in $newer.State.Items.GetEnumerator()) { $state.Items[$entry.Key] = $entry.Value }
                $state.Transitioned = $true
            }
        }
    }.GetNewClosure()
}
elseif ($Case -eq 'expire') {
    $fixture.State.Before = {
        param($state, $operation, $key)
        if ($operation -eq 'Get' -and $key -eq 'latest.json') {
            $state.LatestReads++
            if (-not $state.Transitioned -and (Test-Path "$ReadyPath.advance")) {
                $manual.Advance([TimeSpan]::FromMinutes(10))
                $state.Transitioned = $true
            }
        }
    }.GetNewClosure()
}

$cts = [Threading.CancellationTokenSource]::new()
$watch = [MaesterViewerFixtureStop]::Watch($StopPath, $cts)
Set-Content -LiteralPath $ReadyPath -Value 'fixture-ready' -Encoding ascii
try {
    $poll = if ($Case -eq 'slowClient') { [TimeSpan]::FromSeconds(30) } else { [TimeSpan]::FromMilliseconds(150) }
    $concurrent = if ($Case -eq 'slowClient') { 1 } else { 8 }
    Start-MaesterViewerWorker -TenantId $tenant -Environment $environment -Store $fixture.Store -Port $Port `
        -PollInterval $poll -MaximumReportAge ([TimeSpan]::FromMinutes(10)) `
        -ClientWriteTimeout ([TimeSpan]::FromSeconds(1)) -MaximumConcurrentRequests $concurrent -CancellationToken $cts.Token
}
finally { $cts.Cancel(); try { $null = $watch.GetAwaiter().GetResult() }catch {}; $cts.Dispose() }
