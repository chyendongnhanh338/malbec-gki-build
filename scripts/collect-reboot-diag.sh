#!/system/bin/sh
# 抓「随机重启」的现场证据
#
# 用法：
#   adb push collect-reboot-diag.sh /data/local/tmp/
#   adb shell su -c 'sh /data/local/tmp/collect-reboot-diag.sh /sdcard/reboot.txt'
#   adb pull /sdcard/reboot.txt
#
# 输出刻意做得短，只挑判读需要的东西。

OUT=${1:-}
[ -n "$OUT" ] && exec > "$OUT" 2>&1

echo "=== 1. 现在跑的是什么 ==="
uname -r
cat /proc/uptime 2>/dev/null | awk '{printf "uptime: %.0f 秒\n", $1}'
getprop sys.boot_completed
getprop ro.boot.slot_suffix

echo
echo "=== 2. 重启原因（最关键）==="
printf '%-28s %s\n' "ro.boot.bootreason" "$(getprop ro.boot.bootreason)"
printf '%-28s %s\n' "ro.boot.bootreason_extra" "$(getprop ro.boot.bootreason_extra)"
echo "--- /proc/cmdline ---"
tr ' ' '\n' < /proc/cmdline | grep -iE "bootreason|reason|reset|panic|watchdog" || echo "(cmdline 无相关字段)"

echo
echo "=== 3. dmesg 里的崩溃痕迹 ==="
dmesg 2>/dev/null | grep -iE "kernel panic|Unable to handle|Internal error|BUG:|Oops|watchdog|hardware watchdog|PON reason|boot reason|last reset|thermal.*shutdown|over.?temp|emergency" | tail -40

echo
echo "=== 4. pstore / ramoops ==="
ls -l /sys/fs/pstore/ 2>/dev/null || echo "(无 /sys/fs/pstore)"
for f in /sys/fs/pstore/*ramoops*; do
  [ -f "$f" ] && { echo "--- $f (tail 60) ---"; tail -60 "$f"; }
done

echo
echo "=== 5. Android dropbox（系统级崩溃记录）==="
ls -lt /data/system/dropbox 2>/dev/null | head -15
echo "--- 最近的条目摘要 ---"
for f in $(ls -t /data/system/dropbox/*.txt 2>/dev/null | head -6); do
  echo "### $f"
  head -12 "$f" 2>/dev/null
  echo
done

echo
echo "=== 6. tombstone ==="
ls -lt /data/tombstones 2>/dev/null | head -8

echo
echo "=== 7. 高通 minidump / ramdump ==="
ls -l /data/vendor/ramdump /data/vendor/qcom/dump 2>/dev/null | head -10

echo
echo "=== 8. 温度 / 电量（排除热关机、掉电）==="
for z in /sys/class/thermal/thermal_zone*; do
  t=$(cat "$z/temp" 2>/dev/null); n=$(cat "$z/type" 2>/dev/null)
  [ -n "$t" ] && printf '%-28s %s\n' "$n" "$t"
done | sort -k2 -rn | head -8
printf '%-28s %s\n' "capacity" "$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)"
printf '%-28s %s\n' "voltage_now" "$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null)"

echo
echo "=== 9. 加载的模块数（对比健康值 502）==="
grep -c '' /proc/modules 2>/dev/null

echo
echo "=== 10. 最近一次重启前的 logcat 尾部（假如同一次开机有记录）==="
logcat -b all -d -t 80 2>/dev/null | tail -40

echo
echo "=== done ==="
