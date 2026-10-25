LOCAL_PATH := $(call my-dir)

# ─── 把 recovery 的 ramdisk 装进 vendor，好让 recovery 能走 OTA ───
#
# 本机没有 recovery 分区，也不该有：安装器把剩余空间全给了 userdata，
# 已装的机器没有余地再切分区。所以 recovery 走和内核同一条路 ——
# 作为文件随 vendor（在 AB_OTA_PARTITIONS 里）走 payload，
# 由 postinstall 钩子铺到 ESP 上该槽的目录 + 写一个 BLS 条目。
# ★ 这样【已装的机器一次普通 OTA 就能拿到 recovery】，不必重装。
#
# ★ 只取 ramdisk，不装整个 recovery.img：实测 recovery.img 里的内核与 boot.img
#   里的【sha256 完全相同】（8e55f776…），dtb 也一样，所以 ESP 上不必再存一份，
#   recovery 的 BLS 条目直接复用该槽的 Image 与 gaokun3.dtb。
#   recovery.img 28 MB vs 单独的 ramdisk 14 MB —— 每个 OTA payload 省一半。
#
# ⚠️ 用【字面路径】$(PRODUCT_OUT)/recovery.img 作依赖，不用
#   INSTALLED_RECOVERYIMAGE_TARGET：那个变量在 core/Makefile 里才定义，
#   而本文件被更早地包含进来，引用它会拿到空值。Make 解析【依赖】不看定义顺序，
#   所以写字面路径是对的。
# ✅ A17（crDroid 17.0）核对：本文件仍被 build/make/target/board/android-info.mk:7 include；
#   recovery.img 的产物路径仍是 $(PRODUCT_OUT)/recovery.img（refs/a17/build/make/core/Makefile:286）；
#   device/huawei 不在 Soong 的 Android.mk 禁用名单里（build/soong/ui/build/androidmk_denylist.go:23-60），
#   本产品也没设 PRODUCT_IGNORE_ALL_ANDROIDMK（设了 core/main.mk:254-260 才过滤 Android.mk）或 PRODUCT_SOONG_ONLY（product.mk:516-518，设了整个 Kati 不跑）。
#   RELEASE_SRC_DIR_IS_READ_ONLY（cp1a 起 true）只限制写源码树，这里只写 $(TARGET_OUT_VENDOR)，不受影响。
GAOKUN3_REC_RAMDISK := $(TARGET_OUT_VENDOR)/boot/recovery-ramdisk.img
GAOKUN3_REC_EXTRACT := $(HOST_OUT_EXECUTABLES)/gaokun3-bootimg-extract

$(GAOKUN3_REC_RAMDISK): $(PRODUCT_OUT)/recovery.img $(GAOKUN3_REC_EXTRACT)
	@echo "gaokun3: 从 recovery.img 取出 ramdisk -> vendor/boot/recovery-ramdisk.img"
	@rm -rf $(dir $@)rec-tmp
	@mkdir -p $(dir $@)rec-tmp
	$(GAOKUN3_REC_EXTRACT) $< $(dir $@)rec-tmp
	$(hide) cp $(dir $@)rec-tmp/ramdisk.img $@
	@rm -rf $(dir $@)rec-tmp

ALL_DEFAULT_INSTALLED_MODULES += $(GAOKUN3_REC_RAMDISK)
