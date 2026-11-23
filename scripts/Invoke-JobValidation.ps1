[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $false)]
  [string]$TenantId,

  [Parameter(Mandatory = $true)]
  [string]$ResourceGroupName,

  [Parameter(Mandatory = $true)]
  [string]$ContainerAppJobName,

  [int]$TimeoutMinutes = 20,

  # Qualification only: refuse upstream inline mail before starting a job.
  [switch]$RequireNoMail,

  [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'vendor\Azd.MaesterHooks\Maester-SetupHelpers.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Maester.AssessmentEvidence.psm1') -Force

if (-not $TenantId) { $TenantId = $env:AZURE_TENANT_ID }
if ([string]::IsNullOrWhiteSpace($TenantId)) { throw 'TenantId is required. Pass -TenantId or set AZURE_TENANT_ID.' }
$azAccount = Get-AzCliSubscriptionContext -SubscriptionId $SubscriptionId -TenantId $TenantId
$TenantId = $azAccount.tenantId
$armToken = az account get-access-token --subscription $SubscriptionId --resource https://management.azure.com/ --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($armToken)) { throw 'Failed to acquire the selected subscription management token.' }
$armHeaders = @{ Authorization = "Bearer $armToken" }

$apiVersion = '2024-03-01'
$basePath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.App/jobs/$ContainerAppJobName"

# Bind the expected evidence to this checkout before starting any workload.
$lockPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'runtime-packages.lock.json'
$expectedSource = Get-MaesterEvidenceSource -ScriptsRoot $PSScriptRoot -LockPath $lockPath
$packageLock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
$job = Invoke-RestMethod -Method GET -Uri "https://management.azure.com${basePath}?api-version=$apiVersion" -Headers $armHeaders
$containers = @($job.properties.template.containers)
if ($containers.Count -ne 1) { throw 'validation.jobContainerAmbiguous' }
$jobEnv = @{}
foreach ($entry in @($containers[0].env)) {
  if ($jobEnv.ContainsKey($entry.name)) { throw 'validation.jobEnvironmentAmbiguous' }
  $jobEnv[$entry.name] = $entry.value
}
$storageAccount = $jobEnv['STORAGE_ACCOUNT_NAME']
if ($storageAccount -isnot [string] -or $storageAccount -cnotmatch '^[a-z0-9]{3,24}\z') { throw 'validation.storageDestinationInvalid' }
# Upstream Maester sends mail before returning. Qualification deliberately does
# not use that path; a post-return evidence gate cannot retract a sent report.
$expectMail = -not [string]::IsNullOrWhiteSpace($jobEnv['MAIL_RECIPIENT'])
if ($RequireNoMail -and $expectMail) { throw 'validation.mailMustBeDisabled' }
$expectWebApp = -not [string]::IsNullOrWhiteSpace($jobEnv['WEB_APP_NAME'])
$requiredModules = @('Az.Accounts','Microsoft.Graph.Authentication','Pester','Maester','DnsClient-PS')
if (([string]$jobEnv['INCLUDE_EXCHANGE']).Trim() -ieq 'true') { $requiredModules += 'ExchangeOnlineManagement' }
if (([string]$jobEnv['INCLUDE_TEAMS']).Trim() -ieq 'true') { $requiredModules += 'MicrosoftTeams' }
$expectedModules = @{}
foreach ($name in $requiredModules) {
  $package = @($packageLock.packages | Where-Object name -CEQ $name)
  if ($package.Count -ne 1) { throw 'validation.packageLockInvalid' }
  $expectedModules[$name] = [string]$package[0].version
}
$storageToken = az account get-access-token --subscription $SubscriptionId --resource https://storage.azure.com/ --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($storageToken)) { throw 'validation.storageTokenUnavailable' }
$storageHeaders = @{ Authorization = "Bearer $storageToken"; 'x-ms-version' = '2021-12-02' }
$receiptBase = "https://$storageAccount.blob.core.windows.net/archive"
# Bounded data-read preflight with the operator's existing authorization only.
# List permission is not assumed to imply Get; the exact receipt GET is mandatory.
try {
  $null = Invoke-WebRequest -Method GET -Uri "${receiptBase}?restype=container&comp=list&prefix=validation-receipts%2F&maxresults=1" -Headers $storageHeaders -MaximumRedirection 0 -ErrorAction Stop
}
catch { throw 'validation.receiptReaderUnavailable: existing Blob data access is required before starting; no permissions were changed.' }

# Revalidate at the mutation boundary after token acquisition.
$null = Get-AzCliSubscriptionContext -SubscriptionId $SubscriptionId -TenantId $TenantId

# Start the Container App Job execution
$startedAt = [datetimeoffset]::UtcNow
$startPayload = Invoke-RestMethod -Method POST -Uri "https://management.azure.com$basePath/start?api-version=$apiVersion" -Headers $armHeaders -Body '{}' -ContentType 'application/json'
$executionName = $startPayload.name
if ([string]::IsNullOrWhiteSpace($executionName)) {
  # Some API versions return the execution name in different fields
  $executionName = $startPayload.id -split '/' | Select-Object -Last 1
}

if ($executionName -cnotmatch '^[a-z0-9][a-z0-9-]{0,127}\z') { throw 'validation.executionIdentityMissing' }
Write-Host "Started Container App Job execution: $executionName"

# Poll execution status
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$status = 'Running'
do {
  Start-Sleep -Seconds 15
  $execPayload = Invoke-RestMethod -Method GET -Uri "https://management.azure.com$basePath/executions/${executionName}?api-version=$apiVersion" -Headers $armHeaders -ErrorAction SilentlyContinue
  if (-not $execPayload) {
    Write-Warning "Failed to check execution status. Retrying..."
    continue
  }

  $status = $execPayload.properties.status
  Write-Host "Execution status: $status"
} while ($status -in @('Running', 'Processing', 'Unknown') -and (Get-Date) -lt $deadline)

if ($status -ne 'Succeeded') {
  # Try to get more details about the failure
  $detailPayload = Invoke-RestMethod -Method GET -Uri "https://management.azure.com$basePath/executions/${executionName}?api-version=$apiVersion" -Headers $armHeaders -ErrorAction SilentlyContinue
  if ($detailPayload -and $detailPayload.properties -and $detailPayload.properties.PSObject.Properties.Match('status').Count -gt 0) {
    throw "Container App Job execution did not succeed. Final status: $($detailPayload.properties.status)"
  }
  throw "Container App Job execution did not succeed. Final status: $status"
}

try {
  # Never accept a global latest receipt, fall back to HTML, or print raw content.
  $response = Invoke-WebRequest -Method GET -Uri "$receiptBase/validation-receipts/$executionName.json" -Headers $storageHeaders -MaximumRedirection 0 -ErrorAction Stop
  $receipt = Assert-MaesterValidationReceipt -Json $response.Content -ExecutionName $executionName -ExpectedSource $expectedSource -ExpectedModules $expectedModules -NotBefore $startedAt -ExpectWebApp $expectWebApp -ExpectMail $expectMail
}
catch { throw 'validation.receiptUnavailableOrInvalid: execution status alone is not assessment validation.' }
Write-Host 'Container App Job assessment evidence and Blob/Web App publication validated.'

$result = [pscustomobject]@{
  ValidationPassed    = $true
  ValidationScope     = 'AssessmentAndBlobWebAppPublication'
  MailDeliveryVerified = $false
  AssessmentEvidence = $receipt.Assessment
  PublicationEvidence = $receipt.Publication
  EvidenceSource     = $receipt.Source
  ExecutionName       = $executionName
  FinalStatus         = $status
  SubscriptionId      = $SubscriptionId
  ResourceGroupName   = $ResourceGroupName
  ContainerAppJobName = $ContainerAppJobName
  CompletedAt         = (Get-Date).ToString('o')
}

if ($PassThru) {
  return $result
}
