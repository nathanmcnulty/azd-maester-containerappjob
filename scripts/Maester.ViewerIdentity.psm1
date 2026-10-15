#Requires -Version 7.6
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Maester.ViewerProjection.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Maester.ViewerWorker.psm1') -Force

if (-not ('MaesterContainerAppIdentityCredential' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Security;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

public sealed class MaesterContainerAppIdentityCredential : IDisposable {
    private const int MaximumResponseBytes = 65536;
    private const string Failure = "Managed identity token acquisition failed.";
    private readonly Guid clientId;
    private readonly HttpClient client;
    private readonly TimeProvider timeProvider;
    private readonly TimeSpan timeout;
    private readonly object gate = new object();
    private SecureString cachedToken;
    private DateTimeOffset cachedUntil;
    private bool disposed;

    public MaesterContainerAppIdentityCredential(Guid clientId, TimeSpan timeout, HttpMessageHandler handler, bool disposeHandler, TimeProvider timeProvider) {
        if (clientId == Guid.Empty || timeout <= TimeSpan.Zero || timeout > TimeSpan.FromSeconds(10)) throw new ArgumentException(Failure);
        this.clientId = clientId; this.timeout = timeout; this.timeProvider = timeProvider ?? TimeProvider.System;
        client = new HttpClient(handler ?? throw new ArgumentNullException(nameof(handler)), disposeHandler);
        client.Timeout = Timeout.InfiniteTimeSpan;
    }

    public SecureString GetToken() {
        lock (gate) {
            if (disposed) throw new ObjectDisposedException(nameof(MaesterContainerAppIdentityCredential));
            DateTimeOffset now = timeProvider.GetUtcNow();
            if (cachedToken != null && now < cachedUntil) return cachedToken;
            SecureString replacement = Acquire(now);
            SecureString previous = cachedToken;
            cachedToken = replacement;
            previous?.Dispose();
            return cachedToken;
        }
    }

    private SecureString Acquire(DateTimeOffset acquiredAt) {
        HttpRequestMessage request = null; HttpResponseMessage response = null; Stream stream = null;
        MemoryStream buffered = null; CancellationTokenSource deadline = null;
        try {
            Uri endpoint = ValidateEndpoint(Environment.GetEnvironmentVariable("IDENTITY_ENDPOINT"));
            string platformHeader = Environment.GetEnvironmentVariable("IDENTITY_HEADER");
            if (String.IsNullOrEmpty(platformHeader)) throw new InvalidOperationException();
            var target = new UriBuilder(endpoint) {
                Query = "api-version=2019-08-01&resource=https%3A%2F%2Fstorage.azure.com%2F&client_id=" + clientId.ToString("D")
            }.Uri;
            request = new HttpRequestMessage(HttpMethod.Get, target);
            request.Headers.Add("X-IDENTITY-HEADER", platformHeader);
            deadline = new CancellationTokenSource(timeout);
            response = client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token).GetAwaiter().GetResult();
            if (response.StatusCode != HttpStatusCode.OK) throw new InvalidOperationException();
            long? declared = response.Content.Headers.ContentLength;
            if (declared.HasValue && (declared.Value < 1 || declared.Value > MaximumResponseBytes)) throw new InvalidOperationException();
            stream = response.Content.ReadAsStreamAsync(deadline.Token).GetAwaiter().GetResult();
            buffered = new MemoryStream(); byte[] buffer = new byte[4096]; int total = 0; int read;
            while ((read = stream.ReadAsync(buffer, 0, buffer.Length, deadline.Token).GetAwaiter().GetResult()) > 0) {
                if (total + read > MaximumResponseBytes) throw new InvalidOperationException();
                buffered.Write(buffer, 0, read); total += read;
            }
            if (total == 0 || (declared.HasValue && total != declared.Value)) throw new InvalidOperationException();
            using JsonDocument document = JsonDocument.Parse(buffered.ToArray());
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new InvalidOperationException();
            string token = RequiredString(root, "access_token");
            string tokenType = RequiredString(root, "token_type");
            string resource = RequiredString(root, "resource");
            string responseClient = RequiredString(root, "client_id");
            if (!String.Equals(tokenType, "Bearer", StringComparison.Ordinal) ||
                !String.Equals(resource, "https://storage.azure.com/", StringComparison.Ordinal) ||
                !Guid.TryParseExact(responseClient, "D", out Guid parsedClient) || parsedClient != clientId ||
                token.IndexOfAny(new[] {'\r','\n'}) >= 0) throw new InvalidOperationException();
            long expiresOn = RequiredInteger(root, "expires_on");
            DateTimeOffset expiry = DateTimeOffset.FromUnixTimeSeconds(expiresOn);
            DateTimeOffset serviceLimit = expiry - TimeSpan.FromMinutes(2);
            DateTimeOffset localLimit = acquiredAt + TimeSpan.FromMinutes(10);
            DateTimeOffset usableUntil = serviceLimit < localLimit ? serviceLimit : localLimit;
            if (usableUntil <= acquiredAt) throw new InvalidOperationException();
            var secure = new SecureString();
            foreach (char value in token) secure.AppendChar(value);
            secure.MakeReadOnly(); cachedUntil = usableUntil;
            return secure;
        } catch { throw new InvalidOperationException(Failure); }
        finally {
            buffered?.Dispose(); stream?.Dispose(); response?.Dispose(); request?.Dispose(); deadline?.Dispose();
        }
    }

    private static Uri ValidateEndpoint(string value) {
        if (String.IsNullOrWhiteSpace(value) || value.IndexOf('\\') >= 0) throw new InvalidOperationException();
        foreach (char c in value) if (Char.IsControl(c)) throw new InvalidOperationException();
        if (!Uri.TryCreate(value, UriKind.Absolute, out Uri uri) || !String.Equals(uri.Scheme, "http", StringComparison.Ordinal) ||
            !String.IsNullOrEmpty(uri.UserInfo) || !String.IsNullOrEmpty(uri.Query) || !String.IsNullOrEmpty(uri.Fragment) ||
            !String.Equals(uri.AbsolutePath, "/msi/token", StringComparison.Ordinal) || uri.Port < 1) throw new InvalidOperationException();
        if (String.Equals(uri.Host, "localhost", StringComparison.OrdinalIgnoreCase)) return uri;
        if (!IPAddress.TryParse(uri.Host, out IPAddress address) || !IPAddress.IsLoopback(address)) throw new InvalidOperationException();
        return uri;
    }

    private static string RequiredString(JsonElement root, string name) {
        if (!root.TryGetProperty(name, out JsonElement value) || value.ValueKind != JsonValueKind.String) throw new InvalidOperationException();
        string result = value.GetString(); if (String.IsNullOrEmpty(result)) throw new InvalidOperationException(); return result;
    }
    private static long RequiredInteger(JsonElement root, string name) {
        if (!root.TryGetProperty(name, out JsonElement value)) throw new InvalidOperationException();
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out long numeric)) return numeric;
        if (value.ValueKind == JsonValueKind.String && Int64.TryParse(value.GetString(), NumberStyles.None, CultureInfo.InvariantCulture, out numeric)) return numeric;
        throw new InvalidOperationException();
    }

    public void Dispose() {
        lock (gate) {
            if (disposed) return; disposed = true;
            cachedToken?.Dispose(); cachedToken = null; client.Dispose();
        }
    }
}

public sealed class MaesterViewerProcessCancellation : IDisposable {
    private readonly CancellationTokenSource source = new CancellationTokenSource();
    private readonly ConsoleCancelEventHandler consoleHandler;
    private readonly System.Runtime.InteropServices.PosixSignalRegistration terminate;
    public MaesterViewerProcessCancellation() {
        consoleHandler = (sender, args) => { args.Cancel = true; source.Cancel(); };
        Console.CancelKeyPress += consoleHandler;
        if (!OperatingSystem.IsWindows()) terminate = System.Runtime.InteropServices.PosixSignalRegistration.Create(
            System.Runtime.InteropServices.PosixSignal.SIGTERM, context => { context.Cancel = true; source.Cancel(); });
    }
    public CancellationToken Token => source.Token;
    public void Dispose() { Console.CancelKeyPress -= consoleHandler; terminate?.Dispose(); source.Dispose(); }
}
'@
}

function New-MaesterContainerAppIdentityHttpHandler {
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

function New-MaesterContainerAppIdentityCredential {
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Creates a disposable credential owner and does not acquire a token until GetToken is called.')]
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ClientId,
    [ValidateScript({ $_ -gt [TimeSpan]::Zero -and $_ -le [TimeSpan]::FromSeconds(10) })]
    [TimeSpan]$AcquisitionTimeout = [TimeSpan]::FromSeconds(10),
    [Net.Http.HttpMessageHandler]$HttpMessageHandler,
    [TimeProvider]$TimeProvider = [TimeProvider]::System
  )
  $parsed = [guid]::Empty
  if (-not [guid]::TryParseExact($ClientId, 'D', [ref]$parsed) -or $parsed -eq [guid]::Empty -or $ClientId -cne $parsed.ToString('D')) {
    throw 'Managed identity configuration is invalid.'
  }
  $handler = if ($HttpMessageHandler) { $HttpMessageHandler } else { New-MaesterContainerAppIdentityHttpHandler }
  try {
    return [MaesterContainerAppIdentityCredential]::new($parsed, $AcquisitionTimeout, $handler, $null -eq $HttpMessageHandler, $TimeProvider)
  } catch {
    if ($null -eq $HttpMessageHandler) { $handler.Dispose() }
    throw 'Managed identity configuration is invalid.'
  }
}

function Start-MaesterViewerEntrypoint {
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Runs the explicitly configured local viewer process and performs no storage mutation.')]
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$StorageAccountName,
    [Parameter(Mandatory)][string]$ProjectionContainerName,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$Environment,
    [Parameter(Mandatory)][string]$UserAssignedIdentityClientId,
    [ValidateRange(1, 65535)][int]$Port = 8081,
    [ValidateScript({ $_ -ge [TimeSpan]::FromMilliseconds(100) -and $_ -le [TimeSpan]::FromHours(1) })]
    [TimeSpan]$PollInterval = [TimeSpan]::FromSeconds(30),
    [ValidateScript({ $_ -gt [TimeSpan]::Zero -and $_ -le [TimeSpan]::FromDays(31) })]
    [TimeSpan]$MaximumReportAge = [TimeSpan]::FromHours(24),
    [ValidateRange(1, 64)][int]$MaximumConcurrentRequests = 4,
    [ValidateScript({ $_ -gt [TimeSpan]::Zero -and $_ -le [TimeSpan]::FromSeconds(15) })]
    [TimeSpan]$ClientWriteTimeout = [TimeSpan]::FromSeconds(5),
    [ValidateRange(1, 67108864)][int64]$MaximumHtmlBytes = 20MB,
    [ValidateScript({ $_ -gt [TimeSpan]::Zero -and $_ -le [TimeSpan]::FromSeconds(10) })]
    [TimeSpan]$TokenAcquisitionTimeout = [TimeSpan]::FromSeconds(10),
    [Parameter(Mandatory)][Threading.CancellationToken]$CancellationToken,
    [Net.Http.HttpMessageHandler]$IdentityHttpMessageHandler,
    [Net.Http.HttpMessageHandler]$ProjectionHttpMessageHandler,
    [TimeProvider]$TimeProvider = [TimeProvider]::System
  )
  $tenant = [guid]::Empty
  if (-not [guid]::TryParseExact($TenantId, 'D', [ref]$tenant) -or $tenant -eq [guid]::Empty -or $TenantId -cne $tenant.ToString('D') -or
      $Environment -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z') { throw 'Viewer configuration is invalid.' }
  $credential = $null
  try {
    $credential = New-MaesterContainerAppIdentityCredential -ClientId $UserAssignedIdentityClientId -AcquisitionTimeout $TokenAcquisitionTimeout -HttpMessageHandler $IdentityHttpMessageHandler -TimeProvider $TimeProvider
    $tokenProvider = { $credential.GetToken() }.GetNewClosure()
    $store = New-MaesterAzureBlobProjectionStore -AccountName $StorageAccountName -ContainerName $ProjectionContainerName -TokenProvider $tokenProvider -HttpMessageHandler $ProjectionHttpMessageHandler
    $null = $credential.GetToken()
    Start-MaesterViewerWorker -TenantId $TenantId -Environment $Environment -Store $store -Port $Port -PollInterval $PollInterval `
      -MaximumReportAge $MaximumReportAge -MaximumConcurrentRequests $MaximumConcurrentRequests `
      -ClientWriteTimeout $ClientWriteTimeout -MaximumHtmlBytes $MaximumHtmlBytes -CancellationToken $CancellationToken
  } catch {
    throw 'Viewer process failed.'
  } finally {
    if ($credential) { $credential.Dispose() }
  }
}

Export-ModuleMember -Function New-MaesterContainerAppIdentityCredential, Start-MaesterViewerEntrypoint
