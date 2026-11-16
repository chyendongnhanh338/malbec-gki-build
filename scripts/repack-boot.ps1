<#
.SYNOPSIS
  用原厂 boot.img 换上自编的 Image，在 Windows 上重打包成可 fastboot 刷入的 boot.img。

.DESCRIPTION
  只替换 kernel 段，ramdisk / cmdline / header 字段全部沿用原厂。
  本机的 DTB、622 个闭源 .ko、bootconfig 都在 vendor_boot 里，不要动。

  依赖 AOSP 的两个纯 python 脚本（仓库没有的话脚本会自动 git clone 到 tools/mkbootimg）：
      https://android.googlesource.com/platform/system/tools/mkbootimg
  注意 PyPI 上并没有 mkbootimg 包，pip install mkbootimg 会 404。

  如果你已经会用 AnyKernel3 zip 在手机上直接刷，就不需要这个脚本。

.PARAMETER StockBoot
  原厂 boot_a.img（用 dd 备份出来的那个）

.PARAMETER Image
  自编的内核，比如 Image-all

.PARAMETER Out
  输出的新 boot.img

.EXAMPLE
  .\repack-boot.ps1 -StockBoot .\stock-boot_a.img -Image .\Image-all -Out .\new-boot_a.img
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StockBoot,
    [Parameter(Mandatory = $true)][string]$Image,
    [Parameter(Mandatory = $true)][string]$Out
)

$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string]$p) {
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p)
    if (-not (Test-Path -LiteralPath $full)) { throw "找不到文件: $full" }
    return $full
}

$stockPath = Resolve-FullPath $StockBoot
$imagePath = Resolve-FullPath $Image
$outPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out)

# ---------- 找 python ----------
$python = $null
foreach ($cand in @('py', 'python', 'python3')) {
    $cmd = Get-Command $cand -ErrorAction SilentlyContinue
    if ($cmd) { $python = $cmd.Source; break }
}
if (-not $python) { throw "找不到 python。装一个 Python 3.8+ 后重试（https://www.python.org/downloads/）" }

# ---------- 准备 AOSP mkbootimg 工具 ----------
# 注意：PyPI 上没有 mkbootimg 包（pip install mkbootimg 会 404），
# 必须用 AOSP 源码里的两个纯 python 脚本。
$mbtDir = $null
foreach ($cand in @(
        (Join-Path $PSScriptRoot '..\tools\mkbootimg'),
        (Join-Path $PSScriptRoot '..\..\mkbootimg'))) {
    if (Test-Path (Join-Path $cand 'mkbootimg.py')) { $mbtDir = (Resolve-Path $cand).Path; break }
}

if (-not $mbtDir) {
    $mbtDir = Join-Path $PSScriptRoot '..\tools\mkbootimg'
    if (-not (Test-Path (Join-Path $mbtDir 'mkbootimg.py'))) {
        Write-Host "获取 AOSP mkbootimg 工具 -> $mbtDir" -ForegroundColor Cyan
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            throw "需要 git（或用浏览器下载 https://android.googlesource.com/platform/system/tools/mkbootimg 解压到 tools/mkbootimg）"
        }
        if (Test-Path $mbtDir) { Remove-Item -Recurse -Force $mbtDir }
        New-Item -ItemType Directory -Path (Split-Path $mbtDir) -Force | Out-Null
        & git clone --depth 1 https://android.googlesource.com/platform/system/tools/mkbootimg $mbtDir
        if ($LASTEXITCODE -ne 0) { throw "克隆 mkbootimg 失败" }
    }
}

$mkbootimgPy  = Join-Path $mbtDir 'mkbootimg.py'
$unpackPy     = Join-Path $mbtDir 'unpack_bootimg.py'
if (-not (Test-Path $mkbootimgPy)) { throw "缺少 $mkbootimgPy" }
if (-not (Test-Path $unpackPy))    { throw "缺少 $unpackPy" }

# ---------- 拆原厂 boot ----------
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("repack-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null

try {
    Write-Host "拆解 $stockPath" -ForegroundColor Cyan
    $unpackOut = & $python $unpackPy --boot_img $stockPath --out $work
    $unpackOut | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) { throw "unpack_bootimg 失败" }

    $headerVersion = '4'
    $hvFile = Join-Path $work 'header_version'
    if (Test-Path $hvFile) { $headerVersion = (Get-Content $hvFile -Raw).Trim() }

    Write-Host "  header_version = $headerVersion" -ForegroundColor DarkGray
    Get-ChildItem $work | ForEach-Object {
        Write-Host ("  {0,-20} {1,10:N0} bytes" -f $_.Name, $_.Length) -ForegroundColor DarkGray
    }

    # ---------- 组包 ----------
    $argList = @(
        $mkbootimgPy,
        '--header_version', $headerVersion,
        '--kernel', $imagePath,
        '--pagesize', '4096',
        '--output', $outPath
    )

    $ramdisk = Join-Path $work 'ramdisk'
    if ((Test-Path $ramdisk) -and (Get-Item $ramdisk).Length -gt 0) {
        $argList += @('--ramdisk', $ramdisk)
    }

    $cmdline = $null
    $cmdlineFile = Join-Path $work 'cmdline'
    if (Test-Path $cmdlineFile) {
        $cmdline = (Get-Content $cmdlineFile -Raw).Trim()
    } else {
        $line = $unpackOut | Where-Object { $_ -match '^command line args:\s*(.*)$' } | Select-Object -First 1
        if ($line -and $line -match '^command line args:\s*(.*)$') { $cmdline = $Matches[1].Trim() }
    }
    if ($cmdline) { $argList += @('--cmdline', $cmdline) }

    $osVersionFile = Join-Path $work 'os_version'
    if (Test-Path $osVersionFile) {
        $osVersion = (Get-Content $osVersionFile -Raw).Trim()
        if ($osVersion) { $argList += @('--os_version', $osVersion) }
    }

    $osPatchFile = Join-Path $work 'os_patch_level'
    if (Test-Path $osPatchFile) {
        $osPatch = (Get-Content $osPatchFile -Raw).Trim()
        if ($osPatch) { $argList += @('--os_patch_level', $osPatch) }
    }

    # header v4 的 boot.img 有时带 dtb 段
    $dtb = Join-Path $work 'dtb'
    if ((Test-Path $dtb) -and (Get-Item $dtb).Length -gt 0) {
        $argList += @('--dtb', $dtb)
    }

    Write-Host "组包 -> $outPath" -ForegroundColor Cyan
    & $python @argList
    if ($LASTEXITCODE -ne 0) { throw "mkbootimg 失败" }

    $newSize = (Get-Item $outPath).Length
    Write-Host ("完成: {0} ({1:N0} bytes)" -f $outPath, $newSize) -ForegroundColor Green

    # ---------- 自检：重新拆开比对 kernel ----------
    $verify = Join-Path $work 'verify'
    New-Item -ItemType Directory -Path $verify | Out-Null
    & $python $unpackPy --boot_img $outPath --out $verify 2>$null | Out-Null
    $vKernel = Join-Path $verify 'kernel'
    if ($LASTEXITCODE -eq 0 -and (Test-Path $vKernel)) {
        $a = (Get-FileHash $imagePath -Algorithm SHA256).Hash
        $b = (Get-FileHash $vKernel   -Algorithm SHA256).Hash
        if ($a -eq $b) {
            Write-Host "  [OK] kernel 段与新 Image 一致 (sha256 $($a.Substring(0,16))...)" -ForegroundColor Green
        } else {
            Write-Warning "kernel 段不一致 —— 检查原厂 boot 的压缩格式，或改用 magiskboot 流程"
        }
    }

    Write-Host ""
    Write-Host "刷入（先确认槽位）:" -ForegroundColor Yellow
    Write-Host "  adb shell getprop ro.boot.slot_suffix"
    Write-Host "  fastboot --disable-verity --disable-verification flash vbmeta_a vbmeta.img"
    Write-Host "  fastboot flash boot_a `"$outPath`""
    Write-Host "  fastboot reboot"
    Write-Host ""
    Write-Host "回滚: fastboot flash boot_a stock-boot_a.img" -ForegroundColor Yellow
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
