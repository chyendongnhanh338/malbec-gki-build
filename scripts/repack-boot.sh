#!/usr/bin/env bash
# 用原厂 boot.img 换上自己编的 Image，重打包成可 fastboot 刷入的 boot_a.img
#
#   repack-boot.sh <stock-boot.img> <new-Image> <out-boot.img>
#
# 只替换 kernel 段：bootconfig / ramdisk / header 全部沿用原厂，
# 因为这台机器的 DTB（19 个，TunaP 是第 19 个）、622 个闭源 .ko、bootconfig
# 都在 vendor_boot 里，一个字都不要动。
#
# 需要 magiskboot：https://github.com/topjohnwu/Magisk/releases （取 magiskboot 二进制）
set -euo pipefail

STOCK=${1:?usage: repack-boot.sh <stock-boot.img> <new-Image> <out-boot.img>}
IMAGE=${2:?}
OUT=${3:?}

command -v magiskboot >/dev/null || {
  cat >&2 <<'EOF'
需要 magiskboot：
  curl -LO https://github.com/topjohnwu/Magisk/releases/latest/download/Magisk-vXX.zip
  解包后取 lib/arm64-v8a/libmagiskboot.so -> magiskboot
（host 侧也可以直接用 Magisk 源码里的 native/ 目录编译）
EOF
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

magiskboot unpack -h "$STOCK" -d "$work"
cp "$IMAGE" "$work/kernel"
( cd "$work" && magiskboot repack "$STOCK" "$OLDPWD/$OUT" )

echo "wrote $OUT"
echo
echo "刷入（A/B 设备，先确认 current-slot）："
echo "  fastboot --disable-verity --disable-verification flash vbmeta_a vbmeta.img"
echo "  fastboot flash boot_a $OUT"
echo "  fastboot reboot"
echo
echo "回滚：刷回原厂 stock-boot.img 到同一个槽位即可。"
