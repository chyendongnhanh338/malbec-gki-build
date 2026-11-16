#!/usr/bin/env bash
# patch-ak3-nord.sh — 把上游 AnyKernel3 模板改成「boot.img 无 ramdisk」可用
#
# 背景：本设备（malbec / TB376FC）的 boot.img 是 header v4 且 RAMDISK_SZ=0，
# 通用 ramdisk 在 init_boot / vendor_boot 里，我们不碰。上游 AK3 的
# dump_boot/write_boot 会解包 ramdisk，找不到就：
#     No ramdisk found to unpack. Aborting...
#
# 修法用的是 AK3 源码注释里自己给的组合（"use split_boot to skip ramdisk unpack,
# e.g. for devices with init_boot ramdisk"）：
#     dump_boot;  ->  split_boot;
#     write_boot; ->  flash_boot;
# 顺带删掉模板里 init.rc / init.tuna.rc / fstab.tuna 的示例编辑（split_boot 后
# cwd 是包根，这些文件不存在，会刷 sed/cp 报错）。
#
# 用法：
#   scripts/patch-ak3-nord.sh /path/to/anykernel3-dir
#   cd /path/to/anykernel3-dir && zip -r -9 ../ak3-nord.zip . -x '.git*'
#
# 幂等：已经改过则不做任何事。
set -euo pipefail

DIR=${1:?用法: $0 <anykernel3 目录>}
AK=$DIR/anykernel.sh
[ -f "$AK" ] || { echo "找不到 $AK" >&2; exit 1; }

python3 - "$AK" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()

if re.search(r'^\s*split_boot;\s*$', s, re.M) and re.search(r'^\s*flash_boot;\s*$', s, re.M):
    print('已经打过补丁，跳过')
    sys.exit(0)

# 1) 活动行替换（只在 boot install 段，示例注释段里的 #dump_boot; 不动）
done_split = done_flash = False
out = []
for line in s.splitlines(True):
    if not done_split and re.match(r'^dump_boot;\s*(#.*)?$', line):
        out.append('split_boot;' + (line[len(line.rstrip('\n')):] or '\n'))
        done_split = True
        continue
    if not done_flash and re.match(r'^write_boot;\s*(#.*)?$', line):
        out.append('flash_boot;' + (line[len(line.rstrip('\n')):] or '\n'))
        done_flash = True
        continue
    out.append(line)
s = ''.join(out)

if not (done_split and done_flash):
    sys.exit('没找到活动的 dump_boot;/write_boot; 行，模板可能已变，请人工确认')

# 2) 注释掉模板里的 ramdisk 内文件编辑（split_boot 后这些文件不存在）
for name in ('init.rc', 'init.tuna.rc', 'fstab.tuna'):
    s = re.sub(r'^(?!#)((?:backup_file|replace_string|insert_line|append_file|patch_fstab)\s+[^;\n]*\b%s\b[^;\n]*;)'
               % re.escape(name), r'#\1', s, flags=re.M)

open(p, 'w').write(s)
print('已改：dump_boot->split_boot, write_boot->flash_boot，并注释掉 ramdisk 内文件编辑')
PY

echo '--- 关键行 ---'
grep -nE '^(split_boot|flash_boot);' "$AK"
echo
echo '提醒：tools/ 里必须是 aarch64 的 busybox / magiskboot / magiskpolicy（见 README 1.5）。'
