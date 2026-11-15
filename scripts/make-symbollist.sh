#!/usr/bin/env bash
# 生成 CONFIG_UNUSED_KSYMS_WHITELIST 需要的 abi_symbollist.raw
#
# 为什么要这一步：
#   设备 config 里是 CONFIG_UNUSED_KSYMS_WHITELIST="abi_symbollist.raw"，
#   但 ACK 源码树里没有这个文件 —— 官方 GKI 是 kleaf 在构建目录里生成的。
#   直接 make 会因为找不到白名单文件而报错。
#
# 为什么取「所有 abi_gki_aarch64* 的并集」：
#   TRIM_UNUSED_KSYMS 只保留「树里模块用到的 + 白名单里的」符号。
#   官方 GKI Image 导出的是 KMI 基础列表 ∪ 所有厂商列表（android/ 目录里
#   就有 abi_gki_aarch64_lenovo 和 abi_gki_aarch64_qcom，正是这台机器用的）。
#   少一份列表 = 少一批导出符号 = 对应厂商的 vendor_dlkm 模块加载失败。
#   所以这里宁多勿少：多导出的符号只是让 Image 大几十 KB，漏导出会直接废掉设备。
set -euo pipefail

SRC=${1:?usage: make-symbollist.sh <srctree> [output]}
OUT=${2:-$SRC/abi_symbollist.raw}

[ -d "$SRC/android" ] || { echo "no android/ dir in $SRC" >&2; exit 1; }

tmp=$(mktemp)
for f in "$SRC"/android/abi_gki_aarch64*; do
  base=$(basename "$f")
  case "$base" in
    *.stg|*.stg.allowed_breaks|*.xml|*_type_visibility) continue ;;
  esac
  # 列表格式：[abi_symbol_list] 头 + 每行两个空格缩进的符号名
  sed -n 's/^[[:space:]]\{1,\}\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*$/\1/p' "$f" >> "$tmp"
done

{
  echo '[abi_symbol_list]'
  sort -u "$tmp" | sed 's/^/  /'
} > "$OUT"
rm -f "$tmp"

echo "whitelist: $OUT  ($(grep -c '^  ' "$OUT") symbols from $(ls "$SRC"/android/abi_gki_aarch64* | wc -l) lists)"
