# fcitx5-android（预置的中文输入法）

v1.0 DISP-3 / D10。用户 2026-10-06 定：**APK 从 GitHub release 取**（fcitx5-android 项目自己的签名；
以后用户也只能从 GitHub 更新它 —— F-Droid 版签名不同，装不上覆盖）。

| | |
|---|---|
| 版本 | 0.1.3（tag `0.1.3`，提交 `048f581c`，2026-07-26） |
| 文件 | `org.fcitx.fcitx5.android-0.1.3-0-g048f581c-arm64-v8a-release.apk` → 本目录 `fcitx5-android-arm64-v8a.apk`（不入库，`.gitignore`） |
| 大小 | 45,935,104 字节 |
| sha256 | `8e5de1036aea1f55895b39b4fc25a2d563e7b0663fa2708c86598f81768b106d`（GitHub 资产 digest 与本地下载一致；入库的 `fcitx5-android-arm64-v8a.apk.sha256`） |
| 许可证 | LGPL-2.1（作为独立应用随 ROM 分发；源码见下） |
| 源码 | <https://github.com/fcitx5-android/fcitx5-android/tree/0.1.3>（含子模块 fcitx5 / libime / fcitx5-chinese-addons 等） |

取回：

```sh
cd device/huawei/gaokun3/prebuilt-apps/fcitx5
curl -L -o fcitx5-android-arm64-v8a.apk \
  https://github.com/fcitx5-android/fcitx5-android/releases/download/0.1.3/org.fcitx.fcitx5.android-0.1.3-0-g048f581c-arm64-v8a-release.apk
shasum -a 256 -c fcitx5-android-arm64-v8a.apk.sha256
```

构建：APK 在就自动进 product 分区（`device.mk`，wildcard）；`GAOKUN3_WITH_FCITX5=false` 可显式不带。
构建机上由 `scripts/sync-device-tree.sh` 同步并断言 sha256。换版本：改上表、换 `.sha256`、改 NOTICE 里的源码链接。

⬜ 未上机：实体键盘的中英切换（Shift / Ctrl+Space，与 Android 自己的 Ctrl+Space 冲不冲突）、默认是否需要用户在
「设置 → 系统 → 键盘」里手动启用（只预装，不改默认输入法）。
