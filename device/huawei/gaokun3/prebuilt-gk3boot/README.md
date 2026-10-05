# 统一启动入口 gk3boot.efi 的预编译产物（随 vendor 下发）

`.gitignore` 把本目录**整个**忽略，只放行这份 README —— 与 `prebuilt-boot/` 同一个规矩：二进制不入库，
构建机上由 `scripts/sync-device-tree.sh` 同步过去并断言。

设计：`docs/boot-entry-design.md` §4.6.2、§4.11（S9）；入口本身：`tools/gk3boot/`（README §10–§11）。

## 需要放什么

```
gk3boot.efi    tools/gk3boot/build/efi/gk3boot.efi（aarch64 PE，约 100 KB）
version        一行：构建它时的 BOOT_VERSION（只准 [A-Za-z0-9._+-]，≤ 64 字符，不能是 log）
```

`device.mk` 用 wildcard：两样都在才装进 `/vendor/boot/gk3boot/{gk3boot.efi,version}`；不在照样能编，
ROM 里只是没有入口（开机完成线程报 `vendor.gaokun3.bootentry.error=no /vendor/boot/gk3boot in this build`，
不部署、也不撤已有的）。

`version` 是**承重的**：ESP 上的目录叫 `EFI/gk3boot/<version>/`，boot_control HAL 与 OTA postinstall 都按它判断
"ESP 上的入口是不是这一版"。所以：
- 它必须与二进制里嵌的版本串一致（入口把 `androidboot.bootloader=gk3boot-<串>` 交给内核）——
  `sync-device-tree.sh` 第 3c 步用 `grep -ao 'gk3boot-[A-Za-z0-9._+-]*'` 从二进制里抠出来比对；
- **换了二进制就必须换版本串**。同一个版本串配两份不同的二进制，HAL 会用新的那份覆盖 ESP 上的旧文件
  （它按字节比对、不同就重写），但 OTA postinstall 与"上一版入口（gk3prev）"的轮换都以为版本没变 ——
  回退那一档就丢了。

## 怎么产出

```sh
colima start
bash scripts/gk3boot/test-boot.sh              # 在 arm64 容器里编 gk3boot.efi 并跑 QEMU 全部场景；版本串 = 0.2.0-e5.g<提交>
colima stop
cp tools/gk3boot/build/efi/gk3boot.efi device/huawei/gaokun3/prebuilt-gk3boot/
echo 0.2.0-e5.g<提交> > device/huawei/gaokun3/prebuilt-gk3boot/version   # 与 test-boot.sh 打印的"gk3boot 版本串"一致
shasum -a 256 device/huawei/gaokun3/prebuilt-gk3boot/gk3boot.efi
```

⚠️ 版本串里带 `.dirty`（工作区有未提交的改动时编的）就不要放进来：那一版对不上任何提交。

## 装上之后什么时候生效

装进 vendor **不等于**部署到 ESP。部署由属性 `persist.vendor.gaokun3.gk3boot` 决定（缺省 `off`，1.0 发版时再定默认值）：

| 值 | 开机完成时（boot_control HAL，`boot_control/Gk3Boot.cpp`） | OTA 时（`bin/gaokun3-ota-postinstall.sh`） |
|---|---|---|
| `off` / 没设 | 删掉全部 `gk3boot-*` / `gk3prev-*` 条目与 `EFI/gk3boot/<ver>/`（`log/` 留着） | 删条目（目录留给新槽的 HAL 回收） |
| `observe` | 现役入口 = 本槽 vendor 那一版、`gk3.observe=1`（只算不写 misc） | ESP 上还没有入口 ⇒ 直接部署 `+3`；已有别的版本 ⇒ 只铺目录 + `.staged` |
| `action` | 同上、`gk3.observe=0`（扣 tries、自动回滚、写 GK3 记录） | 同上 |

条目格式（HAL 与 postinstall 写的一模一样）：

```
title      Android                          （observe 时 "Android (gk3boot observe)"；上一版 "Android (previous loader)"）
version    gk3boot-<ver>
sort-key   0gk3                             （上一版 0gk3prev；都排在直连条目 zandroid<x> 前面）
efi        /EFI/gk3boot/<ver>/gk3boot.efi
options    gk3.observe=<0|1> gk3.hint=<x>
```

`release.sh` 在本目录有 `gk3boot.efi` 时断言 `$OUT/vendor/boot/gk3boot/` 里那两份与这里逐字节相同。
