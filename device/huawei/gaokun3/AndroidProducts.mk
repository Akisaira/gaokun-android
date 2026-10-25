PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/lineage_gaokun3.mk

# release config = cp2a，来自 vendor/lineage/vars/aosp_target_release
# （crdroidandroid/android_vendor_crdroid@17.0，2026-10-25 核实；A16 / crDroid 16.0 时是 bp4a）。
# brunch gaokun3 == lunch lineage_gaokun3-cp2a-userdebug
COMMON_LUNCH_CHOICES := \
    lineage_gaokun3-cp2a-userdebug \
    lineage_gaokun3-cp2a-eng
