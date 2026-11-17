#!/usr/bin/env python3
"""CRC 闸门：新编内核的 Module.symvers  vs  原厂 vendor_dlkm/vendor_boot 的 .ko

判定标准
--------
MISMATCH  某个符号新内核算出的 CRC 与厂商模块记录的 CRC 不同
          -> 该 .ko 加载时会报 "disagrees about version of symbol X"
          -> 无 Wi-Fi / 无触摸 / 卡开机动画。这是硬失败，退出码 1。

MISSING   厂商模块引用了某符号，而新内核 Module.symvers 里没有。
          --gki-symbols 给出 ABI 列表后，MISSING 会被拆成两类：
            missing_gki    符号本该由 GKI 导出（在 abi_gki_aarch64* 里）却没导出
                           -> TRIM 白名单没生效 / config 关掉了子系统。这是真问题。
            missing_vendor 不在 ABI 列表里，通常由另一个厂商模块自己导出
                           -> 正常，仅供参考。

STOCK-CUT 新内核缺少原厂内核本该导出的符号（给了 --stock-exports 时启用）。
          这是 TRIM_UNUSED_KSYMS 的典型症状：CRC 全对（闸门原来看不出问题），
          但内核少导出上百个原厂导出过的符号，某些厂商模块在 probe 期按名字查符号
          失败 -> 子系统起不来 -> 卡开机。硬失败，退出码 1。

TOO-FEW   新内核 Module.symvers 条数低于 --min-symvers
          -> 白名单没被 modpost 读到时的典型症状：导出被裁到只剩树内模块用到的那些，
             编出来的 Image 会让原厂 vendor 模块全部 "Unknown symbol"。
             这是本次踩过的坑，所以单独设成硬失败。

只依赖标准库（自带最小 ELF 解析，不需要 pyelftools）。

用法
----
  gate-crc.py <Module.symvers> <vendor modules dir> [options]

选项
  --gki-symbols FILE   abi_symbollist.raw（扁平格式），用于把 MISSING 分成
                       「本该 GKI 导出」和「厂商互导」两类
  --min-symvers N      symvers 条数下限，低于则失败（防白名单失效）
  --variant NAME       报告标题用
  --json out.json      机器可读结果

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
    ap.add_argument("--gki-symbols", default="")
    ap.add_argument("--min-symvers", type=int, default=0)
    ap.add_argument("--stock-exports", default="",
                    help="原厂内核导出符号清单（一行一个），要求新内核导出集合覆盖它")
    ap.add_argument("--trim", choices=["on", "off"], default="",
                    help="本次是否启用 CONFIG_TRIM_UNUSED_KSYMS，仅用于报告标注")
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

    gki = set()
    if args.gki_symbols:
        with open(args.gki_symbols, errors="replace") as fh:
            gki = {ln.strip() for ln in fh if ln.strip()}
    missing_gki = {k: v for k, v in missing.items() if k in gki} if gki else {}
    missing_vendor = {k: v for k, v in missing.items() if k not in gki} if gki else dict(missing)

    # section 边界标记不是真实导出，原厂清单里由 vmlinux 重建带出来的，忽略
    STOCK_ARTIFACTS = {"__start___ksymtab_gpl", "__stop___ksymtab_gpl",
                       "__start___ksymtab", "__stop___ksymtab"}
    stock = set()
    if args.stock_exports:
        with open(args.stock_exports, errors="replace") as fh:
            stock = {ln.strip() for ln in fh if ln.strip() and not ln.startswith("#")}
    stock_cut = sorted(stock - set(new) - STOCK_ARTIFACTS) if stock else []

    too_few = args.min_symvers and len(new) < args.min_symvers
    ok = not mismatches and not too_few and not stock_cut
    lines = [
        f"# CRC gate — variant `{args.variant or 'n/a'}`",
        "",
        f"- vendor modules scanned: **{len(kos)}** ({checked} with `__versions`"
        + (f", {len(no_versions)} without" if no_versions else "") + ")",
        f"- symbols in new Module.symvers: **{len(new)}**",
        f"- **MISMATCH: {len(mismatches)}** " + ("✅" if not mismatches else "❌"),
    ]
    if args.trim:
        lines.append(
            f"- TRIM_UNUSED_KSYMS: **{args.trim}** "
            + ("✅ 全导出" if args.trim == "off"
               else "⚠️ 会裁掉原厂导出过的符号，已实测导致卡开机，仅用于对照"))
    if stock:
        lines.append(
            f"- 原厂导出覆盖: **{len(stock) - len(stock_cut)}/{len(stock)}** "
            + ("✅" if not stock_cut else f"❌ 少 {len(stock_cut)} 个（TRIM 或 config 关掉了子系统）"))
    if args.min_symvers:
        lines.append(
            f"- exports: **{len(new)}** (min {args.min_symvers}) "
            + ("✅" if not too_few else "❌ 白名单没生效"))
    if gki:
        lines.append(
            f"- missing from ABI list (`abi_gki_aarch64*`): **{len(missing_gki)}** "
            + ("✅" if not missing_gki else "⚠️ 白名单里的符号没导出，检查 TRIM / config"))
        lines.append(f"- MISSING, 厂商互导（正常）: {len(missing_vendor)}")
    else:
        lines.append(f"- MISSING (informational, may be vendor→vendor exports): {len(missing)}")

    if too_few:
        lines += ["", "## 白名单没生效",
                  "",
                  f"新内核只导出了 {len(new)} 个符号，低于下限 {args.min_symvers}。",
                  "检查 `abi_symbollist.raw` 是否为**扁平格式**（一行一个符号、无缩进、无表头），"
                  "以及 modpost 是否在构建目录或 srctree 找到了它。", ""]

    if stock_cut:
        lines += ["", "## STOCK-CUT — 原厂导出过、这次没导出", "",
                  "CRC 全对不代表可用：厂商模块可能在 probe 期按名字查这些符号。",
                  "最常见原因是 `CONFIG_TRIM_UNUSED_KSYMS=y`，其次是某个子系统被 config 关掉了。", ""]
        for name in stock_cut[:40]:
            lines.append(f"- `{name}`")
        if len(stock_cut) > 40:
            lines.append(f"- …（共 {len(stock_cut)} 个）")

    if missing_gki:
        lines += ["", "<details><summary>missing_gki（前 30 条）</summary>", ""]
        for name in sorted(missing_gki)[:30]:
            lines.append(f"- `{name}` ← {len(missing_gki[name])} 个 .ko")
        lines += ["", "</details>"]

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
        "min_symvers": args.min_symvers,
        "too_few": bool(too_few),
        "mismatch": {k: {"new": v[0], "vendor": v[1], "kos": v[2]} for k, v in mismatches.items()},
        "missing": {k: v for k, v in missing.items()},
        "missing_gki": sorted(missing_gki),
        "missing_vendor_count": len(missing_vendor),
        "no_versions": no_versions,
        "trim": args.trim,
        "stock_exports": len(stock),
        "stock_cut": stock_cut,
    }
    with open(args.json, "w") as fh:
        json.dump(payload, fh, indent=1, sort_keys=True)

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
