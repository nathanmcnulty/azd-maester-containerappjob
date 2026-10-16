#Requires -Version 7.6
param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$CaddyPath,
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $Root 'scripts/Maester.ViewerContent.psm1') -Force
. (Join-Path $Root 'tests/helpers/MaesterViewerTemplateFixture.ps1')
$templateBytes=Get-MaesterViewerTestTemplateBytes
$expectedReport=[Text.Encoding]::UTF8.GetString((New-MaesterViewerQualifiedTestReport $templateBytes '{"Name":"old-snapshot","EndOfJson":"EndOfJson"}'))
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$checks = [Collections.Generic.List[string]]::new()
$processes = [Collections.Generic.List[Diagnostics.Process]]::new()
$stop = Join-Path $OutputDirectory 'worker.stop'
$ready = Join-Path $OutputDirectory 'worker.ready'
if ((Test-Path $stop) -or (Test-Path $ready)) { throw 'Use a new proxy validation output directory.' }
function Assert-Proxy([bool]$Value, [string]$Name) { if (-not$Value) { throw "Proxy validation failed: $Name" }; $checks.Add($Name) }
function Start-ProxyProcess([string]$File, [string[]]$Arguments, [string]$Name) {
    $info = [Diagnostics.ProcessStartInfo]::new($File); $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($info); $processes.Add($process); return $process
}
function Send-RawProxy([string]$Method, [string]$Target, [string]$Headers = '', [string]$Body = '') {
    $client = [Net.Sockets.TcpClient]::new(); $client.ReceiveTimeout = 3000; $client.SendTimeout = 3000
    try {
        $client.Connect('127.0.0.1', 8080); $stream = $client.GetStream()
        $request = "$Method $Target HTTP/1.1`r`nHost: synthetic.invalid`r`nConnection: close`r`n$Headers`r`n$Body"
        $bytes = [Text.Encoding]::ASCII.GetBytes($request); $stream.Write($bytes, 0, $bytes.Length)
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() }finally { $reader.Dispose() }
    }
    finally { $client.Dispose() }
}
$handler = [Net.Http.HttpClientHandler]::new(); $handler.UseProxy = $false; $handler.AllowAutoRedirect = $false
$http = [Net.Http.HttpClient]::new($handler, $true); $http.Timeout = [TimeSpan]::FromSeconds(3)
$result = [ordered]@{success = $false; checks = @(); cleanupVerified = $false }
try {
    foreach ($port in 8080, 8081, 2019) {
        $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $port)
        try { $probe.Start() }finally { $probe.Stop() }
    }
    $worker = Start-ProxyProcess (Get-Process -Id $PID).Path @('-NoLogo', '-NoProfile', '-File', (Join-Path $Root 'tests/helpers/Invoke-MaesterViewerWorkerFixture.ps1'), '-Case', 'valid', '-Root', $Root, '-Port', '8081', '-StopPath', $stop, '-ReadyPath', $ready) worker
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
    do {
        try { $response = $http.GetAsync('http://127.0.0.1:8081/report.html').GetAwaiter().GetResult(); $workerReady = [int]$response.StatusCode -eq 200; $response.Dispose() }catch { $workerReady = $false }
        if ($worker.HasExited) { throw 'Worker exited before proxy validation.' }; if (-not$workerReady) { Start-Sleep -Milliseconds 50 }
    }while (-not$workerReady -and [DateTimeOffset]::UtcNow -lt $deadline)
    if (-not$workerReady) { throw 'Worker startup deadline exceeded.' }
    $caddy = Start-ProxyProcess $CaddyPath @('run', '--config', $ConfigPath, '--adapter', 'caddyfile') caddy
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    do { try { $text = $http.GetStringAsync('http://127.0.0.1:8080/report.html').GetAwaiter().GetResult(); $proxyReady = $true }catch { $proxyReady = $false; Start-Sleep -Milliseconds 50 }; if ($caddy.HasExited) { throw 'Caddy exited before proxy validation.' } }while (-not$proxyReady -and [DateTimeOffset]::UtcNow -lt $deadline)
    Assert-Proxy ($proxyReady -and $text -ceq $expectedReport) 'Real Caddy forwards exact verified report bytes from the worker'
    $head = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Head, 'http://127.0.0.1:8080/report.html')
    try { $response = $http.SendAsync($head).GetAwaiter().GetResult(); try { Assert-Proxy ([int]$response.StatusCode -eq 200 -and $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult().Length -eq 0 -and $response.Content.Headers.ContentLength -gt 0) 'HEAD retains length and has no response body' }finally { $response.Dispose() } }finally { $head.Dispose() }
    foreach ($target in '/report.html?destination=https://example.invalid', '/%72eport.html', '/runs/secret/report.html', '/latest.json', '/Caddyfile', '/', '/config/') {
        $raw = Send-RawProxy GET $target
        Assert-Proxy ($raw -match '\AHTTP/1\.[01] 404 ' -and $raw -notmatch 'old-snapshot') "Raw route denied: $target"
    }
    $post = Send-RawProxy POST '/report.html'
    Assert-Proxy ($post -match '\AHTTP/1\.[01] 404 ' -and $post -notmatch 'old-snapshot') 'Non-read method denied before report proxy'
    $body = Send-RawProxy GET '/report.html' "Content-Length: 1`r`n" x
    Assert-Proxy ($body -match '\AHTTP/1\.[01] 400 ' -and $body -notmatch 'old-snapshot') 'Request body rejected by the worker through real Caddy'
    $forged = Send-RawProxy GET '/report.html' "Authorization: Bearer synthetic-only`r`nX-MS-CLIENT-PRINCIPAL: synthetic-only`r`nX-Forwarded-Host: example.invalid`r`nX-Forwarded-Proto: https`r`n"
    Assert-Proxy ($forged -match '\AHTTP/1\.[01] 200 ' -and $forged.Contains('old-snapshot') -and $forged -notmatch 'synthetic-only|example.invalid') 'Request host and headers do not change the fixed upstream or enter the response'
    foreach ($path in '/healthz', '/readyz') {
        $probe = $http.GetAsync("http://127.0.0.1:8080$path").GetAwaiter().GetResult()
        try { $content = $probe.Content.ReadAsStringAsync().GetAwaiter().GetResult(); Assert-Proxy ([int]$probe.StatusCode -eq 200 -and $content -notmatch 'old-snapshot|11111111|worker-test|Projection') "Minimal probe through Caddy: $path" }finally { $probe.Dispose() }
    }
    $admin = [Net.Sockets.TcpClient]::new(); try { $listening = $false; try { $admin.Connect('127.0.0.1', 2019); $listening = $true }catch {}; Assert-Proxy (-not$listening) 'Caddy admin listener is disabled' }finally { $admin.Dispose() }
    $result.success = $true
}
finally {
    Set-Content -LiteralPath $stop -Value stop -Encoding ascii
    foreach ($process in $processes) { if (-not$process.HasExited) { if ($process.Id -eq $worker.Id) { $null = $process.WaitForExit(8000) }; if (-not$process.HasExited) { $process.Kill($true); $null = $process.WaitForExit(5000) } }; $process.Dispose() }
    $http.Dispose()
    foreach ($port in 8080, 8081) { $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $port); try { $probe.Start() }finally { $probe.Stop() } }
    $result.cleanupVerified = $true; $result.checks = $checks.ToArray(); $result | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputDirectory 'proxy-result.json')
}
