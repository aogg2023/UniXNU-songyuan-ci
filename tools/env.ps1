# Dot-source this in a new PowerShell before running the songyuan tools:
#   . .\tools\env.ps1
# It adds platform-tools / LLVM / GitHub CLI to PATH and exports GH_TOKEN from the
# credential Git already stores for this repo (nothing extra is written to disk).
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path $here -Parent

$env:Path = "E:\Android\platform-tools;E:\Android\llvm\bin;C:\Program Files\GitHub CLI;$env:Path"
$env:PYTHON = 'C:\Users\Administrator\AppData\Local\Programs\Python\Python311\python.exe'
# all heavy artifacts (kernel, payload, ADT, downloads, IPSW) stay on E:
$env:SONGYUAN_WORK = 'E:\songyuan\bringup_work\songyuan'
$env:SONGYUAN_DL = 'E:\songyuan\dl'
$env:SONGYUAN_IPSW = 'E:\songyuan\ipsw'

if (-not $env:GH_TOKEN) {
    $cred = "protocol=https`nhost=github.com`npath=aogg2023/UniXNU-songyuan`n`n" | git credential fill 2>$null
    $tok = (($cred -split "`n") | Where-Object { $_ -like 'password=*' }) -replace '^password=',''
    if ($tok) { $env:GH_TOKEN = $tok } else { Write-Warning 'no stored github credential for this repo; gh will be unauthenticated' }
}

# keep git talking through the local proxy (direct github is unreliable here)
git config --global --get http.proxy > $null 2>&1
if (-not (git config --global --get http.proxy)) { git config --global http.proxy http://127.0.0.1:7897; git config --global https.proxy http://127.0.0.1:7897 }

Set-Location $root
"env ready: adb $( (adb version 2>$null | Select-Object -First 1) )"
"repo: $root"
