#!/bin/sh
# Embedded in the Job template; no mounted or mutable script is executed.
set -eu
umask 077
export POWERSHELL_TELEMETRY_OPTOUT=1 DOTNET_CLI_TELEMETRY_OPTOUT=1
owned_dir=$(mktemp -d "${TMPDIR:-/tmp}/maester-bootstrap.XXXXXXXX")
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
# The base image's engine may need a writable first-run cache. Never inherit user profiles.
export HOME="$owned_dir/home" XDG_CONFIG_HOME="$owned_dir/config" XDG_CACHE_HOME="$owned_dir/cache"
mkdir "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$owned_dir/bundle"
printf '%s' "${MAESTER_RUNTIME_BOOTSTRAP:?Missing embedded bootstrap}" | base64 --decode > "$owned_dir/bootstrap.ps1"
unset MAESTER_RUNTIME_BOOTSTRAP
pwsh -NoLogo -NoProfile -File "$owned_dir/bootstrap.ps1" -Destination "$owned_dir/bundle" &
child_pid=$!
status=0
wait "$child_pid" || status=$?
child_pid=
[ "$status" -eq 0 ] || exit "$status"
# The bootstrap engine has exited. Only the isolated exact locked engine will assess.
/bin/sh "$owned_dir/bundle/Start-MaesterContainerJob.sh" nonacr &
child_pid=$!
status=0
wait "$child_pid" || status=$?
child_pid=
exit "$status"
