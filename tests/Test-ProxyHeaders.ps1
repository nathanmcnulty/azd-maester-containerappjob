#Requires -Version 7.6
param([Parameter(Mandatory)][string]$CaddyPath, [Parameter(Mandatory)][string]$ConfigPath, [Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$null = New-Item -ItemType Directory -Path $OutputDirectory
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
public sealed class MaesterProxyHeaderCapture : IDisposable {
    private readonly TcpListener listener = new TcpListener(IPAddress.Loopback, 8081);
    private readonly CancellationTokenSource stop = new CancellationTokenSource(TimeSpan.FromSeconds(15));
    public Task<string> Capture {get;private set;}
    public void Start() { listener.Start(); Capture = CaptureAsync(); }
    private async Task<string> CaptureAsync() {
        using var client = await listener.AcceptTcpClientAsync(stop.Token);
        using var stream = client.GetStream();
        using var headers = new MemoryStream();
        var next = new byte[1];
        while (headers.Length < 8192) {
            if (await stream.ReadAsync(next, stop.Token) != 1) throw new IOException("Incomplete synthetic request.");
            headers.WriteByte(next[0]);
            if (headers.Length >= 4) {
                var bytes = headers.GetBuffer(); var n = (int)headers.Length;
                if (bytes[n-4] == 13 && bytes[n-3] == 10 && bytes[n-2] == 13 && bytes[n-1] == 10) {
                    var response = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 9\r\nConnection: close\r\n\r\nsynthetic");
                    await stream.WriteAsync(response, stop.Token);
                    await stream.FlushAsync(stop.Token);
                    if (await stream.ReadAsync(next, stop.Token) != 0) throw new IOException("Unexpected synthetic request bytes after the response.");
                    return Encoding.ASCII.GetString(headers.ToArray());
                }
            }
        }
        throw new IOException("Synthetic request headers exceeded limit.");
    }
    public void Dispose() { stop.Cancel(); listener.Stop(); if (Capture != null) { try { Capture.Wait(TimeSpan.FromSeconds(2)); } catch {} } stop.Dispose(); }
}
'@
$capture = [MaesterProxyHeaderCapture]::new()
$proxyCanary = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$caddy = $null
try {
    foreach ($port in 8080, 2019) {
        $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $port)
        $probe.Server.ExclusiveAddressUse = $true
        try { $probe.Start() } finally { $probe.Stop() }
    }
    $capture.Start(); $proxyCanary.Start()
    $info = [Diagnostics.ProcessStartInfo]::new($CaddyPath); $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    foreach ($argument in @('run', '--config', $ConfigPath, '--adapter', 'caddyfile')) { $info.ArgumentList.Add($argument) }
    $info.Environment['HTTP_PROXY'] = "http://127.0.0.1:$($proxyCanary.LocalEndpoint.Port)"
    $info.Environment['HTTPS_PROXY'] = $info.Environment['HTTP_PROXY']; $info.Environment['NO_PROXY'] = ''
    $caddy = [Diagnostics.Process]::Start($info)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
    do {
        $probe = [Net.Sockets.TcpClient]::new()
        try { $probe.Connect('127.0.0.1', 8080); $listening = $true }catch { $listening = $false; Start-Sleep -Milliseconds 30 }finally { $probe.Dispose() }
        if ($caddy.HasExited) { throw 'Caddy exited before synthetic header capture.' }
    }while (-not$listening -and [DateTimeOffset]::UtcNow -lt $deadline)
    if (-not$listening) { throw 'Caddy startup deadline exceeded.' }
    $client = [Net.Sockets.TcpClient]::new(); $client.ReceiveTimeout = 3000; $client.SendTimeout = 3000
    try {
        $client.Connect('127.0.0.1', 8080); $stream = $client.GetStream()
        $request = "GET /report.html HTTP/1.1`r`nHost: attacker.invalid`r`nAuthorization: Bearer synthetic-only`r`nCookie: synthetic-only`r`nX-MS-CLIENT-PRINCIPAL: synthetic-only`r`nX-Forwarded-For: 192.0.2.1`r`nX-Forwarded-Host: attacker.invalid`r`nX-Forwarded-Proto: https`r`nAccept-Encoding: gzip`r`nConnection: close`r`n`r`n"
        $bytes = [Text.Encoding]::ASCII.GetBytes($request); $stream.Write($bytes, 0, $bytes.Length)
        $reader = [IO.StreamReader]::new($stream)
        try { $response = $reader.ReadToEnd(); if ($response -notmatch '\AHTTP/1\.[01] 200 ') { throw 'Synthetic upstream response not returned.' } }finally { $reader.Dispose() }
    }
    finally { $client.Dispose() }
    $raw = $capture.Capture.GetAwaiter().GetResult()
    $raw | Set-Content (Join-Path $OutputDirectory 'synthetic-upstream-request.txt')
    $lines = $raw.Split("`r`n", [StringSplitOptions]::RemoveEmptyEntries)
    if ($lines[0] -cne 'GET /report.html HTTP/1.1') { throw 'Unexpected upstream request target.' }
    $headers = @($lines | Select-Object -Skip 1)
    if ($headers.Count -ne 1 -or $headers[0] -cne 'Host: 127.0.0.1:8081') { throw 'Unexpected upstream header allowlist.' }
    if ($proxyCanary.Pending()) { throw 'Environment proxy was contacted.' }
    [ordered]@{success = $true; requestLine = $lines[0]; headers = $headers; environmentProxyContacted = $false } | ConvertTo-Json | Set-Content (Join-Path $OutputDirectory 'header-result.json')
}
finally {
    if ($caddy) { if (-not$caddy.HasExited) { $caddy.Kill($true); $null = $caddy.WaitForExit(5000) }; $caddy.Dispose() }
    $capture.Dispose(); $proxyCanary.Stop()
    foreach ($port in 8080, 8081, 2019) { $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $port); $probe.Server.ExclusiveAddressUse = $true; try { $probe.Start() }finally { $probe.Stop() } }
}
