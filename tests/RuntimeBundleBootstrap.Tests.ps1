BeforeAll {
  . (Join-Path $PSScriptRoot '../scripts/Get-MaesterRuntimeBundle.ps1')
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public class RuntimeBundleHandler : HttpMessageHandler {
  public static Queue<HttpResponseMessage> Responses = new Queue<HttpResponseMessage>();
  public static List<string> Requests = new List<string>();
  protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) {
    Requests.Add(request.Method + " " + request.RequestUri.AbsoluteUri + " " + request.Headers.ToString());
    return Task.FromResult(Responses.Dequeue());
  }
}
'@
  function New-TestBundle {
    param([string]$Path, [string]$Extra, [string]$Omit, [switch]$Duplicate, [switch]$Symlink)
    $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
      $names = @('Invoke-MaesterContainerJob.ps1','Maester.AssessmentEvidence.psm1','Maester.DriftInputs.psm1','Maester.DriftRun.psm1','Install-LockedModules.ps1','Start-MaesterContainerJob.sh','runtime-packages.lock.json','powershell-7.6.6-linux-x64.tar.gz','packages/Test.Module.1.0.0.nupkg')
      if ($Extra) { $names += $Extra }
      if ($Duplicate) { $names += 'Start-MaesterContainerJob.sh' }
      foreach ($name in $names) {
        if ($name -eq $Omit) { continue }
        $entry = $archive.CreateEntry($name)
        if ($Symlink -and $name -eq 'Start-MaesterContainerJob.sh') { $entry.ExternalAttributes = -1577058304 }
        $writer = [IO.StreamWriter]::new($entry.Open())
        try {
          if ($name -eq 'runtime-packages.lock.json') { $writer.Write('{"schemaVersion":1,"packages":[{"name":"Test.Module","version":"1.0.0","sha256":"' + ('a' * 64) + '"}]}') }
          else { $writer.Write('test bytes') }
        } finally { $writer.Dispose() }
      }
    } finally { $archive.Dispose() }
  }
  function Add-TestResponse {
    param([int]$Status = 200, [byte[]]$Bytes)
    $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$Status)
    $response.Content = [Net.Http.ByteArrayContent]::new($Bytes)
    [RuntimeBundleHandler]::Responses.Enqueue($response)
  }
  $envNames = @('MAESTER_RUNTIME_STORAGE_ACCOUNT','MAESTER_RUNTIME_SHA256','MAESTER_RUNTIME_BLOB_NAME','MAESTER_RUNTIME_SIZE','IDENTITY_ENDPOINT','IDENTITY_HEADER')
  $saved = @{}
  foreach ($name in $envNames) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
}
AfterAll { foreach ($name in $envNames) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) } }
Describe 'Pinned private runtime bootstrap' {
  BeforeEach {
    [RuntimeBundleHandler]::Responses.Clear(); [RuntimeBundleHandler]::Requests.Clear()
    $script:bundleDestination = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory $bundleDestination
    $script:archive = Join-Path $TestDrive (([guid]::NewGuid().ToString('N')) + '.zip')
    New-TestBundle -Path $archive
    $script:bytes = [IO.File]::ReadAllBytes($archive)
    $env:MAESTER_RUNTIME_STORAGE_ACCOUNT = 'testaccount'
    $env:MAESTER_RUNTIME_SHA256 = (Get-FileHash $archive).Hash.ToLowerInvariant()
    $env:MAESTER_RUNTIME_BLOB_NAME = "bundles/$env:MAESTER_RUNTIME_SHA256.zip"
    $env:MAESTER_RUNTIME_SIZE = [string]$bytes.Length
    $env:IDENTITY_ENDPOINT = 'http://localhost:1234/msi/token'
    $env:IDENTITY_HEADER = 'fixture-identity-secret'
    Mock New-MaesterRuntimeHttpClient { [Net.Http.HttpClient]::new([RuntimeBundleHandler]::new()) }
    Mock Start-Sleep {}
    Add-TestResponse -Bytes ([Text.Encoding]::UTF8.GetBytes('{"access_token":"fixture-bearer-secret"}'))
  }
  It 'downloads only canonical Blob using MI and verifies then extracts complete bundle' {
    Add-TestResponse -Bytes $bytes
    Get-MaesterRuntimeBundle -Destination $bundleDestination
    Test-Path "$bundleDestination/Start-MaesterContainerJob.sh" | Should -BeTrue
    Test-Path "$bundleDestination/packages/Test.Module.1.0.0.nupkg" | Should -BeTrue
    Test-Path "$bundleDestination/.runtime.zip" | Should -BeFalse
    [RuntimeBundleHandler]::Requests.Count | Should -Be 2
    [RuntimeBundleHandler]::Requests[0] | Should -Match 'resource=https%3A%2F%2Fstorage.azure.com%2F'
    [RuntimeBundleHandler]::Requests[0] | Should -Not -Match 'Authorization:'
    [RuntimeBundleHandler]::Requests[1] | Should -Match 'https://testaccount.blob.core.windows.net/runtime/bundles/'
    [RuntimeBundleHandler]::Requests[1] | Should -Match 'Authorization: Bearer fixture-bearer-secret'
    [RuntimeBundleHandler]::Requests[1] | Should -Not -Match 'fixture-identity-secret|sig=|SharedKey'
  }
  It 'rejects a mismatching external hash before any extraction' {
    $env:MAESTER_RUNTIME_SHA256 = 'b' * 64; $env:MAESTER_RUNTIME_BLOB_NAME = "bundles/$env:MAESTER_RUNTIME_SHA256.zip"
    Add-TestResponse -Bytes $bytes
    { Get-MaesterRuntimeBundle -Destination $bundleDestination } | Should -Throw '*retrieve and verify*'
    Test-Path "$bundleDestination/Start-MaesterContainerJob.sh" | Should -BeFalse
  }
  It 'rejects truncated and oversized responses before extraction' -TestCases @(@{ Delta = -1 }, @{ Delta = 1 }) {
    param($Delta)
    $env:MAESTER_RUNTIME_SIZE = [string]($bytes.Length + $Delta)
    Add-TestResponse -Bytes $bytes
    { Get-MaesterRuntimeBundle -Destination $bundleDestination } | Should -Throw '*retrieve and verify*'
    Test-Path "$bundleDestination/Start-MaesterContainerJob.sh" | Should -BeFalse
  }
  It 'rejects redirect responses instead of following them' {
    Add-TestResponse -Status 302 -Bytes ([byte[]]@())
    { Get-MaesterRuntimeBundle -Destination $bundleDestination } | Should -Throw '*retrieve and verify*'
    [RuntimeBundleHandler]::Requests.Count | Should -Be 2
  }
  It 'bounds authorization propagation retries and suppresses secret diagnostics' {
    1..6 | ForEach-Object { Add-TestResponse -Status 403 -Bytes ([Text.Encoding]::UTF8.GetBytes('fixture-bearer-secret')) }
    try { Get-MaesterRuntimeBundle -Destination $bundleDestination; throw 'Expected failure' } catch { $_.ToString() | Should -Not -Match 'fixture-bearer-secret|fixture-identity-secret' }
    [RuntimeBundleHandler]::Requests.Count | Should -Be 7
    Should -Invoke Start-Sleep -Times 5 -Exactly
  }
  It 'allows bounded transient recovery' {
    Add-TestResponse -Status 403 -Bytes ([byte[]]@()); Add-TestResponse -Bytes $bytes
    Get-MaesterRuntimeBundle -Destination $bundleDestination
    Should -Invoke Start-Sleep -Times 1 -Exactly
  }
  It 'rejects untrusted endpoint before requesting a token' {
    $env:IDENTITY_ENDPOINT = 'https://example.com/msi/token'
    { Get-MaesterRuntimeBundle -Destination $bundleDestination } | Should -Throw '*identity endpoint*'
    [RuntimeBundleHandler]::Requests.Count | Should -Be 0
  }
  It 'rejects malformed size and newline-suffixed account identifiers before transport' -TestCases @(
    @{ Account="testaccount`n"; Size='100' }, @{ Account='testaccount'; Size='0' },
    @{ Account='testaccount'; Size='536870913' }, @{ Account='testaccount'; Size='not-a-number' }
  ) {
    param($Account,$Size)
    $env:MAESTER_RUNTIME_STORAGE_ACCOUNT = $Account; $env:MAESTER_RUNTIME_SIZE = $Size
    { Get-MaesterRuntimeBundle -Destination $bundleDestination } | Should -Throw '*configuration*'
    [RuntimeBundleHandler]::Requests.Count | Should -Be 0
  }
  It 'retains production no-redirect and no-proxy transport settings' {
    $source = Get-Content (Join-Path $PSScriptRoot '../scripts/Get-MaesterRuntimeBundle.ps1') -Raw
    $source | Should -Match '\$handler.AllowAutoRedirect = \$false'
    $source | Should -Match '\$handler.UseProxy = \$false'
  }
  It 'rejects mutable or SAS blob references before transport' -TestCases @(@{ Blob='latest.zip' },@{ Blob='bundles/test.zip?sig=secret' },@{ Blob='../other.zip' }) {
    param($Blob)
    $env:MAESTER_RUNTIME_BLOB_NAME = $Blob
    { Get-MaesterRuntimeBundle -Destination $bundleDestination } | Should -Throw '*configuration*'
    [RuntimeBundleHandler]::Requests.Count | Should -Be 0
  }
  It 'rejects occupied destination without altering files' {
    Set-Content "$bundleDestination/sentinel" 'keep'
    { Get-MaesterRuntimeBundle -Destination $bundleDestination } | Should -Throw '*empty owned directory*'
    Get-Content "$bundleDestination/sentinel" | Should -Be 'keep'
  }
  It 'rejects unsafe or incomplete ZIP before extraction' -TestCases @(
    @{ Extra='../escape'; Omit=''; Duplicate=$false; Symlink=$false },
    @{ Extra='/absolute'; Omit=''; Duplicate=$false; Symlink=$false },
    @{ Extra='packages\\escape'; Omit=''; Duplicate=$false; Symlink=$false },
    @{ Extra=''; Omit='Start-MaesterContainerJob.sh'; Duplicate=$false; Symlink=$false },
    @{ Extra=''; Omit=''; Duplicate=$true; Symlink=$false },
    @{ Extra=''; Omit=''; Duplicate=$false; Symlink=$true }
  ) {
    param($Extra,$Omit,$Duplicate,$Symlink)
    $badArchive = Join-Path $TestDrive (([guid]::NewGuid().ToString('N')) + '.zip')
    New-TestBundle -Path $badArchive -Extra $Extra -Omit $Omit -Duplicate:$Duplicate -Symlink:$Symlink
    { Expand-MaesterRuntimeBundle -ArchivePath $badArchive -Destination $bundleDestination } | Should -Throw
    @(Get-ChildItem $bundleDestination -Force).Count | Should -Be 0
  }
  It 'limits streaming content independently of Content-Length' {
    $inputStream = [IO.MemoryStream]::new([byte[]](1..10)); $outputStream = [IO.MemoryStream]::new()
    try { { Copy-MaesterBoundedStream -Source $inputStream -Target $outputStream -Limit 9 } | Should -Throw '*size limit*' } finally { $inputStream.Dispose(); $outputStream.Dispose() }
  }
}
