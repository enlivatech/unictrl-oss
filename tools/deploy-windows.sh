#!/bin/sh
# Builds Unictrl on the Windows laptop over SSH, installs it and starts it on the logged-in desktop.
# The source is copied with the repo layout intact because the project links ../../assets.
set -eu

host="${UNICTRL_WINDOWS_HOST:?Set UNICTRL_WINDOWS_HOST to user@your-pc}"
key="${UNICTRL_WINDOWS_KEY:-$HOME/.ssh/id_ed25519}"
stage='unictrl-stage' # relative to the Windows user's home folder
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ssh_() { ssh -i "$key" -o LogLevel=ERROR "$host" "$@"; }
scp_() { scp -q -r -i "$key" -o LogLevel=ERROR "$@"; }

# Start from empty source and output folders so no stale file (an old icon, a removed DLL) survives.
ssh_ "powershell -NoProfile -Command \"Remove-Item $stage/src, $stage/app -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $stage/src/windows | Out-Null\""
scp_ "$repo/windows/Unictrl" "$host:$stage/src/windows/"
scp_ "$repo/assets" "$host:$stage/src/"
scp_ "$repo/tools/windows/launch.ps1" "$host:$stage/launch.ps1"
log=$(mktemp)
ssh_ "cd $stage/src/windows/Unictrl && %USERPROFILE%\\.dotnet\\dotnet.exe publish Unictrl.csproj -c Release -p:Platform=x64 -o $stage/app" >"$log" 2>&1 || true
grep -E ' error |warning [A-Z]+[0-9]+|-> ' "$log" || true
# Never install over a working copy when the build failed.
if grep -q ' error ' "$log" || ! ssh_ "powershell -NoProfile -Command \"if (Test-Path $stage/app/Unictrl.exe) { exit 0 } else { exit 1 }\""; then
    rm -f "$log"
    echo "build failed; the installed Unictrl was left untouched" >&2
    exit 1
fi
rm -f "$log"
ssh_ "powershell -NoProfile -ExecutionPolicy Bypass -File $stage/launch.ps1"
