# config 的来源

`device-6.6.87.config` **不是** `gki_defconfig`，而是设备内核 Image 里内嵌的那份真 config。

## 怎么来的

```bash
# 1. 取原厂 Image（这个仓库就是设备树引用的 prebuilt kernel 仓）
curl -L -o kernel.img \
  https://raw.githubusercontent.com/suddenBook/android_device_lenovo_malbec-kernel/HEAD/images/kernel

# 2. 抠出 IKCFG_ST..IKCFG_ED 之间的 gzip 段
python3 ../scripts/extract-config-from-image.py kernel.img device-6.6.87.config
```

也可以在设备上直接拿（`CONFIG_IKCONFIG_PROC=y`）：

```sh
su -c 'zcat /proc/config.gz' > device.config
```

两者内容一致。

## 为什么要用它对

符号 CRC 由 `genksyms` 按「头文件声明文本 + **配置**」算出。换成 `gki_defconfig`
或者别的机型的 config，CRC 会大面积不同，产出的 `.ko` / 内核就和原厂 vendor 模块对不上。
`baseline` 变体的全部意义就是验证「用这份 config + r510928 clang 能复现原厂 ABI」。

## OTA 之后

PixelOS 更新内核 → 重新跑一遍上面的提取，覆盖这个文件，再跑 `baseline`。
如果 `baseline` 出现 MISMATCH，说明新内核的 config 或源码基线变了，需要重新审。
