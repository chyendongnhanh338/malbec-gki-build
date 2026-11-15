#!/usr/bin/env bash
# 把 scripts/patches/*.patch 应用到 ACK 源码树（幂等）
#
#   apply-patches.sh <srctree>
#
# 这些补丁只做一件事：让「打开某个 CONFIG」不改变任何现存字段的偏移，
# 并且不让 genksyms 看见新增字段，从而保持 modversions CRC 与原厂 GKI 一致。
# 没有它们，单是 CONFIG_SYSVIPC=y 就会让 2628 / 5372 个导出符号的 CRC 变化
# （struct task_struct 在中间多出 sysvsem/sysvshm 两个成员，后半段全部位移，
#   而 genksyms 会把 struct 定义递归展开进每个符号的哈希）。
set -euo pipefail

SRC=${1:?usage: apply-patches.sh <srctree>}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PATCHES=$(ls "$REPO"/scripts/patches/*.patch 2>/dev/null || true)

[ -z "$PATCHES" ] && { echo "no patches"; exit 0; }

for p in $PATCHES; do
  name=$(basename "$p")
  if git -C "$SRC" apply --reverse --check "$p" >/dev/null 2>&1; then
    echo "  = $name (already applied)"
    continue
  fi
  if ! git -C "$SRC" apply --check "$p" >/dev/null 2>&1; then
    echo "  ! $name does not apply cleanly — ACK 上游可能改了，需要更新补丁" >&2
    git -C "$SRC" apply --check "$p" || true
    exit 1
  fi
  git -C "$SRC" apply "$p"
  echo "  + $name"
done
