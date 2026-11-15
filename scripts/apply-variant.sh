#!/usr/bin/env bash
# 把「设备真 config + 功能 fragment」合成一次构建用的 .config
#
#   apply-variant.sh <srctree> <outdir> <variant> <trim:on|off>
#
# variant: baseline | g1 | g1g2 | g1g2g3 | all
set -euo pipefail

SRC=${1:?usage: apply-variant.sh <srctree> <outdir> <variant> [trim]}
OUT=${2:?}
VARIANT=${3:?}
TRIM=${4:-on}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

DEVCFG="$REPO/config/device-6.6.87.config"
[ -f "$SRC/scripts/config" ] || { echo "not a kernel tree: $SRC" >&2; exit 1; }

case "$VARIANT" in
  baseline) FRAGS=() ;;
  g1)       FRAGS=(G1-container) ;;
  g1g2)     FRAGS=(G1-container G2-devices) ;;
  g1g2g3)   FRAGS=(G1-container G2-devices G3-network) ;;
  all)      FRAGS=(G1-container G2-devices G3-network G4-userns) ;;
  *) echo "unknown variant: $VARIANT" >&2; exit 2 ;;
esac

mkdir -p "$OUT"
cp "$DEVCFG" "$OUT/.config"

apply_frag() {
  local f=$1 line name val
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    if [[ "$line" =~ ^#[[:space:]]+(CONFIG_[A-Za-z0-9_]+)[[:space:]]+is[[:space:]]+not[[:space:]]+set ]]; then
      "$SRC/scripts/config" --file "$OUT/.config" -d "${BASH_REMATCH[1]#CONFIG_}"
      continue
    fi
    case "$line" in ''|'#'*) continue ;; esac
    name="${line%%=*}"; val="${line#*=}"
    [[ "$name" == CONFIG_* ]] || continue
    name="${name#CONFIG_}"
    case "$val" in
      y|m) "$SRC/scripts/config" --file "$OUT/.config" -e "$name" ;;
      n)   "$SRC/scripts/config" --file "$OUT/.config" -d "$name" ;;
      *)   "$SRC/scripts/config" --file "$OUT/.config" --set-str "$name" "$val" ;;
    esac
  done < "$f"
}

for f in "${FRAGS[@]:-}"; do
  [ -z "$f" ] && continue
  echo "  + $f"
  apply_frag "$REPO/config/features/$f.config"
done

if [ "$TRIM" = "off" ]; then
  echo "  ! TRIM_UNUSED_KSYMS disabled (escape hatch: export everything)"
  "$SRC/scripts/config" --file "$OUT/.config" -d TRIM_UNUSED_KSYMS
else
  bash "$REPO/scripts/make-symbollist.sh" "$SRC"
fi

make -C "$SRC" O="$OUT" ARCH=arm64 LLVM=1 olddefconfig >/dev/null
echo "variant=$VARIANT trim=$TRIM  -> $OUT/.config"
