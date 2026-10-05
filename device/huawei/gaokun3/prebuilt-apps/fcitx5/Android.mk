# 中文输入法预置：fcitx5-android（v1.0 DISP-3 / D10，2026-10-05）。⚠️ 默认【不启用】：等用户确认 APK 来源。
#
# 为什么选它（调研 2026-10-05，只看了项目页 / release / F-Droid 页，⬜ 没在本机上装过）：
#   * 许可证 LGPL-2.1（github.com/fcitx5-android/fcitx5-android；F-Droid 页写 "GNU Lesser General Public License v2.1 only"）
#     —— 能作为独立应用随 ROM 发；义务是给出对应版本的完整源码（下面"源码出处"），NOTICE 里要记一笔。
#   * 主 APK 自带拼音 / 双拼 / 五笔 / 仓颉 + 英文，不用另下词库；
#   * 0.1.0 起支持物理键盘：开始用实体键盘打字时隐藏软键盘、显示浮动候选窗（release 0.1.0 说明）。
#     ⬜ 实体键盘上怎么中英切换（Shift / Ctrl+Space，以及与 Android 自己的 Ctrl+Space 切输入法冲不冲突）文档没写，要上机验。
#   * 体积：0.1.3 的 arm64-v8a APK 45,935,104 字节（GitHub release 资产列表，2026-07-26）。
#     product 分区（10-04 构建 1.2 GB）在 12 GiB super 里，装得下。
#   对照：Trime（RIME，GPL-3.0，v3.3.12 arm64 8,986,312 字节）—— 小得多，但要自己配 schema，文档里也找不到实体键盘支持的说明。
#
# ⬜ 要用户定的：APK 从哪来。
#   (a) GitHub release（fcitx5-android 项目自己签名）；(b) F-Droid 构建（F-Droid 签名）。
#   两者签名不同：预装哪一份，用户以后就只能从同一来源更新（否则装不上更新、要先卸载）。
#   定了之后把 APK 放在本目录、文件名用 fcitx5-android-arm64-v8a.apk，并在 lineage_gaokun3.mk / 构建命令里设
#   GAOKUN3_WITH_FCITX5 := true（device.mk 只有这个开关为 true 才把模块加进 PRODUCT_PACKAGES）。
#
# 源码出处（LGPL 义务；发版时把这一行抄进 docs/relnotes/<版本>-sources.md 与 NOTICE）：
#   https://github.com/fcitx5-android/fcitx5-android/tree/<所用版本的 tag>（含子模块 fcitx5 / libime / fcitx5-chinese-addons 等）。
#
# ★ 为什么用 Android.mk + wildcard 而不是 Android.bp 的 android_app_import：
#   Soong 遇到不存在的 apk 源文件会在分析期直接让整个构建失败，而 APK 不入库（本目录 .gitignore）；
#   Android.mk 可以"文件在才定义模块"。device/huawei 不在 Soong 的 Android.mk 禁用名单里
#   （build/soong/ui/build/androidmk_denylist.go）。
# ★ 写法照 vendor/gapps 的 android_app_import（presigned / 不 dexpreopt / product 分区），换成 Android.mk 的对应变量。

LOCAL_PATH := $(call my-dir)

ifneq ($(wildcard $(LOCAL_PATH)/fcitx5-android-arm64-v8a.apk),)
include $(CLEAR_VARS)
LOCAL_MODULE := Fcitx5Android
LOCAL_MODULE_CLASS := APPS
LOCAL_MODULE_SUFFIX := $(COMMON_ANDROID_PACKAGE_SUFFIX)
LOCAL_SRC_FILES := fcitx5-android-arm64-v8a.apk
LOCAL_CERTIFICATE := PRESIGNED
LOCAL_PRODUCT_MODULE := true
LOCAL_DEX_PREOPT := false
LOCAL_LICENSE_KINDS := SPDX-license-identifier-LGPL-2.1
LOCAL_LICENSE_CONDITIONS := restricted
include $(BUILD_PREBUILT)
endif
