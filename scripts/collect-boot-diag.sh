#!/system/bin/sh
# 在「卡开机但 adb 可用」的机器上采集启动诊断信息
#
# 用法（PC 上执行）：
#   adb push collect-boot-diag.sh /data/local/tmp/
#   adb shell su -c 'sh /data/local/tmp/collect-boot-diag.sh' > diag.txt 2>&1
#   # 或者让脚本自己写文件：
#   adb shell su -c 'sh /data/local/tmp/collect-boot-diag.sh /sdcard/diag.txt'
#   adb pull /sdcard/diag.txt
#
# 输出刻意做得短（默认 < 400 行），只挑判断需要的东西。

OUT=${1:-}
if [ -n "$OUT" ]; then
  exec > "$OUT" 2>&1
fi

echo "=== 1. 内核 ==="
uname -a
echo "--- /proc/version ---"
cat /proc/version
echo "--- 关键 CONFIG（从 /proc/config.gz）---"
if [ -r /proc/config.gz ]; then
  zcat /proc/config.gz | grep -E '^CONFIG_(PID_NS|IPC_NS|SYSVIPC|POSIX_MQUEUE|USER_NS|DEVTMPFS|CGROUP_PIDS|CGROUP_DEVICE|MACVLAN|NF_TABLES)=' || echo "(none of the target configs are set)"
else
  echo "no /proc/config.gz"
fi

echo
echo "=== 2. 启动进度 ==="
for p in sys.boot_completed dev.bootcomplete ro.boot.veritymode ro.boot.verifiedbootstate \
         ro.boot.flash.locked ro.boot.slot_suffix ro.build.fingerprint; do
  printf '%-32s %s\n' "$p" "$(getprop $p)"
done

echo
echo "=== 3. 模块加载情况 ==="
echo "已加载模块数: $(grep -c '^[a-zA-Z0-9_]' /proc/modules 2>/dev/null)"
echo "--- dmesg 里的模块错误（关键）---"
dmesg 2>/dev/null | grep -iE "disagrees about version|Unknown symbol|invalid module format|module verification failed|not signed|taint" | head -40
echo "--- 最近 30 条 dlkm/module 相关 dmesg ---"
dmesg 2>/dev/null | grep -iE "dlkm|\.ko|module" | tail -30

echo
echo "=== 4. 关键分区挂载 ==="
mount 2>/dev/null | grep -E " /(system|vendor|product|system_ext|odm|vendor_dlkm|system_dlkm|data|metadata) " \
  || cat /proc/mounts | grep -E " /(system|vendor|product|system_ext|odm|vendor_dlkm|system_dlkm|data|metadata) "

echo
echo "=== 5. SELinux / dm-verity 报错 ==="
dmesg 2>/dev/null | grep -iE "avc: *denied|dm-verity|verity.*(error|fail)|EIO" | tail -25

echo
echo "=== 6. 未起来的关键服务 ==="
for svc in surfaceflinger audioserver media system_server vendor.audio-hal; do
  printf '%-24s %s\n' "$svc" "$(getprop init.svc.$svc)"
done
echo "--- 进程快照（前 25 个非内核进程）---"
ps -A -o PID,NAME 2>/dev/null | grep -vE "^ *[0-9]+ +\[" | head -26

echo
echo "=== 7. 崩溃日志 ==="
echo "--- logcat -b crash（尾 60 行）---"
logcat -b crash -d -t 60 2>/dev/null | tail -60
echo "--- tombstone 数量 ---"
ls /data/tombstones 2>/dev/null | wc -l

echo
echo "=== 8. 卡住处最近的系统日志（尾 60 行，含错误）---"
logcat -d -t 200 2>/dev/null | grep -iE " (E|F) " | tail -60

echo
echo "=== done ==="
