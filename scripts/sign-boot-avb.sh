#!/usr/bin/env bash
# 把裸 Image 打成能直接 fastboot 刷入的 boot.img（带合法 AVB footer）
#
#   sign-boot-avb.sh <Image> <out-boot.img> [--stock-boot stock-boot_a.img]
#
# 为什么需要这一步：
#   本机 vbmeta 里 `boot` 是 **链式分区描述符**（chain partition），不是 hash 描述符：
#       Chain Partition descriptor: boot, rollback_index_location=3, pubkey=testkey
#   意思是 boot 分区靠**自己尾部**的 vbmeta 自证。所以只要用同一把私钥
#   （本 ROM 的 BOARD_AVB_KEY_PATH 就是 AOSP 公开的 testkey_rsa4096.pem）
#   给 boot 重签 footer，就完全不用碰 vbmeta。
#   没有 footer 的裸 boot 会被 ABL 判为无签名 → 直接掉 fastboot。
#
# 参数来源全部取自原厂 boot.img（--stock-boot），保证与原厂逐字段一致：
#   header_version=4, os_version/os_patch_level, partition_size=分区大小,
#   algorithm=SHA256_RSA4096, rollback_index, rollback_index_location, flags=0
set -euo pipefail

IMG=${1:?usage: sign-boot-avb.sh <Image> <out-boot.img> [--stock-boot stock.img]}
OUT=${2:?usage: sign-boot-avb.sh <Image> <out-boot.img> [--stock-boot stock.img]}
shift 2
STOCK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --stock-boot) STOCK=${2:?}; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=${WORK:-$REPO/.work}
mkdir -p "$WORK"

# ---------- 取 AOSP mkbootimg / avbtool / testkey ----------
fetch() {  # fetch <url> <out>
  [ -f "$2" ] && return 0
  curl -fsSL --retry 3 "$1" | base64 -d > "$2"
}
if [ ! -f "$WORK/mkbootimg.py" ]; then
  git clone --depth 1 -q https://android.googlesource.com/platform/system/tools/mkbootimg "$WORK/mkbootimg" 2>/dev/null || true
  ln -sf "$WORK/mkbootimg/mkbootimg.py" "$WORK/mkbootimg.py"
  ln -sf "$WORK/mkbootimg/unpack_bootimg.py" "$WORK/unpack_bootimg.py"
fi
fetch "https://android.googlesource.com/platform/external/avb/+/refs/heads/main/avbtool.py?format=TEXT" "$WORK/avbtool.py"
fetch "https://android.googlesource.com/platform/external/avb/+/refs/heads/main/test/data/testkey_rsa4096.pem?format=TEXT" "$WORK/testkey_rsa4096.pem"

# ---------- 若没给原厂 boot，则从设备树常量取默认值 ----------
if [ -n "$STOCK" ]; then
  [ -f "$STOCK" ] || { echo "找不到 $STOCK" >&2; exit 1; }
  info=$(python3 "$WORK/unpack_bootimg.py" --boot_img "$STOCK" --out "$WORK/stock_unpack" 2>&1)
  header_version=$(echo "$info" | sed -n 's/^boot image header version: //p')
  os_version=$(echo "$info"    | sed -n 's/^os version: //p')
  os_patch=$(echo "$info"      | sed -n 's/^os patch level: //p')
  partition_size=$(stat -c%s "$STOCK")
  avbinfo=$(python3 "$WORK/avbtool.py" info_image --image "$STOCK")
  algorithm=$(echo "$avbinfo"   | sed -n 's/^Algorithm:[[:space:]]*//p')
  rollback=$(echo "$avbinfo"    | sed -n 's/^Rollback Index:[[:space:]]*//p')
  rb_loc=$(echo "$avbinfo"      | sed -n 's/^Rollback Index Location:[[:space:]]*//p')
else
  header_version=4; os_version=16.0.0; os_patch=2026-10
  partition_size=100663296          # BOARD_BOOTIMAGE_PARTITION_SIZE
  algorithm=SHA256_RSA4096; rollback=1777939200; rb_loc=0
fi

echo "header_v=$header_version os=$os_version patch=$os_patch"
echo "partition_size=$partition_size alg=$algorithm rollback=$rollback rb_loc=$rb_loc"

# ---------- 组 boot.img（无 footer） ----------
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
python3 "$WORK/mkbootimg.py" --header_version "$header_version" \
        --kernel "$IMG" --os_version "$os_version" --os_patch_level "$os_patch" \
        --pagesize 4096 --output "$tmp/boot.img"

# ---------- 加 AVB footer ----------
python3 "$WORK/avbtool.py" add_hash_footer \
        --image "$tmp/boot.img" \
        --partition_name boot \
        --partition_size "$partition_size" \
        --algorithm "$algorithm" \
        --key "$WORK/testkey_rsa4096.pem" \
        --rollback_index "$rollback" \
        --rollback_index_location "$rb_loc" \
        --hash_algorithm sha256 >/dev/null

cp "$tmp/boot.img" "$OUT"

echo
echo "wrote $OUT ($(stat -c%s "$OUT") bytes)"
python3 "$WORK/avbtool.py" info_image --image "$OUT" | grep -E \
  "Original image size|Public key|Algorithm|Rollback Index:|Flags|Partition Name" | sed 's/^/  /'
