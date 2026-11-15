#!/usr/bin/env bash
# 打印关键 CONFIG 状态 + 与设备原 config 的差异摘要
#   show-features.sh <.config> [device config]
set -uo pipefail
CFG=${1:-out/.config}
DEV=${2:-config/device-6.6.87.config}

keys="PID_NS IPC_NS SYSVIPC POSIX_MQUEUE USER_NS DEVTMPFS CGROUP_PIDS CGROUP_DEVICE \
CFS_BANDWIDTH MACVLAN IP6_NF_NAT NF_TABLES NETFILTER_XT_MATCH_ADDRTYPE \
MODVERSIONS CFI_CLANG TRIM_UNUSED_KSYMS UNUSED_KSYMS_WHITELIST PREEMPT \
LOCALVERSION ARM64_4K_PAGES"

echo "| option | value |"
echo "|---|---|"
for k in $keys; do
  v=$(grep -E "^(CONFIG_$k=|# CONFIG_$k is not set)" "$CFG" | head -1)
  [ -z "$v" ] && v="(absent)"
  echo "| \`$k\` | \`$(echo "$v" | cut -c1-70)\` |"
done

if [ -f "$DEV" ]; then
  echo
  echo "<details><summary>与设备原 config 的符号级差异（去掉注释与新增项）</summary>"
  echo
  echo '```diff'
  diff <(grep -E '^CONFIG_' "$DEV" | sort) <(grep -E '^CONFIG_' "$CFG" | sort) | head -120 || true
  echo '```'
  echo
  echo "</details>"
fi
