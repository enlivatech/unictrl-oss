# Installs the published build to %LOCALAPPDATA%\Programs\Unictrl and starts it.
# An SSH session is not a desktop session, so a one-shot interactive scheduled task starts the app on
# the logged-in desktop. It runs elevated so it can also type into administrator windows.
$ErrorActionPreference = 'Continue'
Get-Process Unictrl -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
$app = Join-Path $env:LOCALAPPDATA 'Programs\Unictrl'
New-Item -ItemType Directory -Force $app | Out-Null
robocopy (Join-Path $PSScriptRoot 'app') $app /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
$exe = Join-Path $app 'Unictrl.exe'
$task = 'UnictrlLaunchOnce'
schtasks /delete /tn $task /f *>&1 | Out-Null
schtasks /create /tn $task /tr "`"$exe`"" /sc once /st 00:00 /it /rl highest /f *>&1 | Out-Null
schtasks /run /tn $task *>&1 | Out-Null
for ($i = 0; $i -lt 30; $i++) { Start-Sleep 1; if (Get-Process Unictrl -ErrorAction SilentlyContinue) { break } }
Start-Sleep 3
schtasks /delete /tn $task /f *>&1 | Out-Null
$running = Get-Process Unictrl -ErrorAction SilentlyContinue
if ($running) { "running: pid $($running.Id)" } else { 'not running' }
Get-Content (Join-Path $env:LOCALAPPDATA 'Unictrl\unictrl.log') -Tail 3 -ErrorAction SilentlyContinue
