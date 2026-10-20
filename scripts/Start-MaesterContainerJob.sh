#!/bin/sh
# Execute only a bundled runner, never a mounted share or the bootstrap engine.
set -eu
export POWERSHELL_TELEMETRY_OPTOUT=1 DOTNET_CLI_TELEMETRY_OPTOUT=1
mode=${1:?Expected acr or nonacr mode}
shift
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != '-ValidateRuntimeOnly' ]; }; then
  echo 'Unsupported runner argument.' >&2
  exit 2
fi
case "$mode" in acr|nonacr) ;; *) echo 'Expected acr or nonacr mode.' >&2; exit 2 ;; esac
[ "$(uname -m)" = 'x86_64' ] || { echo 'Expected Linux x64.' >&2; exit 1; }
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
owned_dir=$(mktemp -d "${TMPDIR:-/tmp}/maester-runtime.XXXXXXXX")
child_pid=
cleanup() { rm -rf -- "$owned_dir"; }
terminate() {
  code=$1
  trap '' TERM INT
  if [ -n "$child_pid" ]; then
    kill -TERM "$child_pid" 2>/dev/null || :
    wait "$child_pid" 2>/dev/null || :
  fi
  exit "$code"
}
run_child() {
  "$@" &
  child_pid=$!
  status=0
  wait "$child_pid" || status=$?
  child_pid=
  return "$status"
}
trap cleanup EXIT
trap 'terminate 143' TERM
trap 'terminate 130' INT
export HOME="$owned_dir/home" XDG_CACHE_HOME="$owned_dir/cache" XDG_CONFIG_HOME="$owned_dir/config" XDG_DATA_HOME="$owned_dir/data"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
check_runtime='if (-not $IsLinux -or [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne "X64" -or $PSVersionTable.PSVersion.ToString() -cne "7.6.6" -or [Environment]::Version.Major -ne 10) { throw "Expected PowerShell 7.6.6 / .NET 10 on Linux x64." }'
if [ "$mode" = 'acr' ]; then
  # The provisioning placeholder must fail here. Never bootstrap or fall back.
  engine=/opt/microsoft/powershell/7/pwsh
  [ -x "$engine" ] || { echo 'ACR image is not ready: pwsh is missing.' >&2; exit 1; }
  export PSModulePath='/usr/local/share/powershell/Modules:/opt/microsoft/powershell/7/Modules'
else
  # Hash and extract the same private copy, never execute before verification.
  cp -- "$script_dir/powershell-7.6.6-linux-x64.tar.gz" "$owned_dir/powershell.tar.gz"
  printf '%s  %s\n' 'DDBC4A2D113BBD46D283CFEDCBCD117A70CAEFD7673F41F2B4E0000BADF103BC' "$owned_dir/powershell.tar.gz" | sha256sum --check --strict -
  mkdir "$owned_dir/engine" "$owned_dir/modules"
  tar --extract --gzip --no-same-owner --no-same-permissions --file "$owned_dir/powershell.tar.gz" --directory "$owned_dir/engine"
  chmod +x "$owned_dir/engine/pwsh"
  engine="$owned_dir/engine/pwsh"
  export PSModulePath="$owned_dir/modules:$owned_dir/engine/Modules"
fi
run_child "$engine" -NoLogo -NoProfile -Command "$check_runtime"
if [ "$mode" = 'nonacr' ]; then
  run_child "$engine" -NoLogo -NoProfile -File "$script_dir/Install-LockedModules.ps1" \
    -LockPath "$script_dir/runtime-packages.lock.json" -PackageDirectory "$script_dir/packages" -DestinationRoot "$owned_dir/modules"
fi
run_child "$engine" -NoLogo -NoProfile -File "$script_dir/Invoke-MaesterContainerJob.ps1" "$@"
