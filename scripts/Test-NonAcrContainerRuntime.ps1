#Requires -Version 7.6
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$projectRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'Maester-RuntimeFiles.psm1') -Force
$infra = Get-Content (Join-Path $projectRoot 'infra/main.bicep') -Raw
$image = [regex]::Match($infra, "param imageName string = '([^']+)'").Groups[1].Value
if (-not $image -or $infra -notmatch "'/bin/sh'\s+'/mnt/scripts/Start-MaesterContainerJob.sh'\s+includeACR \? 'acr' : 'nonacr'") { throw 'Production invocation changed: update the integration test.' }
$owned = Join-Path ([IO.Path]::GetTempPath()) ('maester-ci-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $owned | Out-Null
$staging = $null
try {
  # Exactly the file preparation used by Setup-PostDeploy, including download/hash.
  $staging = New-MaesterRuntimeStaging -ProjectRoot $projectRoot
  $sourceHashes = @{}
  Get-ChildItem $staging.Path -File | ForEach-Object { $sourceHashes[$_.Name] = (Get-FileHash $_.FullName).Hash }
  $containerHome = New-Item -ItemType Directory -Path (Join-Path $owned 'home')
  $temp = New-Item -ItemType Directory -Path (Join-Path $owned 'tmp')
  Set-Content (Join-Path $temp 'unrelated') preserve
  $dockerArgs = @('run', '--rm', '--platform', 'linux/amd64', '--user', "$(& id -u):$(& id -g)", '--env', 'HOME=/home/maester', '--env', 'POWERSHELL_TELEMETRY_OPTOUT=1',
    '--mount', "type=bind,source=$($staging.Path),target=/mnt/scripts,readonly",
    '--mount', "type=bind,source=$containerHome,target=/home/maester",
    '--mount', "type=bind,source=$temp,target=/tmp")
  foreach ($network in @('bridge', 'none')) {
    # First run executes real module installation. Second proves cached default imports offline.
    $output = & docker @dockerArgs --network $network $image /bin/sh /mnt/scripts/Start-MaesterContainerJob.sh nonacr -ValidateRuntimeOnly 2>&1
    $status = $LASTEXITCODE
    $output | Write-Output
    if ($status -ne 0) { throw "Production non-ACR runtime validation failed ($network): $status." }
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
  # Same actual base with ACR mode cannot bootstrap around its missing pwsh.
  $output = & docker @dockerArgs --network none $image /bin/sh /mnt/scripts/Start-MaesterContainerJob.sh acr -ValidateRuntimeOnly 2>&1
  if ($LASTEXITCODE -eq 0 -or ($output -join "`n") -match '"validation": "runtime-only"') { throw 'ACR provisioning placeholder did not fail closed.' }
  # Real hash failure on real production base, preserving the original mounted inputs.
  $bad = New-Item -ItemType Directory -Path (Join-Path $owned 'bad')
  Copy-Item (Join-Path $staging.Path '*') $bad
  Add-Content (Join-Path $bad 'powershell-7.6.6-linux-x64.tar.gz') corrupt
  $output = & docker run --rm --platform linux/amd64 --network none --mount "type=bind,source=$bad,target=/mnt/scripts,readonly" --mount "type=bind,source=$temp,target=/tmp" $image /bin/sh /mnt/scripts/Start-MaesterContainerJob.sh nonacr -ValidateRuntimeOnly 2>&1
  if ($LASTEXITCODE -eq 0 -or ($output -join "`n") -match '"validation": "runtime-only"') { throw 'Corrupt archive did not fail closed.' }
  if (@(Get-ChildItem $temp -Directory -Filter 'maester-runtime.*').Count) { throw 'Failed bootstrap left owned temporary files.' }
  # A module integrity failure must not become a diagnostic or assessment success.
  Copy-Item (Join-Path $staging.Path 'powershell-7.6.6-linux-x64.tar.gz') $bad -Force
  $badLock = Get-Content (Join-Path $bad 'runtime-packages.lock.json') -Raw | ConvertFrom-Json
  $badLock.packages[0].sha256 = '0' * 64
  $badLock | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $bad 'runtime-packages.lock.json')
  $badHome = New-Item -ItemType Directory -Path (Join-Path $owned 'bad-home')
  $output = & docker run --rm --platform linux/amd64 --user "$(& id -u):$(& id -g)" --env HOME=/home/maester --env POWERSHELL_TELEMETRY_OPTOUT=1 --mount "type=bind,source=$bad,target=/mnt/scripts,readonly" --mount "type=bind,source=$badHome,target=/home/maester" --mount "type=bind,source=$temp,target=/tmp" $image /bin/sh /mnt/scripts/Start-MaesterContainerJob.sh nonacr -ValidateRuntimeOnly 2>&1
  if ($LASTEXITCODE -eq 0 -or ($output -join "`n") -match '"validation": "runtime-only"') { throw 'Module hash failure did not fail closed.' }
  if (($output -join "`n") -notmatch 'SHA-256 verification') { throw 'Module-failure test did not reach the real hash check.' }
  if (@(Get-ChildItem $temp -Directory | Where-Object Name -Match '^maester-(runtime\.|packages-)').Count) { throw 'Failed module installation left owned temporary files.' }
  foreach ($file in $sourceHashes.Keys) {
    if ((Get-FileHash (Join-Path $staging.Path $file)).Hash -cne $sourceHashes[$file]) { throw "Source changed: $file." }
  }
  if ((Get-Content (Join-Path $temp 'unrelated') -Raw).Trim() -ne 'preserve') { throw 'Unrelated temporary input changed.' }
  Write-Output 'Non-ACR production bootstrap, exact imports, failure closure and source preservation passed. No Azure assessment or report was run.'
}
finally {
  if ($staging) { Remove-Item -LiteralPath $staging.Path -Recurse -Force }
  Remove-Item -LiteralPath $owned -Recurse -Force
}
# GitHub's pwsh wrapper propagates LASTEXITCODE; negative tests deliberately set it.
# Reset only after all assertions and owned cleanup have completed successfully.
$global:LASTEXITCODE = 0
