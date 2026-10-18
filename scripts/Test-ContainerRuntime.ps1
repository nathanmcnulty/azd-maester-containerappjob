#Requires -Version 7.6
[CmdletBinding()]
param(
    [string]$LockPath = '/tmp/runtime-packages.lock.json',
    [string]$ModuleRoot = '/usr/local/share/powershell/Modules'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsLinux -or [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne 'X64') { throw 'The production image requires Linux x64.' }
$lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json
$versions = [ordered]@{}
foreach ($package in $lock.packages) {
    $manifest = Join-Path $ModuleRoot "$($package.name)/$($package.version)/$($package.name).psd1"
    $data = Import-PowerShellDataFile -LiteralPath $manifest
    if ([version]$data.ModuleVersion -ne [version]$package.version) { throw "Module manifest version mismatch: $($package.name)." }
}
foreach ($name in @('Az.Accounts','Microsoft.Graph.Authentication','Maester','Pester','DnsClient-PS')) {
    $package = @($lock.packages | Where-Object name -CEQ $name)
    if ($package.Count -ne 1) { throw "Default module absent from lock: $name." }
    $manifest = Join-Path $ModuleRoot "$name/$($package[0].version)/$name.psd1"
    $loaded = @(Import-Module -Name $manifest -Force -PassThru | Where-Object Name -CEQ $name)
    if ($loaded.Count -ne 1 -or $loaded[0].Version -ne [version]$package[0].version) { throw "Exact module import failed: $name." }
    $versions[$name] = $loaded[0].Version.ToString()
}
[ordered]@{powerShell=$PSVersionTable.PSVersion.ToString();dotnet=[Environment]::Version.ToString();linux=$IsLinux;is64Bit=[Environment]::Is64BitProcess;modules=$versions} | ConvertTo-Json -Depth 5
