#!/usr/bin/env bash
# 用原厂 boot.img 换上自编 Image，重打包成可 fastboot 刷入的 boot.img
#
#   repack-boot.sh <stock-boot.img> <new-Image> <out-boot.img>
#
# 只替换 kernel 段：bootconfig / ramdisk / header / dtb 全部沿用原厂。
# 这台机器的 19 个 DTB（TunaP 是第 19 个）、622 个闭源 .ko、bootconfig
# 都在 vendor_boot 里，一个字都不要动。
#
# 依赖 magiskboot（Magisk 的 native 工具）：
#   - 从 Magisk release zip 里取 lib/arm64-v8a/libmagiskboot.so，重命名为 magiskboot
#   - 或 ubuntu: magiskboot 在 AUR / 自行编译 Magisk native/
#   - 或改用 AOSP 的 unpack_bootimg + mkbootimg 两步（见文件末尾注释）
set -euo pipefail

STOCK=${1:?usage: repack-boot.sh <stock-boot.img> <new-Image> <out-boot.img>}
IMAGE=${2:?}
OUT=${3:?}

[ -f "$STOCK" ] || { echo "找不到 $STOCK" >&2; exit 1; }
[ -f "$IMAGE" ] || { echo "找不到 $IMAGE" >&2; exit 1; }

command -v magiskboot >/dev/null || {
  cat >&2 <<'EOF'
需要 magiskboot。最简单的获取方式：

  # 任选其一
  1) 从 Magisk release zip 取出：
       unzip -o Magisk-v*.zip 'lib/arm64-v8a/libmagiskboot.so' -d /tmp/mb
       cp /tmp/mb/lib/arm64-v8a/libmagiskboot.so ~/.local/bin/magiskboot
       chmod +x ~/.local/bin/magiskboot
  2) Debian/Ubuntu 上从 Magisk 源码编：
       git clone --depth 1 https://github.com/topjohnwu/Magisk && cd Magisk/native
       # 按 README 用 NDK 或 host 工具链编 magiskboot
EOF
  exit 1
}

OUT_ABS=$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# magiskboot 是在当前目录展开的，不接受 -d 参数
cp "$STOCK" "$work/boot.img"
( cd "$work" && magiskboot unpack -h boot.img )

echo "--- 原厂 boot 拆解结果 ---"
ls -l "$work" | sed 's/^/  /'

# kernel 段：magiskboot 已解压成裸文件，直接覆盖
cp "$IMAGE" "$work/kernel"
echo "--- 替换 kernel: $(du -h "$IMAGE" | cut -f1) ---"

( cd "$work" && magiskboot repack boot.img "$OUT_ABS" )

echo
echo "wrote $OUT_ABS  ($(du -h "$OUT_ABS" | cut -f1))"
echo
echo "自检：重新拆开新 boot，确认 kernel 段与你给的 Image 一致"
work2=$(mktemp -d)
cp "$OUT_ABS" "$work2/boot.img"
( cd "$work2" && magiskboot unpack boot.img >/dev/null 2>&1 ) || true
if [ -f "$work2/kernel" ]; then
  a=$(sha256sum "$IMAGE" | cut -d' ' -f1)
  b=$(sha256sum "$work2/kernel" | cut -d' ' -f1)
  if [ "$a" = "$b" ]; then
    echo "  ✅ kernel 段一致（sha256 ${a:0:16}…）"
  else
    echo "  ⚠️ kernel 段不一致（可能是原厂压缩格式被保留，属正常；也可能替换失败）"
    echo "     stock-image: ${a:0:16}…  repacked: ${b:0:16}…"
  fi
fi
rm -rf "$work2"

cat <<EOF

刷入（A/B 设备，先确认当前槽位）：
  adb shell getprop ro.boot.slot_suffix        # 例如 _a
  fastboot --disable-verity --disable-verification flash vbmeta_a vbmeta.img
  fastboot flash boot_a $OUT_ABS
  fastboot reboot

回滚：
  fastboot flash boot_a stock-boot_a.img
  fastboot reboot

# 备选方案（没有 magiskboot 时，AOSP python 工具）：
#   pip install -U mkbootimg
#   unpack_bootimg --boot_img stock-boot.img --out /tmp/boot
#   mkbootimg --header_version 4 --kernel Image \\
#             --ramdisk /tmp/boot/ramdisk \\
#             --cmdline "\$(cat /tmp/boot/cmdline)" \\
#             --os_version \$(cat /tmp/boot/os_version) \\
#             --os_patch_level \$(cat /tmp/boot/os_patch_level) \\
#             --output new-boot.img
EOF
