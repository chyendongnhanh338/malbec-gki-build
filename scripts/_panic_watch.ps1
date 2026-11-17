# 在 PC 侧持续抓内核日志，设备 panic 重启也不会丢（文件在 PC 上）
#
# 用法：在 PowerShell 里
#   .\scripts\panic-watch.ps1            # 默认写 panic-capture.txt
#   .\scripts\panic-watch.ps1 C:\tmp\d.txt
#
# 然后另一窗口复现（停止容器），重启后在 panic-capture.txt 末尾找
# "Kernel panic" / "Unable to handle kernel" / "watchdog" / "BUG:"

param([string]$Out = "panic-capture.txt")

$ErrorActionPreference = "Continue"
Write-Host "capturing dmesg -> $Out  (Ctrl+C 结束)" -ForegroundColor Cyan
Write-Host "现在去复现：停止 droidspaces 容器。重启后回来看文件末尾。" -ForegroundColor Yellow

# dmesg -w 会一直流；adb 断开（重启）时管道结束
adb shell "cat /proc/kmsg" 2>&1 | ForEach-Object {
    $line = "$(Get-Date -Format 'HH:mm:ss') $_"
    Add-Content -Path $Out -Value $line
    Write-Host $line
}
Write-Host "adb 连接已断开（设备可能已重启）" -ForegroundColor Red
