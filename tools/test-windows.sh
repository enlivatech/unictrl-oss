#!/bin/sh
# Runs the Windows unit tests on the laptop over SSH (the WinUI app itself only builds there).
set -eu

host="${UNICTRL_WINDOWS_HOST:?Set UNICTRL_WINDOWS_HOST to user@your-pc}"
key="${UNICTRL_WINDOWS_KEY:-$HOME/.ssh/id_ed25519}"
stage='unictrl-test' # relative to the Windows user's home folder
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ssh_() { ssh -i "$key" -o LogLevel=ERROR "$host" "$@"; }
scp_() { scp -q -r -i "$key" -o LogLevel=ERROR "$@"; }

ssh_ "powershell -NoProfile -Command \"Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $stage/windows, $stage/tests | Out-Null\""
scp_ "$repo/windows/Unictrl" "$repo/windows/Unictrl.Tests" "$host:$stage/windows/"
scp_ "$repo/tests/contract" "$host:$stage/tests/"
ssh_ "cd $stage/windows/Unictrl.Tests && %USERPROFILE%\\.dotnet\\dotnet.exe test --nologo -v q"
