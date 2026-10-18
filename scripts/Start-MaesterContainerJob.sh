#!/bin/sh
# Azure Files need not permit execution: Bicep invokes this file with /bin/sh.
set -eu
export POWERSHELL_TELEMETRY_OPTOUT=1 DOTNET_CLI_TELEMETRY_OPTOUT=1
mode=${1:?Expected acr or nonacr mode}
shift
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != '-ValidateRuntimeOnly' ]; }; then
  echo 'Unsupported runner argument.' >&2
  exit 2
fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
check_runtime='if (-not $IsLinux -or [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne "X64" -or $PSVersionTable.PSVersion.ToString() -cne "7.6.6" -or [Environment]::Version.Major -ne 10) { throw "Expected PowerShell 7.6.6 / .NET 10 on Linux x64." }'
case "$mode" in
  acr)
    # The provisioning placeholder must fail here. Never bootstrap or fall back.
    command -v pwsh >/dev/null 2>&1 || { echo 'ACR image is not ready: pwsh is missing.' >&2; exit 1; }
    pwsh -NoLogo -NoProfile -Command "$check_runtime"
    exec pwsh -NoLogo -NoProfile -File "$script_dir/Invoke-MaesterContainerJob.ps1" "$@"
    ;;
  nonacr) ;;
  *) echo 'Expected acr or nonacr mode.' >&2; exit 2 ;;
esac
[ "$(uname -m)" = 'x86_64' ] || { echo 'Expected Linux x64.' >&2; exit 1; }
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
trap cleanup EXIT
trap 'terminate 143' TERM
trap 'terminate 130' INT
# Hash and extract the same private copy, never modify the mounted source.
cp -- "$script_dir/powershell-7.6.6-linux-x64.tar.gz" "$owned_dir/powershell.tar.gz"
printf '%s  %s\n' 'DDBC4A2D113BBD46D283CFEDCBCD117A70CAEFD7673F41F2B4E0000BADF103BC' "$owned_dir/powershell.tar.gz" | sha256sum --check --strict -
mkdir "$owned_dir/engine"
tar --extract --gzip --no-same-owner --file "$owned_dir/powershell.tar.gz" --directory "$owned_dir/engine"
chmod +x "$owned_dir/engine/pwsh"
"$owned_dir/engine/pwsh" -NoLogo -NoProfile -Command "$check_runtime"
"$owned_dir/engine/pwsh" -NoLogo -NoProfile -File "$script_dir/Invoke-MaesterContainerJob.ps1" "$@" &
child_pid=$!
status=0
wait "$child_pid" || status=$?
child_pid=
exit "$status"
