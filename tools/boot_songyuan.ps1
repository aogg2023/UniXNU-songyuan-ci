# Windows-native version of tools/boot_ios.sh for songyuan (no WSL).
# ADT -> payload -> loader boot.img -> fastboot boot (RAM only, never flashes).
#
#   .\tools\boot_songyuan.ps1 -Kernel <path> [-RootImage <device path>] [-Extents <json>]
#                             [-Cmdline "..."] [-NoFbcon] [-DryRun]
#
# Extents are read off the phone with /data/local/tmp/extents (the file must not move
# between that read and the boot: f2fs GC moves files, so re-read right before booting).
param(
    [string]$Kernel = '',
    [string]$Extents = '',
    [string]$RootDevicePath = '/data/local/tmp/iosroot.img',
    [string]$Cmdline = '-v debug=0xc cpus=1 keepsyms=1 rd=ufsroot0',
    [switch]$NoFbcon,
    [switch]$DryRun,
    [switch]$AllowExtentChange,
    [string]$Adb = 'E:\Android\platform-tools\adb.exe',
    [string]$Fastboot = 'E:\Android\platform-tools\fastboot.exe',
    [string]$Python = 'C:\Users\Administrator\AppData\Local\Programs\Python\Python311\python.exe',
    [string]$Serial = 'a928b15f'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
# heavy intermediates on E: (C: is tight); SONGYUAN_WORK overrides
$work = if ($env:SONGYUAN_WORK) { $env:SONGYUAN_WORK } else { 'E:\songyuan\bringup_work\songyuan' }
$adtOut = Join-Path $work 'adt\songyuan.adt'
$payloadOut = Join-Path $work 'payload\payload.bin'

if (-not $Kernel) {
    $Kernel = Get-ChildItem (Join-Path $work 'kernel') -Filter 'kernel.development.*' |
        Where-Object { $_.Extension -ne '.gz' } | Sort-Object LastWriteTime | Select-Object -Last 1 -ExpandProperty FullName
}
if (-not $Kernel -or -not (Test-Path $Kernel)) { throw 'no kernel: pass -Kernel or put one in bringup_work/songyuan/kernel' }

# 1. extents (fresh every boot: a stale table is how userdata got written wrongly before)
if (-not $Extents -and $Cmdline -match 'rd=ufsroot0') {
    if (-not (Test-Path $Adb)) { throw "adb not found: $Adb" }
    $raw = & $Adb -s $Serial shell "su -c '/data/local/tmp/extents $RootDevicePath'" 2>&1
    $json = ($raw | Where-Object { $_ -match '^\{' }) -join ''
    if (-not $json) { throw "could not read extents of $RootDevicePath : $raw" }
    $dir = Join-Path $repo 'device\extents'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $prev = Get-ChildItem $dir -Filter 'iosroot-*.json' | Sort-Object LastWriteTime | Select-Object -Last 1
    if ($prev -and -not $AllowExtentChange) {
        $old = (Get-Content $prev.FullName -Raw).Trim()
        if ($old -ne $json.Trim()) {
            throw "extents changed since $($prev.Name) - f2fs moved the file. Re-pin it (or pass -AllowExtentChange if the move is expected):`nold: $old`nnew: $json"
        }
    }
    $Extents = Join-Path $dir ('iosroot-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
    [System.IO.File]::WriteAllText($Extents, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
    "extents: $Extents"
}

# 2. ADT
$env:SONGYUAN_NO_FBCON = if ($NoFbcon) { '1' } else { $null }
$adtArgs = @((Join-Path $repo 'tools\mkadt_songyuan.py'), $adtOut)
if ($Extents) {
    if (-not (Test-Path $Extents)) { throw "missing extents json: $Extents" }
    $adtArgs += @('--root-extents', $Extents)
}
& $Python @adtArgs
if ($LASTEXITCODE) { throw 'mkadt failed' }

# 3. payload
$plArgs = @((Join-Path $repo 'tools\mkpayload.py'), $Kernel, $adtOut, $payloadOut, '--cmdline', $Cmdline)
& $Python @plArgs
if ($LASTEXITCODE) { throw 'mkpayload failed' }

# 4. loader boot image
& (Join-Path $repo 'shim\loader\build.ps1') -Out (Split-Path $payloadOut -Parent)
if ($LASTEXITCODE) { throw 'loader build failed' }
$img = Join-Path (Split-Path $payloadOut -Parent) 'loader\loader-boot.img'
"boot image: $img ($([math]::Round((Get-Item $img).Length/1MB,1)) MB)"
if ($DryRun) { 'dry run: not touching the phone'; return }

# 5. fastboot boot (RAM only)
& $Adb -s $Serial reboot bootloader
$ok = $false
foreach ($i in 1..30) {
    Start-Sleep -Seconds 2
    $dev = (& $Fastboot devices 2>&1) -join "`n"
    if ($dev -match 'fastboot') { $ok = $true; break }
}
if (-not $ok) { throw 'phone did not enter fastboot' }
$product = (& $Fastboot getvar product 2>&1 | Select-String '^product:') -replace '^product:\s*', ''
$product = ($product -join '').Trim()
"fastboot product: $product"
if ($product -notmatch 'songyuan|M098FE') { throw "fastboot device is '$product', expected songyuan" }
& $Fastboot boot $img
"booted; expect console text on the phone within a few seconds (watchdog resets after ~10-15 s)"
