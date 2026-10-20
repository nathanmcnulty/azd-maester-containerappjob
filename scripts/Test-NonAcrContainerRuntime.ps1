#Requires -Version 7.6
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$projectRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'Maester-RuntimeFiles.psm1') -Force
. (Join-Path $PSScriptRoot 'Get-MaesterRuntimeBundle.ps1')
$infra = Get-Content (Join-Path $projectRoot 'infra/main.bicep') -Raw
$image = [regex]::Match($infra, "param imageName string = '([^']+)'").Groups[1].Value
if ($image -notmatch '^mcr.microsoft.com/azure-powershell@sha256:[a-f0-9]{64}$') { throw 'Expected digest-pinned production bootstrap image.' }
$owned = Join-Path ([IO.Path]::GetTempPath()) ('maester-ci-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $owned | Out-Null
$staging = $null
try {
  # Use exactly the publisher's bundle bytes, including verified module packages.
  $staging = New-MaesterRuntimeStaging -ProjectRoot $projectRoot
  $bundle = New-MaesterRuntimeBundle -Staging $staging
  if ((Get-FileHash $bundle.Path).Hash.ToLowerInvariant() -cne $bundle.Sha256) { throw 'Bundle identity mismatch.' }
  $verified = New-Item -ItemType Directory -Path (Join-Path $owned 'verified')
  Expand-MaesterRuntimeBundle -ArchivePath $bundle.Path -Destination $verified.FullName
  $sourceHashes = @{}
  Get-ChildItem $verified -File -Recurse | ForEach-Object { $sourceHashes[$_.FullName] = (Get-FileHash $_.FullName).Hash }
  $temp = New-Item -ItemType Directory -Path (Join-Path $owned 'tmp')
  Set-Content (Join-Path $temp 'unrelated') preserve
  $dockerArgs = @('run', '--rm', '--platform', 'linux/amd64', '--network', 'none', '--entrypoint', '/bin/sh', '--user', "$(& id -u):$(& id -g)",
    '--env', 'POWERSHELL_TELEMETRY_OPTOUT=1', '--mount', "type=bind,source=$verified,target=/opt/maester,readonly", '--mount', "type=bind,source=$temp,target=/tmp")
  # Both runs are offline and fresh; no Gallery, preinstalled Az, or warm cache.
  foreach ($iteration in 1..2) {
    $output = & docker @dockerArgs $image /opt/maester/Start-MaesterContainerJob.sh nonacr -ValidateRuntimeOnly 2>&1
    $status = $LASTEXITCODE
    $output | Write-Output
    if ($status -ne 0) { throw "Production non-ACR runtime validation failed (run $iteration): $status." }
    $text = $output -join "`n"
    foreach ($pattern in @('"validation": "runtime-only"', '"powerShell": "7.6.6"', '"dotnet": "10\.', '"architecture": "X64"')) {
      if ($text -notmatch $pattern) { throw "Missing runtime assertion: $pattern." }
    }
    $lock = Get-Content (Join-Path $projectRoot 'runtime-packages.lock.json') -Raw | ConvertFrom-Json
    foreach ($name in @('Az.Accounts', 'Microsoft.Graph.Authentication', 'Maester', 'Pester', 'DnsClient-PS')) {
      $version = @($lock.packages | Where-Object name -CEQ $name)[0].version
      if ($text -notmatch ('"' + [regex]::Escape($name) + '": "' + [regex]::Escape($version) + '"')) { throw "Missing exact import: $name/$version." }
    }
    if ($text -match 'Maester Run Completed') { throw 'Runtime-only validation reported assessment success.' }
    if (@(Get-ChildItem $temp -Directory -Filter 'maester-runtime.*').Count) { throw 'Runtime bootstrap left owned temporary files.' }
  }
  # The bootstrap interpreter is not a qualified ACR assessment engine.
  $output = & docker @dockerArgs $image /opt/maester/Start-MaesterContainerJob.sh acr -ValidateRuntimeOnly 2>&1
  if ($LASTEXITCODE -eq 0 -or ($output -join "`n") -match '"validation": "runtime-only"') { throw 'ACR provisioning placeholder did not fail closed.' }
  $bad = New-Item -ItemType Directory -Path (Join-Path $owned 'bad')
  Copy-Item (Join-Path $verified '*') $bad -Recurse
  Add-Content (Join-Path $bad 'powershell-7.6.6-linux-x64.tar.gz') corrupt
  $badArgs = @('run','--rm','--platform','linux/amd64','--network','none','--entrypoint','/bin/sh','--mount',"type=bind,source=$bad,target=/opt/maester,readonly",'--mount',"type=bind,source=$temp,target=/tmp")
  $output = & docker @badArgs $image /opt/maester/Start-MaesterContainerJob.sh nonacr -ValidateRuntimeOnly 2>&1
  if ($LASTEXITCODE -eq 0 -or ($output -join "`n") -match '"validation": "runtime-only"') { throw 'Corrupt engine archive did not fail closed.' }
  Copy-Item (Join-Path $verified 'powershell-7.6.6-linux-x64.tar.gz') $bad -Force
  Add-Content (Join-Path $bad "packages/$($lock.packages[0].name).$($lock.packages[0].version).nupkg") corrupt
  $output = & docker @badArgs $image /opt/maester/Start-MaesterContainerJob.sh nonacr -ValidateRuntimeOnly 2>&1
  if ($LASTEXITCODE -eq 0 -or ($output -join "`n") -match '"validation": "runtime-only"') { throw 'Corrupt package did not fail closed.' }
  if (($output -join "`n") -notmatch 'SHA-256 verification') { throw 'Module-failure test did not reach the real hash check.' }
  if (@(Get-ChildItem $temp -Directory -Filter 'maester-runtime.*').Count) { throw 'Failed bootstrap left owned temporary files.' }
  foreach ($file in $sourceHashes.Keys) { if ((Get-FileHash $file).Hash -cne $sourceHashes[$file]) { throw "Source changed: $file." } }
  if ((Get-Content (Join-Path $temp 'unrelated') -Raw).Trim() -ne 'preserve') { throw 'Unrelated temporary input changed.' }
  Write-Output 'Pinned-image native dependency checks, offline locked imports, failure closure and cleanup passed. MI transport is covered separately; no Azure assessment or report was run.'
}
finally {
  if ($staging) { Remove-Item -LiteralPath $staging.Path -Recurse -Force }
  Remove-Item -LiteralPath $owned -Recurse -Force
}
$global:LASTEXITCODE = 0
