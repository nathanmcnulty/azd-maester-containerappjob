#Requires -Version 7.6
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$StorageAccountName,
  [Parameter(Mandatory)][string]$ProjectionContainerName,
  [Parameter(Mandatory)][string]$TenantId,
  [Parameter(Mandatory)][string]$Environment,
  [Parameter(Mandatory)][string]$UserAssignedIdentityClientId,
  [ValidateRange(1, 65535)][int]$Port = 8081,
  [ValidateRange(1, 3600)][int]$PollIntervalSeconds = 30,
  [ValidateRange(1, 2678400)][int]$MaximumReportAgeSeconds = 86400,
  [ValidateRange(1, 64)][int]$MaximumConcurrentRequests = 4,
  [ValidateRange(1, 15)][int]$ClientWriteTimeoutSeconds = 5,
  [ValidateRange(1, 67108864)][int64]$MaximumHtmlBytes = 20MB,
  [ValidateRange(1, 10)][int]$TokenAcquisitionTimeoutSeconds = 10
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Maester.ViewerIdentity.psm1') -Force
$signals = [MaesterViewerProcessCancellation]::new()
try {
  Start-MaesterViewerEntrypoint -StorageAccountName $StorageAccountName -ProjectionContainerName $ProjectionContainerName `
    -TenantId $TenantId -Environment $Environment -UserAssignedIdentityClientId $UserAssignedIdentityClientId -Port $Port `
    -PollInterval ([TimeSpan]::FromSeconds($PollIntervalSeconds)) -MaximumReportAge ([TimeSpan]::FromSeconds($MaximumReportAgeSeconds)) `
    -MaximumConcurrentRequests $MaximumConcurrentRequests -ClientWriteTimeout ([TimeSpan]::FromSeconds($ClientWriteTimeoutSeconds)) `
    -MaximumHtmlBytes $MaximumHtmlBytes -TokenAcquisitionTimeout ([TimeSpan]::FromSeconds($TokenAcquisitionTimeoutSeconds)) `
    -CancellationToken $signals.Token
} finally {
  $signals.Dispose()
}
