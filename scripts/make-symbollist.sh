#!/usr/bin/env bash
# 生成 CONFIG_UNUSED_KSYMS_WHITELIST 需要的 abi_symbollist.raw
#
# 为什么要这一步：
#   设备 config 里是 CONFIG_UNUSED_KSYMS_WHITELIST="abi_symbollist.raw"，
#   但 ACK 源码树里没有这个文件 —— 官方 GKI 是 kleaf 在构建目录里生成的。
#
# 格式（踩过的坑，别改）：
#   modpost 的 handle_white_list_exports() 是这么读的：
#       while ((name = strsep(&p, "\n")))
#               if ((sym = find_symbol(name))) sym->used = true;
#   —— 整行直接当符号名去查，**没有 trim、没有注释、没有 [abi_symbol_list] 头**。
#   而 android/abi_gki_aarch64* 是带 `[abi_symbol_list]` 头 + 两空格缩进的格式。
#   直接把那个文件喂进去，find_symbol("  add_timer") 全部返回 NULL，
#   白名单等于空表，导出符号被裁到只剩「树内模块用到的」那些
#   （实测 9394 个白名单符号 → Module.symvers 只有 1690 条），
#   编出来的 Image 会让 622 个原厂 vendor 模块全部 "Unknown symbol"。
#   所以这里必须输出**扁平的一行一个符号**。
#
# 为什么取「所有 abi_gki_aarch64* 的并集」：
#   官方 GKI Image 导出的是 KMI 基础列表 ∪ 所有厂商列表（android/ 里就有
#   abi_gki_aarch64_lenovo 和 abi_gki_aarch64_qcom，正是这台机器用的）。
#   多导出几十 KB，漏导出直接废掉设备。
set -euo pipefail

SRC=${1:?usage: make-symbollist.sh <srctree> [extra outdir...]}
shift || true
OUTS=("$SRC/abi_symbollist.raw" "$@")

[ -d "$SRC/android" ] || { echo "no android/ dir in $SRC" >&2; exit 1; }

tmp=$(mktemp)
lists=0
for f in "$SRC"/android/abi_gki_aarch64*; do
  base=$(basename "$f")
  case "$base" in
    *.stg|*.stg.allowed_breaks|*.xml|*_type_visibility) continue ;;
  esac
  # 列表格式：[abi_symbol_list] 头 + 每行两个空格缩进的符号名
  if sed -n 's/^[[:space:]]\{1,\}\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*$/\1/p' "$f" >> "$tmp"; then
    lists=$((lists + 1))
  fi
done

# 扁平化：去重、排序、一行一个符号，无缩进无表头
sort -u "$tmp" > /tmp/symbollist.flat
rm -f "$tmp"

for out in "${OUTS[@]}"; do
  mkdir -p "$(dirname "$out")"
  cp /tmp/symbollist.flat "$out"
done
rm -f /tmp/symbollist.flat

echo "whitelist: ${OUTS[0]}  ($(wc -l < "${OUTS[0]}") flat symbols from $lists lists)"
