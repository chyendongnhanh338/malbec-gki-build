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
