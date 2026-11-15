#!/usr/bin/env python3
"""CRC 闸门：新编内核的 Module.symvers  vs  原厂 vendor_dlkm/vendor_boot 的 .ko

判定标准
--------
MISMATCH  某个符号新内核算出的 CRC 与厂商模块记录的 CRC 不同
          -> 该 .ko 加载时会报 "disagrees about version of symbol X"
          -> 无 Wi-Fi / 无触摸 / 卡开机动画。这是硬失败，退出码 1。

MISSING   厂商模块引用了某符号，而新内核 Module.symvers 里没有
          -> 可能是被 CONFIG_TRIM_UNUSED_KSYMS 裁掉，也可能该符号本来就由
             另一个厂商模块导出（vendor->vendor）。仅供参考，不判失败；
             但如果数量异常多，说明白名单没生成对。

只依赖标准库（自带最小 ELF 解析，不需要 pyelftools）。

用法
----
  gate-crc.py <Module.symvers> <vendor modules dir> [--json out.json] [--variant g1]

退出码：0 = 无 MISMATCH；1 = 有 MISMATCH；2 = 输入有问题
"""
import argparse
import glob
import json
import os
import struct
import sys

MODVERSIONS_NAME_LEN = 56          # MODULE_NAME_LEN = 64 - sizeof(unsigned long)


# ---------- 最小 ELF 段读取 ----------

def elf_section(path, wanted):
    """返回 (data, user_ptr_size)；找不到返回 (None, ptr)。"""
    with open(path, "rb") as fh:
        blob = fh.read()
    if blob[:4] != b"\x7fELF":
        raise ValueError("not ELF")
    is64 = blob[4] == 2
    end = "<" if blob[5] == 1 else ">"

    if is64:
        (e_shoff,) = struct.unpack_from(end + "Q", blob, 0x28)
        e_shentsize, e_shnum, e_shstrndx = struct.unpack_from(end + "HHH", blob, 0x3A)
        hdr, ptr = end + "IIQQQQ", 8      # sh_name, sh_type, flags, addr, offset, size
    else:
        (e_shoff,) = struct.unpack_from(end + "I", blob, 0x20)
        e_shentsize, e_shnum, e_shstrndx = struct.unpack_from(end + "HHH", blob, 0x2E)
        hdr, ptr = end + "IIIIII", 4

    if not e_shoff or not e_shnum:
        return None, ptr

    heads = []
    for i in range(e_shnum):
        f = struct.unpack_from(hdr, blob, e_shoff + i * e_shentsize)
        heads.append((f[0], f[4], f[5]))     # name, offset, size

    if e_shstrndx >= len(heads):
        return None, ptr
    _, str_off, str_size = heads[e_shstrndx]
    strtab = blob[str_off:str_off + str_size]

    for sh_name, sh_offset, sh_size_ in heads:
        nm = strtab[sh_name:strtab.find(b"\0", sh_name)].decode("ascii", "replace")
        if nm in wanted:
            return blob[sh_offset:sh_offset + sh_size_], ptr
    return None, ptr


# ---------- 数据 ----------

def load_symvers(path):
    """Module.symvers: <crc-hex>\t<name>\t<module>\t<export-kind>"""
    syms = {}
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            try:
                syms[parts[1]] = int(parts[0], 16)
            except ValueError:
                continue
    return syms


def read_versions(path):
    """__versions 段：struct modversion_info { unsigned long crc; char name[56]; }"""
    try:
        data, ptr = elf_section(path, ("__versions", "__version"))
    except ValueError:
        return None
    if data is None:
        return {}
    size = ptr + MODVERSIONS_NAME_LEN
    out = {}
    for off in range(0, len(data) - size + 1, size):
        crc = int.from_bytes(data[off:off + ptr], "little")
        nm = data[off + ptr:off + size].split(b"\0")[0].decode("utf-8", "replace")
        if nm and nm.isprintable():
            out[nm] = crc
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("symvers")
    ap.add_argument("modules_dir")
    ap.add_argument("--json", default="gate.json")
    ap.add_argument("--variant", default="")
    args = ap.parse_args()

    new = load_symvers(args.symvers)
    kos = sorted(glob.glob(os.path.join(args.modules_dir, "**", "*.ko"), recursive=True))
    if not kos:
        print(f"no .ko under {args.modules_dir}", file=sys.stderr)
        sys.exit(2)

    mismatches, missing, no_versions = {}, {}, []
    checked = 0

    for ko in kos:
        vers = read_versions(ko)
        if vers is None:
            continue
        if not vers:
            no_versions.append(os.path.basename(ko))
            continue
        checked += 1
        base = os.path.basename(ko)
        for name, old_crc in vers.items():
            if name in new:
                if new[name] != old_crc:
                    ent = mismatches.setdefault(
                        name, [f"0x{new[name]:08x}", f"0x{old_crc:08x}", []])
                    ent[2].append(base)
            else:
                missing.setdefault(name, []).append(base)

    ok = not mismatches
    lines = [
        f"# CRC gate — variant `{args.variant or 'n/a'}`",
        "",
        f"- vendor modules scanned: **{len(kos)}** ({checked} with `__versions`"
        + (f", {len(no_versions)} without" if no_versions else "") + ")",
        f"- symbols in new Module.symvers: **{len(new)}**",
        f"- **MISMATCH: {len(mismatches)}** " + ("✅" if ok else "❌"),
        f"- MISSING (informational, may be vendor→vendor exports): {len(missing)}",
    ]

    if mismatches:
        lines += ["", "## MISMATCH — 这些符号的 ABI 被这次 config 改动了", "",
                  "| symbol | new CRC | vendor CRC | affected .ko |", "|---|---|---|---|"]
        for name, (a, b, ko_list) in sorted(mismatches.items()):
            names = ", ".join(f"`{k}`" for k in ko_list[:3])
            more = f" (+{len(ko_list) - 3})" if len(ko_list) > 3 else ""
            lines.append(f"| `{name}` | `{a}` | `{b}` | {names}{more} |")

    if missing:
        lines += ["", "<details><summary>MISSING 明细（前 40 条）</summary>", ""]
        for name in sorted(missing)[:40]:
            lines.append(f"- `{name}` ← {len(missing[name])} 个 .ko")
        lines += ["", "</details>"]

    print("\n".join(lines))

    payload = {
        "variant": args.variant,
        "modules": len(kos),
        "scanned": checked,
        "symvers": len(new),
        "mismatch": {k: {"new": v[0], "vendor": v[1], "kos": v[2]} for k, v in mismatches.items()},
        "missing": {k: v for k, v in missing.items()},
        "no_versions": no_versions,
    }
    with open(args.json, "w") as fh:
        json.dump(payload, fh, indent=1, sort_keys=True)

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
