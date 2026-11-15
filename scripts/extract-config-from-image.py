#!/usr/bin/env python3
"""从内核 Image / vmlinux 里把内嵌的 .config 抠出来（CONFIG_IKCONFIG）

  extract-config-from-image.py <Image|vmlinux> [out.config]

原理：CONFIG_IKCONFIG=y 时内核把 gzip 压缩的 .config 夹在
IKCFG_ST … IKCFG_ED 标记之间。OTA 换了内核之后重跑这个脚本，
就能得到新的权威 config。
"""
import gzip
import hashlib
import sys

START, END = b"IKCFG_ST", b"IKCFG_ED"


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    blob = open(sys.argv[1], "rb").read()
    i, j = blob.find(START), blob.find(END)
    if i < 0 or j < i:
        sys.exit("no IKCFG_ST/IKCFG_ED — 这个内核没开 CONFIG_IKCONFIG，"
                 "改用设备上的 /proc/config.gz")
    cfg = gzip.decompress(blob[i + len(START):j])
    out = sys.argv[2] if len(sys.argv) > 2 else "device.config"
    with open(out, "wb") as fh:
        fh.write(cfg)
    print(f"{out}: {len(cfg)} bytes, {cfg.count(chr(10).encode())} lines")
    print("sha256:", hashlib.sha256(cfg).hexdigest())


if __name__ == "__main__":
    main()
