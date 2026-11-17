# 诊断决策树（6.6.87 对齐版）

目标：定位「自编内核卡在开机 logo」的确切原因，并在每种结论下给出可直接使用的产物。

## 已确定的事实

| # | 事实 | 证据 |
|---|---|---|
| 1 | 构建链本身没问题 | `6.6.144 baseline`（stock config + 三枚 ABI 补丁 + TRIM 白名单 + AVB 签名）能正常开机 |
| 2 | 符号不会缺 | 从原厂 Image 重建 vmlinux，抽出 8755 个导出符号；718 个厂商模块引用 5372 个，其中我们没导出的 1561 个 **原厂内核也没导出** → 全是模块间互导 |
| 3 | AVB 链路已解决 | vbmeta 里 `boot` 是 **链描述符**（不比对 boot 内容），boot 靠自身 footer 自证；本 ROM 的私钥就是 AOSP 公开 `testkey_rsa4096.pem`（公钥 sha1 逐位一致） |
| 4 | 版本基线可精确对齐 | ACK tag `android15-6.6-2025-05_r10` = Makefile **6.6.87**、`CLANG_VERSION=r510928`、`KMI_GENERATION=8`；`baseline` 的 Image 尺寸与原厂**完全相同**（36,456,960），`CONFIG_CC_VERSION_TEXT` 逐字相同 |
| 5 | 失败边界已收缩到 G1 | `6.6.144`：baseline ✅ / g1 ❌ / all ❌ |

## G1 的四个开关

```
CONFIG_PID_NS=y         容器必需
CONFIG_IPC_NS=y         容器必需
CONFIG_SYSVIPC=y        容器必需（IPC_NS 依赖它）
CONFIG_POSIX_MQUEUE=y   容器可选
```

其中只有 `SYSVIPC` 需要补丁 0001（把 `sysvsem`/`sysvshm` 从 `task_struct` 中部搬到尾部）。
其余三个不改变任何既有字段偏移。

## 决策树

```
① boot-6687-baseline（stock config，精确 6.6.87）
│
├─ ❌ 卡  → 构建环境问题，与任何 CONFIG 无关
│          嫌疑：PGO/BOLT/MLGO 优化、ld.lld 版本、GKI build.config 的额外参数
│          下一步：改用 kleaf / GKI 官方 build.sh 构建，而不是手写 make
│
└─ ✅ 开
   │
   ② boot-6687-g1（PID_NS + IPC_NS + SYSVIPC + POSIX_MQUEUE）
   │
   ├─ ✅ 开  → 【结论 A】元凶是 6.6.87 → 6.6.144 的版本漂移
   │            → 最终产物直接钉在 6.6.87，用 safe / g1dev
   │
   └─ ❌ 卡
      │
      ③ 三分法（都是精确 6.6.87）
      │
      ├─ boot-6687-sysvonly（SYSVIPC + IPC_NS）
      │  ├─ ❌ 卡 → ④ 再切
      │  │        ├─ boot-6687-sysv-noipcns（只 SYSVIPC）
      │  │        │  ├─ ❌ 卡 → 【结论 B】SYSVIPC 子系统本身
      │  │        │  │        内核内方案不可行 → 改 LKM 路线，或深挖补丁 0001
      │  │        │  └─ ✅ 开 → 【结论 C】IPC_NS
      │  │        │           → 只开 SYSVIPC（容器可跑，droidspaces 需 IPC_NS 时会降级）
      │  │        └─ ✅ 开 → 见 ⑤
      │  └─ ✅ 开 → 见 ⑤
      │
      ⑤ boot-6687-pidonly / boot-6687-mqonly
         ├─ pidonly ❌ → 【结论 D】PID_NS（最难，需比对 6.6.87 vs 6.6.144 的 kernel/pid*.c）
         ├─ mqonly  ❌ → 【结论 E】POSIX_MQUEUE（放弃该项，容器不强制需要）
         └─ 都 ✅ 但 g1 ❌ → 【结论 F】组合效应，两两组合再切 3 轮
```

## 每种结论对应的最终产物

| 结论 | 可用的最终配置 | 产物名 | 能力 |
|---|---|---|---|
| A 版本漂移 | G1 + DEVTMPFS + macvlan + userns | `boot-6687-safe` | 容器全套（无 cgroup 限额） |
| A 版本漂移 | G1 + DEVTMPFS | `boot-6687-g1dev` | 容器最小可用 |
| C 仅 IPC_NS 有问题 | SYSVIPC only | 需新编 | 容器可跑，缺 IPC 隔离 |
| D PID_NS 有问题 | — | 无 | 只能走 LKM 补 PID_NS |
| E MQUEUE 有问题 | G1 去掉 MQUEUE | `boot-6687-g1` 去掉 mqueue | 容器可跑 |
| F 组合效应 | 逐项加 | 按实测组合 | 按实测 |

## cgroup（G2）单独一条线

```
boot-6687-g1 开 之后
  └─ boot-6687-g1g2（g1 + DEVTMPFS + CGROUP_PIDS + CGROUP_DEVICE）
     ├─ ❌ 卡 → 【结论 G】cgroup 数组位移（GENKSYMS 看不见的那类改动）
     │          → 放弃 --pids-limit / 设备白名单，用 safe
     └─ ✅ 开 → 再试 boot-6687-all（+ nftables + userns）
```

`CGROUP_PIDS` / `CGROUP_DEVICE` 各给 `CGROUP_SUBSYS_COUNT` +1，使
`struct css_set` / `struct cgroup` 里的 `subsys[CGROUP_SUBSYS_COUNT]` 数组加长 16 字节，
**其后所有字段整体位移**。genksyms 只对声明文本求哈希，所以补丁 0002 能让 CRC 归零，
但真实偏移确实变了 —— 这是 CRC 闸门原理上抓不到的一类问题。


## 全部 11 个已签产物（release v2）

`boot-6687-*.zip` → 解压得 `boot_a.img`，全部 96 MB 满分区、testkey 签名。

| 包 | PID | IPC | SYSV | MQ | DEVTMPFS | CGROUPS | MACVLAN | NFT | USER_NS |
|---|---|---|---|---|---|---|---|---|---|
| `baseline` | – | – | – | – | – | – | – | – | – |
| `pidonly` | ✅ | – | – | – | – | – | – | – | – |
| `mqonly` | – | – | – | ✅ | – | – | – | – | – |
| `sysv-noipcns` | – | – | ✅ | – | – | – | – | – | – |
| `sysvonly` | – | ✅ | ✅ | – | – | – | – | – | – |
| `g1` | ✅ | ✅ | ✅ | ✅ | – | – | – | – | – |
| `g1-noipcns` | ✅ | – | ✅ | ✅ | – | – | – | – | – |
| `g1dev` | ✅ | ✅ | ✅ | ✅ | ✅ | – | – | – | – |
| `safe` | ✅ | ✅ | ✅ | ✅ | ✅ | – | ✅ | – | ✅ |
| `g1g2` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | – | – | – |
| `all` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

`safe` / `all` 另含 `IP6_NF_NAT` + `NETFILTER_XT_MATCH_ADDRTYPE`。

### Kconfig 陷阱

`init/Kconfig`：`config IPC_NS` 是 **`default y`** + **`depends on (SYSVIPC || POSIX_MQUEUE)`**。
开 `SYSVIPC` 或 `POSIX_MQUEUE` 会**自动**打开 `IPC_NS`。
要真正隔离必须在 fragment 里显式写 `# CONFIG_IPC_NS is not set`（`mqonly` / `sysv-noipcns` / `g1-noipcns` 就是这么做的）。

同理 `config PID_NS` 也是 `default y`，stock 之所以是 n，是 `gki_defconfig` 里显式关掉的。


## 实测：6.6.87 基线不可用（重要）

> ✅ **定案（同日，单变量实验）：元凶是 `CONFIG_TRIM_UNUSED_KSYMS=y`，与内核版本、与 CONFIG 开关都无关。**
>
> | 镜像 | TRIM | ABI 补丁 | 结果 |
> |---|---|---|---|
> | v1.2 `boot-baseline`（6.6.144） | off | 无 | ✅ 开机 |
> | v4-iso `boot-B-trim-off-patch`（6.6.144） | **off** | 有 | ✅ 开机 |
> | v4-iso `boot-A-trim-on-nopatch`（6.6.144） | **on** | 无 | ❌ 卡 |
> | 6.6.87 baseline / g1 / pidonly / mqonly / g1dev（全部 trim=on） | on | 有 | ❌ 卡 |
>
> 因此 6.6.87 那条"版本不兼容"的结论作废；所有构建**一律 trim=off**（workflow 默认已改）。

| 内核 | 结果 | 定位 |
|---|---|---|
| `6.6.144-4k-<hash>`（分支头 baseline） | ✅ `sys.boot_completed=1`，模块 **502**，`media.audio_flinger`/`audio_policy` 齐全 | 可用 |
| `6.6.87-4k-<hash>-dirty`（ACK tag `android15-6.6-2025-05_r10` baseline） | ❌ 卡开机动画，模块 **403**，无 `media.audio_flinger` | **弃用** |

卡的精确位置（system_server ANR，`main` 线程）：

```
libaudioclient.so  ServiceHandler::get<IAudioFlingerService>
android_media_AudioSystem_setMasterBalance
AudioService.updateMasterBalance(AudioService.java:3033)
AudioService.readPersistedSettings(AudioService.java:3446)
AudioService.<init>(AudioService.java:1681)
SystemServer.startOtherServices(SystemServer.java:2489)
```

因果链：`audioserver` 拿不到 `android.hardware.audio.core.IConfig/default`（`init: Could not find ... for ctl.interface_start`，
每秒钟重试）→ 无法创建 AudioFlinger → 不注册 `media.audio_flinger` →
`system_server` 在构造 `AudioService` 时无限等待 → `boot_progress_ams_ready` 之后全部不出现。

**结论：版本号对齐（6.6.87 == 设备）不等于可用。** 必须用分支头（6.6.144）。


## TRIM_UNUSED_KSYMS 是卡开机的真凶（已定案）

### 现象
所有 `trim=on` 的镜像都在同一处卡住：`sys.boot_completed` 空、`/proc/modules` ≈403、
无 `media.audio_flinger`、`system_server` 主线程卡在 `AudioService.<init>` 等 `IAudioFlingerService`。

### 为什么 CRC 闸门看不出来
TRIM 只改变"导出了哪些符号"，**不改变任何 CRC**。718 个厂商模块的 `__versions` 全对 ⇒ `MISMATCH: 0`,
但内核实际少导出了 7712 个符号（trim=on 9539 vs trim=off 17251），其中 67 个是**原厂内核本来导出**的。
厂商模块在 probe 期若按名字解析符号失败，子系统就起不来——这条链路闸门原来完全看不见。

### 新闸门（已加进 `scripts/gate-crc.py`）
`--stock-exports config/stock-exports-6.6.87.txt`：要求**新内核导出集合 ⊇ 原厂导出集合**（8755 个，
由 `vmlinux-to-elf` 从 boot Image 重建后解析 `__ksymtab` 得到）。

| 构建 | 原厂导出覆盖 | 退出码 |
|---|---|---|
| trim=off（当前全部产物） | **8755/8755** ✅ | 0 |
| trim=on（旧产物） | 8688/8755 ❌ 少 67 | 1 |

报告里另加一行 `TRIM_UNUSED_KSYMS: on ⚠️ …已实测导致卡开机`。

### 判据速查
```sh
adb shell getprop sys.boot_completed                                   # 1 = 好
adb shell "grep -c '' /proc/modules"                                   # 健康 ≈502；≈403 且卡 = 同一症状
adb shell "service list | grep -E 'media.audio_(flinger|policy)'"      # 健康时两个都在
```

## 快速判据（每次卡住先跑这两条）

```sh
adb shell getprop sys.boot_completed              # 1 = 通过
adb shell "grep -c '' /proc/modules"              # 健康 ≈ 502；若 ~403 且卡住 = 音频 HAL 没起来
adb shell "service list | grep -E 'media.audio_(flinger|policy)'"   # 健康时两个都在
```

- 模块数 ~403、`media.audio_flinger` 缺失 → **音频阻塞**，与本次内核开关无关；
- 模块数正常、`media.audio_flinger` 在、但 `boot_completed` 空 → 才是真正由该 CONFIG 引起的新问题。

## 已验证的好状态参照（6.6.144 baseline，2026-11-17）

```
uname -r                6.6.144-4k-<hash>       # 注意：无 -dirty
sys.boot_completed      1
ro.boot.veritymode      enforcing
ro.boot.verifiedbootstate green
/proc/modules 行数       502
dmesg 模块错误           无
/media.audio_flinger    在
/vendor/bin/hw          audiohalservice.qti + AIDL audio 服务
```


## 随机重启（停止 droidspaces 容器时触发）

### 第一嫌疑：还装着 LKM 版补丁

内核现在已经**原生支持** PID_NS / IPC_NS / SYSVIPC，如果设备上还留着
`_patchHarmony` 系的 `droid_lkm*.ko`（它会 hook `sys_call_table` 的
`__NR_clone/clone3/unshare` 以及 `copy_namespaces` / `switch_task_namespaces` /
`exit_task_namespaces` / `free_nsproxy`），就会与内核原生实现**双重接管**，
容器停止时走 `put_nsproxy` 释放路径 → 崩溃。

排查：
```sh
lsmod | grep -i droid
ls /data/adb/modules
```
有就删掉模块目录并重启。

### 第二嫌疑：cgroup 子系统数组变长（patch 0002 的已知代价）

`CGROUP_SUBSYS_COUNT` 从 N 变 N+2，`struct css_set` / `struct cgroup` 里的
`subsys[]` **真的长了 16 字节**，其后字段整体位移。CRC 闸门看不见（只比签名）。
受影响的厂商模块：`msm_drm`(284 符号) / `msm_kgsl`(132) / `sched-walt`(25)。

二分验证（都是 v5 的包）：
| 包 | 含 cgroup | 含 USER_NS | 含 NF_TABLES |
|---|---|---|---|
| `boot-g1dev` | – | – | – |
| `boot-safe` | – | ✅ | – |
| `boot-g1g2` | ✅ | – | – |
| `boot-all` | ✅ | ✅ | ✅ |

停止容器只崩 `boot-g1g2` / `boot-all` → cgroup 是元凶 → 放弃 `--pids-limit`，用 `boot-safe`。

### 抓 panic 现场

这台机 `pstore` 是空的（DTB 有 `ramoops-region` 但无驱动绑定），所以崩溃栈必须
**在 PC 侧一边流一边存**：`scripts/_panic_watch.ps1`（`adb shell cat /proc/kmsg`
的输出写到 PC 上的文件，设备重启也不丢）。

## 已验证不可行

| 项 | 结论 |
|---|---|
| `CONFIG_CFS_BANDWIDTH` | **不做**。`struct cfs_rq` 按值内嵌在 `struct rq` 里，加成员会位移 `rt_rq`/`dl_rq`/`clock`，受影响的正是 `sched-walt.ko`（25 个符号）与 `lenovohyperSched.ko`（9 个）。修 CRC 会变绿但读写错位，属静默错误（见 `config/features/X1-cfsbw.config`） |
| `pstore` 抓崩溃日志 | 不可用。DTB 有 `ramoops-region` 保留内存，但没有驱动绑定（QCOM 走 minidump 那套），`/sys/fs/pstore/` 恒空 |
| `pip install mkbootimg` | 不存在（PyPI 404）。用 AOSP `system/tools/mkbootimg` 的 `mkbootimg.py` / `unpack_bootimg.py`（纯 stdlib） |

## 工具链备忘

- 打 boot：`scripts/sign-boot-avb.sh <Image> <out.img> --stock-boot stock-boot_a.img`
  - header v4 / os_version 16.0.0 / patch 2026-10 / pagesize 4096 全部从原厂 boot 读出
  - `add_hash_footer`：SHA256_RSA4096 + testkey + rollback 1777939200（均取自原厂）
  - 产出 96 MB 满分区镜像，可直接 `fastboot flash boot_a`
- 验证工具链正确性：用原厂 kernel 走同一套参数重打包，内容区应与原厂**逐字节相同**（已验证）
- AnyKernel3 的 zip 必须换 arm64 版 busybox/magiskboot，否则 64 位-only 设备报 `Busybox setup failed`
