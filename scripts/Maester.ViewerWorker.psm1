#Requires -Version 7.6
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Maester.ViewerProjection.psm1') -Force

if (-not ('MaesterViewerLoopbackServer' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public sealed class MaesterViewerSnapshot {
    internal byte[] HtmlBytes { get; }
    public string RunId { get; }
    public string Generation { get; }
    public DateTimeOffset RunStartedAtUtc { get; }
    public MaesterViewerSnapshot(byte[] htmlBytes, string runId, string generation, DateTimeOffset runStartedAtUtc) {
        HtmlBytes = (byte[])htmlBytes.Clone(); RunId = runId; Generation = generation; RunStartedAtUtc = runStartedAtUtc;
    }
}

public sealed class MaesterViewerLoopbackServer : IDisposable {
    private readonly HttpListener listener = new HttpListener();
    private readonly int maximumConcurrentRequests;
    private int activeRequests;
    private readonly CancellationTokenSource stop = new CancellationTokenSource();
    private readonly ConcurrentDictionary<Task, HttpListenerContext> inFlight = new ConcurrentDictionary<Task, HttpListenerContext>();
    private readonly TimeProvider timeProvider;
    private readonly TimeSpan maximumReportAge;
    private readonly TimeSpan writeTimeout;
    private Task acceptLoop;
    private MaesterViewerSnapshot snapshot;
    private int refreshHealthy;

    public MaesterViewerLoopbackServer(int port, int maximumConcurrentRequests, TimeSpan maximumReportAge, TimeSpan writeTimeout, TimeProvider timeProvider) {
        this.maximumConcurrentRequests = maximumConcurrentRequests;
        this.maximumReportAge = maximumReportAge; this.writeTimeout = writeTimeout; this.timeProvider = timeProvider;
        listener.IgnoreWriteExceptions = true;
        listener.Prefixes.Add("http://127.0.0.1:" + port.ToString(CultureInfo.InvariantCulture) + "/");
    }

    public void Start() { listener.Start(); acceptLoop = AcceptLoopAsync(); }
    public void SetSnapshot(MaesterViewerSnapshot value) { Interlocked.Exchange(ref snapshot, value); Volatile.Write(ref refreshHealthy, 1); }
    public void SetRefreshFailed() { Volatile.Write(ref refreshHealthy, 0); }

    private async Task AcceptLoopAsync() {
        while (!stop.IsCancellationRequested) {
            HttpListenerContext context;
            try { context = await listener.GetContextAsync().WaitAsync(stop.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { break; }
            catch (HttpListenerException) when (stop.IsCancellationRequested) { break; }
            if (Interlocked.Increment(ref activeRequests) > maximumConcurrentRequests) {
                Interlocked.Decrement(ref activeRequests);
                try { context.Response.StatusCode = 503; context.Response.Abort(); } catch { }
                continue;
            }
            Task handler = HandleAndReleaseAsync(context);
            inFlight.TryAdd(handler, context);
            _ = handler.ContinueWith(completed => {
                inFlight.TryRemove(completed, out _);

            }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        }
    }

    private async Task HandleAndReleaseAsync(HttpListenerContext context) {
        try { await HandleAsync(context).ConfigureAwait(false); }
        finally { Interlocked.Decrement(ref activeRequests); }
    }

    private async Task HandleAsync(HttpListenerContext context) {
        try {
            var request = context.Request;
            var response = context.Response;
            response.Headers["Cache-Control"] = "no-store";
            response.Headers["X-Content-Type-Options"] = "nosniff";
            string raw = request.RawUrl ?? "";
            if (request.ContentLength64 > 0 || request.IsWebSocketRequest || request.Headers["Transfer-Encoding"] != null) {
                await WriteMinimalAsync(response, 400, "bad request", false).ConfigureAwait(false); return;
            }
            bool get = String.Equals(request.HttpMethod, "GET", StringComparison.Ordinal);
            bool head = String.Equals(request.HttpMethod, "HEAD", StringComparison.Ordinal);
            if (!get && !head) {
                response.Headers["Allow"] = "GET, HEAD";
                await WriteMinimalAsync(response, 405, "method not allowed", false).ConfigureAwait(false); return;
            }
            if (String.Equals(raw, "/healthz", StringComparison.Ordinal)) {
                await WriteMinimalAsync(response, 200, "ok", head).ConfigureAwait(false); return;
            }
            var current = Volatile.Read(ref snapshot);
            var now = timeProvider.GetUtcNow();
            bool currentAge = current != null && current.RunStartedAtUtc <= now && now - current.RunStartedAtUtc <= maximumReportAge;
            if (String.Equals(raw, "/readyz", StringComparison.Ordinal)) {
                await WriteMinimalAsync(response, currentAge ? 200 : 503, currentAge ? "ready" : "unavailable", head).ConfigureAwait(false); return;
            }
            if (!String.Equals(raw, "/report.html", StringComparison.Ordinal)) {
                await WriteMinimalAsync(response, 404, "not found", head).ConfigureAwait(false); return;
            }
            if (!currentAge) { await WriteMinimalAsync(response, 503, "unavailable", head).ConfigureAwait(false); return; }
            long ageSeconds = Math.Max(0, (long)Math.Floor((now - current.RunStartedAtUtc).TotalSeconds));
            response.StatusCode = 200; response.ContentType = "text/html; charset=utf-8"; response.ContentLength64 = current.HtmlBytes.LongLength;
            response.Headers["X-Maester-Report-Run"] = current.RunId;
            response.Headers["X-Maester-Report-Generation"] = current.Generation;
            response.Headers["X-Maester-Report-Age-Seconds"] = ageSeconds.ToString(CultureInfo.InvariantCulture);
            response.Headers["X-Maester-Report-Stale"] = Volatile.Read(ref refreshHealthy) == 1 ? "false" : "true";
            if (!head) { await WriteAsync(response, current.HtmlBytes).ConfigureAwait(false); }
            else { response.Close(); }
        } catch { try { context.Response.Abort(); } catch { } }
    }

    private async Task WriteMinimalAsync(HttpListenerResponse response, int status, string text, bool head) {
        byte[] bytes = Encoding.ASCII.GetBytes(text); response.StatusCode = status; response.ContentType = "text/plain; charset=us-ascii"; response.ContentLength64 = bytes.LongLength;
        if (!head) await WriteAsync(response, bytes).ConfigureAwait(false); else response.Close();
    }
    private async Task WriteAsync(HttpListenerResponse response, byte[] bytes) {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(stop.Token); deadline.CancelAfter(writeTimeout);
        // HttpListener streams do not reliably interrupt a blocked write on token cancellation alone.
        using var abort = deadline.Token.Register(() => { try { response.Abort(); } catch { } });
        await response.OutputStream.WriteAsync(bytes, deadline.Token).ConfigureAwait(false); response.Close();
    }

    public void Dispose() {
        stop.Cancel(); try { listener.Stop(); } catch { }
        try { acceptLoop?.Wait(TimeSpan.FromSeconds(5)); } catch { }
        foreach (var context in inFlight.Values) { try { context.Response.Abort(); } catch { } }
        Task[] handlers = inFlight.Keys.ToArray();
        bool drained = true;
        if (handlers.Length > 0) {
            try { drained = Task.WaitAll(handlers, writeTimeout + TimeSpan.FromSeconds(1)); }
            catch (AggregateException) { drained = true; }
        }
        listener.Close();
        if (!drained) { throw new InvalidOperationException("Loopback handlers did not stop within the shutdown deadline."); }
        stop.Dispose();
    }
}
'@
}

$script:MaesterViewerTimeProvider = [TimeProvider]::System

function Start-MaesterViewerWorker {
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Runs a local supervised listener and performs no external mutation.')]
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$Environment,
    [Parameter(Mandatory)][scriptblock]$Store,
    [Parameter(Mandatory)][byte[]]$TemplateBytes,
    [ValidateRange(1, 65535)][int]$Port = 8081,
    [ValidateScript({ $_ -ge [TimeSpan]::FromMilliseconds(100) -and $_ -le [TimeSpan]::FromHours(1) })]
    [TimeSpan]$PollInterval = [TimeSpan]::FromSeconds(30),
    [ValidateScript({ $_ -gt [TimeSpan]::Zero -and $_ -le [TimeSpan]::FromDays(31) })]
    [TimeSpan]$MaximumReportAge = [TimeSpan]::FromHours(24),
    [ValidateRange(1, 64)][int]$MaximumConcurrentRequests = 4,
    [ValidateScript({ $_ -gt [TimeSpan]::Zero -and $_ -le [TimeSpan]::FromSeconds(15) })]
    [TimeSpan]$ClientWriteTimeout = [TimeSpan]::FromSeconds(5),
    [ValidateRange(1, 67108864)][int64]$MaximumHtmlBytes = 20MB,
    [Parameter(Mandatory)][Threading.CancellationToken]$CancellationToken
  )

  $server = [MaesterViewerLoopbackServer]::new(
    $Port, $MaximumConcurrentRequests, $MaximumReportAge, $ClientWriteTimeout, $script:MaesterViewerTimeProvider
  )
  try {
    $server.Start()
    while (-not $CancellationToken.IsCancellationRequested) {
      try {
        $snapshot = Read-MaesterViewerProjection -TenantId $TenantId -Environment $Environment -TemplateBytes $TemplateBytes -Store $Store -MaximumHtmlBytes $MaximumHtmlBytes
        $ticks = [long]0
        if ($snapshot.generation -isnot [string] -or -not [long]::TryParse(
            $snapshot.generation, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$ticks)) {
          throw 'Projection generation is invalid.'
        }
        $runStartedAtUtc = [DateTimeOffset]::new($ticks, [TimeSpan]::Zero)
        if ($runStartedAtUtc -gt $script:MaesterViewerTimeProvider.GetUtcNow()) { throw 'Projection generation is in the future.' }
        $server.SetSnapshot([MaesterViewerSnapshot]::new(
          $snapshot.htmlBytes, $snapshot.runId, $snapshot.generation, $runStartedAtUtc
        ))
      }
      catch {
        $server.SetRefreshFailed()
      }
      if ($CancellationToken.WaitHandle.WaitOne($PollInterval)) { break }
    }
  }
  finally {
    $server.Dispose()
  }
}

Export-ModuleMember -Function Start-MaesterViewerWorker
