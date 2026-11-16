# malbec-gki-build

给 **Lenovo Idea Tab Pro Gen 2（`malbec` / TB390FU，Qualcomm SM8735P）** 自编 GKI 内核的构建仓库。

目标不是"编个能开机的内核"，而是**在补齐容器所需内核能力的同时，不破坏原厂闭源 vendor 模块的 ABI**。所以每组的产物都要过一道 `Module.symvers` vs 厂商 `.ko` 的 CRC 闸门。

## 设备事实（已核实）

| 项 | 值 | 依据 |
|---|---|---|
| 内核 | `6.6.87-android15-8-…-4k`，**未改动的 Google GKI 2.0 Image** | `device/lenovo/malbec/BoardConfig.mk` 注明 "stock Google GKI image; nothing is built from source"；`malbec-kernel/images/kernel` 与原厂 byte-identical |
| KMI | generation **8**，4 KiB 页，`PREEMPT=y` | 从 Image 内嵌 config（`IKCFG_ST`）解析 |
| 工具链 | `Android (11368308, +pgo,+bolt,+lto,+mlgo) clang 18.0.0` = **r510928** | `CONFIG_CC_VERSION_TEXT`；ACK `build.config.constants: CLANG_VERSION=r510928` |
| vendor 侧 | `vendor_dlkm` 300 + `vendor_boot` 322 + `system_dlkm` 96 个闭源 `.ko` | `malbec-kernel/README.md` |
| 原厂缺失 | `PID_NS` `SYSVIPC`（→`IPC_NS` 选项都不存在）`POSIX_MQUEUE` `USER_NS` `DEVTMPFS` `CGROUP_PIDS` `CGROUP_DEVICE` `CFS_BANDWIDTH` `MACVLAN` `IP6_NF_NAT` `NF_TABLES` `XT_MATCH_ADDRTYPE` | 解析出的真 config，见 `config/device-6.6.87.config` |
| AVB | `BOARD_AVB_ENABLE := true`，flags 0，解锁下 verity 失败降级 `eio` | 同上 |

`config/device-6.6.87.config` 是**设备内核自己的 config**（从 `Image` 的 `IKCFG_ST…IKCFG_ED` gzip 段解出来的），不是 `gki_defconfig`。用它对 ABI 才有意义：CRC 由 `genksyms` 按「头文件声明文本 + 配置」算出，config 差一项就可能全变。

## 快速使用（拿到产物之后）

### 0. 先确认闸门是绿的

每次运行的 Summary 里第一段就是 CRC gate。**`MISMATCH` 必须是 0**，否者不要刷——
那意味着这批 config 改动了某个导出符号的 ABI，刷上去对应厂商驱动会加载失败（无 Wi-Fi / 无触摸）。

### 1. 下载产物

```bash
# 换成你那次运行的 id（Actions 页面 URL 里 /runs/ 后面那串数字）
RUN=43866088759
gh run download "$RUN" -R <你的账号>/malbec-gki-build -n malbec-gki-all -D img
ls -lh img/out/arch/arm64/boot/Image      # 约 36 MB
ls img/gate-all.md                        # 闸门报告
```

产物内容：`out/arch/arm64/boot/Image`（内核）、`out/Module.symvers`、
`out/.config`（这次实际用的配置）、`gate-<variant>.{md,json}`、`build.log`。

### 1.5 三种刷入方式，按你的环境挑一个

| 你的环境 | 用哪个 | 需要 PC 吗 |
|---|---|---|
| 有第三方 recovery（TWRP / OrangeFox） | 在 recovery 里「安装」`ak3-all.zip` | 不需要 |
| 装了内核管理 App（EX Kernel Manager / FK Kernel Manager / SmartPack） | App 里刷 `ak3-all.zip`（AK3 zip 它直接支持） | 不需要 |
| 只有 Magisk / KernelSU，没有自定义 recovery | **不能**用模块安装器刷 AK3 zip（它不是模块格式，没有 `module.prop`）→ 走 PC 的 fastboot 路线 | 需要 |
| 有 PC（Windows 也行） | `scripts/repack-boot.ps1`（Windows）/ `scripts/repack-boot.sh`（Linux）重打包后 `fastboot flash boot_a` | 需要 |

> AnyKernel3 zip 的定位是「recovery 刷机包」，只换 `boot` 分区的 kernel 段。
> Magisk / KernelSU 的「模块 → 从本地安装」会报 *Not a Magisk module* 而拒绝，这不是包坏了。

**注意：上游 AnyKernel3 模板自带的是 32 位 ARM 的 `busybox` / `magiskboot` / `magiskpolicy`**，
在 64 位-only 的 Android 上会直接失败：

```
Busybox setup failed. Aborting...
```

打 zip 前必须换成 aarch64 版（从 Magisk APK 的 `lib/arm64-v8a/` 取 `libbusybox.so`
→ `tools/busybox`、`libmagiskboot.so` → `tools/magiskboot`、`libmagiskpolicy.so` → `tools/magiskpolicy`）。
`scripts/repack-boot.sh` / `.ps1` 的 fastboot 路线不受这个限制。

**第二个必改点：本设备的 `boot.img` 没有 ramdisk。** Header v4、`RAMDISK_SZ=0`
（通用 ramdisk 在 `init_boot` / `vendor_boot`，本包不碰它们）。
AK3 模板默认的 `dump_boot` / `write_boot` 会去解包 ramdisk，找不到就直接中止：

```
No ramdisk found to unpack. Aborting...
```

按 AK3 源码自己的注释（`anykernel.sh` 里写着 *use split_boot to skip ramdisk unpack,
e.g. for devices with init_boot ramdisk*），改成：

```sh
dump_boot;   ->  split_boot;
write_boot;  ->  flash_boot;
```

并删掉模板里 `init.rc` / `init.tuna.rc` / `fstab.tuna` 的示例编辑（那些只在解包出的
ramdisk 目录里才有意义，`split_boot` 后 cwd 是包根，会报 *can't read init.rc*）。
`magiskboot repack` 在没有 `ramdisk.cpio` 时会保留原图的 `ramdisk_size`（=0），
只替换 kernel 段——这一点已用合成镜像端到端验证过。
现成产物：release `v1.2` 的 `ak3-all-arm64-nord.zip`。

### 2. 备份原厂 boot，只换 kernel 段

```bash
# 备份（先确认当前槽位）
adb shell getprop ro.boot.slot_suffix            # 例如 _a
adb shell 'dd if=/dev/block/by-name/boot_a of=/data/local/tmp/boot_a.img bs=1M'
adb pull /data/local/tmp/boot_a.img ./stock-boot_a.img

# 用原厂 boot.img 换上自编 Image（脚本会自动自检 kernel 段 sha256）
scripts/repack-boot.sh stock-boot_a.img img/out/arch/arm64/boot/Image new-boot_a.img
```

**不要动 `vendor_boot`**：19 个 DTB（TunaP 是第 19 个）、622 个闭源 `.ko`、
bootconfig 全在里面。

### 3. 刷入

```bash
fastboot --disable-verity --disable-verification flash vbmeta_a vbmeta.img
fastboot flash boot_a new-boot_a.img
fastboot reboot
```

### 4. 验收

```sh
su -c 'zcat /proc/config.gz | grep -E "CONFIG_(PID_NS|IPC_NS|USER_NS|DEVTMPFS|CGROUP_PIDS)="'
su -c 'unshare -pf --mount-proc true && echo PIDns_OK'
su -c 'unshare -i true && echo IPCns_OK'
su -c 'unshare -U true && echo USERns_OK'
su -c 'ls -l /dev | head'            # 有真实设备节点 = DEVTMPFS 生效
su -c 'droidspaces check'            # 应该全绿，且不需要加载任何 .ko
```

### 5. 回滚

```bash
fastboot flash boot stock-boot_a.img     # A/B 设备会写到当前槽
fastboot reboot
```

现成的回滚资产在 release `v1.2`：

| 资产 | 用法 |
|---|---|
| `stock-boot_a-restore.img.zip` | 解压得 `stock-boot_a.img`（内核段 = 原厂 `6.6.87-android15-8`，与设备原图 sha256 一致）→ `fastboot flash boot` |
| `ak3-stock-restore.zip` | 刷不进 fastboot 但能进 recovery 时用：同样是 AnyKernel3 形态，把**原厂内核**写回 boot |

> **卡 logo 后第一件事是把原厂 boot 刷回来，别急着二次尝试。**
> 刷回来能正常开机后，`/sys/fs/pstore/console-ramoops*` 里通常还留着上一次失败启动的
> 内核日志（pstore 跨重启保留），这是唯一能定位「为什么没起来」的证据：
> `adb shell su -c 'cat /sys/fs/pstore/console-ramoops*' > ramoops.txt`

bootloader 一直在，风险窗口只有「刷完 `boot_a` 到确认能开机」这一段。

### 6. 选哪一档

| 你要什么 | 用哪个变体 |
|---|---|
| 跑容器（最小） | `g1` — PID/IPC/SysV/mqueue |
| **推荐**：容器 + 真实 `/dev` + 容器独立 IP + uid 隔离 | **`all`**（本仓库已验证 0 失配） |
| 想完全避开 userns 语义风险 | `safe`（= `all` 去掉 cgroup pids/device 与 nftables） |
| 需要 `--pids-limit` / 设备白名单 | `all`（`CGROUP_PIDS`/`CGROUP_DEVICE` 已开） |
| 需要 `--cpus` 限额 | **不支持**，见 `config/features/X1-cfsbw.config` 的说明 |

### 7. OTA 之后

PixelOS 更新内核会覆盖 `boot_a`，需要重编一次：

```bash
# 1) 取新内核的 config（IKCONFIG_PROC=y，设备上就能拿）
adb shell 'su -c "zcat /proc/config.gz"' > config/device-6.6.87.config
#    或者从 boot.img 里的 IKCFG_ST 段解出来：
#    python3 scripts/extract-config-from-image.py kernel.img config/device-6.6.87.config

# 2) 先跑 baseline，确认工具链+新 config 仍能复现原厂 ABI（必须 0 失配）
gh workflow run build.yml -f variants=baseline -f trim=on

# 3) 再跑 all
gh workflow run build.yml -f variants=all -f trim=on
```

### 8. 想加/减功能

- 改 `config/features/*.config`（或加一个新的），在 `scripts/apply-variant.sh` 里登记成新变体；
- **新开关第一次一定要单独跑**（像 `e-devtmpfs` 那样一个开关一个变体），看它对 CRC 的影响；
- 若失配，先判断属于哪一类：
  - 成员插在枢纽结构体中间 / 数组尺寸变化 → 可用「挪到尾部 + `#ifndef __GENKSYMS__`」补丁（见 `scripts/patches/`）；
  - **按值内嵌的结构体变大**（如 `cfs_rq` → `struct rq`）→ **不要修**，会变绿但读写错位，属静默错误。

## 为什么需要 CRC 闸门

模块能否加载取决于 `.ko` 的 `__versions` 段里的 CRC 与内核 `__kcrctab` 是否一致（`CONFIG_MODVERSIONS=y`）。vermagic 的版本段在模块带 CRC 时会被 `same_magic()` 跳过——这台机器的 vendor 模块是 **6.6.92** 编的，装进 **6.6.87** 内核，就是靠这一点。

所以：**放开任何一个 `CONFIG`，都可能改掉某个导出符号的 CRC，导致对应的闭源驱动加载失败**（无 Wi-Fi / 无触摸 / 卡开机动画）。闸门把这件事故变成红色构建：

```bash
python3 scripts/gate-crc.py out/Module.symvers vk/modules --variant g1
```

- `MISMATCH` = 这个符号 ABI 变了 → **硬失败**
- `MISSING` = 厂商模块引用了、我们的内核没导出 → 仅供参考（多数是 vendor→vendor 互导），数量异常多说明白名单没生成对

## 变体

| variant | 打开 | 目的 |
|---|---|---|
| `baseline` | 无 | **基线复现**：证明工具链 + config 能复现原厂 ABI（应当 0 MISMATCH）。这步不过，后面都别谈 |
| `g1` | `SYSVIPC` `IPC_NS` `PID_NS` `POSIX_MQUEUE` | 容器必需（droidspaces 的 MUST HAVE） |
| `g1g2` | + `DEVTMPFS` `CGROUP_PIDS` `CGROUP_DEVICE` `CFS_BANDWIDTH` | `/dev` 真节点 + 原生限额 |
| `g1g2g3` | + `MACVLAN` `IP6_NF_NAT` `NF_TABLES` `XT_MATCH_ADDRTYPE` | 容器网络 |
| `all` | + `USER_NS` | 真隔离（LKM 路线永远做不到的一项，也最可能破 CRC） |

分组的意义：坏了能精确定位到哪一组、哪个符号，从而只回退那一组。

## 用法

1. Fork / 推到自己的**公共**仓库（公共仓库的 Actions 标准 runner 免费不限分钟，4 vCPU / 16 GB）。
2. Actions → `build-malbec-gki` → Run workflow：
   - `variants`：先只填 `baseline`，确认闸门 0 MISMATCH；
   - 再跑 `g1`，通过后跑 `g1g2` …
   - `trim`：默认 `on`。若 `baseline` 的 `MISSING` 异常多，试 `off`（全导出，Image 略大但彻底排除裁剪问题）。
3. 每次运行在 Summary 里给出：关键 CONFIG 表、与设备原 config 的差异、闸门报告、build.log 尾部。
4. 产物：`Image`、`Module.symvers`、`.config`、闸门 JSON/MD。

跑通之后打 tag（`v1`）会自动发 release 聚合所有 `Image`。

## 拿到 Image 之后

**本仓库不产出 `boot.img`，也不刷机。** 只换 kernel，`vendor_boot` 一个字不动（DTB 19 = TunaP、622 个 `.ko`、bootconfig 都在里面）：

```bash
# 1. 先备份（务必）
adb shell 'dd if=/dev/block/by-name/boot_a of=/data/local/tmp/boot_a.img bs=1M'
adb pull /data/local/tmp/boot_a.img ./stock-boot_a.img

# 2. 用原厂 boot.img 换上自编 Image
scripts/repack-boot.sh stock-boot_a.img Image-baseline new-boot_a.img

# 3. 刷（A/B，先确认 current-slot）
fastboot --disable-verity --disable-verification flash vbmeta_a vbmeta.img
fastboot flash boot_a new-boot_a.img
fastboot reboot
```

验收：

```sh
su -c 'zcat /proc/config.gz | grep -E "CONFIG_(PID_NS|SYSVIPC|IPC_NS|USER_NS|DEVTMPFS)="'
su -c 'unshare -pf --mount-proc true && echo "PIDns OK"'
su -c 'unshare -U true; echo "userns rc=$?"'
su -c 'droidspaces check'
```

回滚：把 `stock-boot_a.img` 刷回同一槽位。bootloader 在，风险窗口只有"刷 `boot_a` 之后到确认能开机"这一段。

## 实现细节（踩过的坑，别改）

1. **`CONFIG_UNUSED_KSYMS_WHITELIST="abi_symbollist.raw"` 在源码树里不存在**——官方是 kleaf 在构建目录生成的。`scripts/make-symbollist.sh` 用 `android/abi_gki_aarch64*` 的**并集**生成它。并集而不是单份，是因为官方 GKI Image 导出的是 KMI 基础列表 ∪ 所有厂商列表（`android/` 里就有 `abi_gki_aarch64_lenovo`、`abi_gki_aarch64_qcom`）；少一份等于少一批导出符号，直接废掉对应厂商的驱动。
2. **不要用 `gki_defconfig`**，会丢掉设备真实的裁剪状态，CRC 全变。
3. **`CONFIG_LTO_NONE=y`**（不是 thin）——设备侧就是 none，别改。
4. **clang 必须 r510928**：`CONFIG_CFI_CLANG=y`，编译器不一致 → 加载即 `CFI failure` → 重启。
5. **磁盘**：`ubuntu-24.04` 根分区约 14 GB，`DEBUG_INFO` + BTF 的 `out/` 会超，workflow 第一步先删掉预装 SDK 腾 ~25 GB。
6. **`make Image modules` 必须带 `set -o pipefail`**，否则 `| tee build.log` 会吞掉编译失败。

## 已知限制

- **没有 `USER_NS` 就没有 uid 隔离**：`g1g2g3` 之前的产物里容器 root 就是宿主 root，别跑不可信镜像。
- 每次 PixelOS OTA 更新 kernel 都要重编；`boot_b` 留着做对照。
- 本仓库不覆盖 `CONFIG_CGROUP_DEVICE` 之外的其它厂商私有裁剪（比如某些 QTI 特性），只看闸门结果。
- 源码来自 `android.googlesource.com/kernel/common` 的 `android15-6.6` 分支；pin 版本用 `kernel_commit` 输入。

## 目录

```
config/device-6.6.87.config     设备内核真 config（从 Image 解出）
config/features/G{1..4}-*.config  功能分组
scripts/make-symbollist.sh      生成 TRIM 白名单（abi 列表并集）
scripts/apply-variant.sh        config + fragment → .config
scripts/gate-crc.py             CRC 闸门（symvers vs 厂商 .ko __versions）
scripts/show-features.sh        Summary 用的关键项表格 + config diff
scripts/repack-boot.sh          本地：原厂 boot.img + 新 Image → 新 boot.img
.github/workflows/build.yml     矩阵构建 + 闸门 + artifact/release
```

## License

GPL-2.0-only（内核 config 派生物；脚本同许可）。
