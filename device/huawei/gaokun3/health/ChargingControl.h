/*
 * vendor.lineage.health IChargingControl for gaokun3（v1.0 PWR-14）。说明见 ChargingControl.cpp 顶部。
 * 接口签名照 hardware/lineage/interfaces/health/aidl/default/ChargingControl.h（crDroid 16.0 构建树）。
 */
#pragma once

#include <aidl/vendor/lineage/health/BnChargingControl.h>
#include <aidl/vendor/lineage/health/ChargingLimitInfo.h>
#include <android/binder_auto_utils.h>
#include <android/binder_status.h>

#include <mutex>

namespace aidl::vendor::lineage::health {

struct ChargingControl : public BnChargingControl {
    ndk::ScopedAStatus getChargingEnabled(bool* _aidl_return) override;
    ndk::ScopedAStatus setChargingEnabled(bool enabled) override;
    ndk::ScopedAStatus setChargingDeadline(int64_t deadline) override;
    ndk::ScopedAStatus getSupportedMode(int* _aidl_return) override;
    ndk::ScopedAStatus getChargingDeadline(int64_t* _aidl_return) override;
    ndk::ScopedAStatus getChargingLimit(ChargingLimitInfo* _aidl_return) override;
    ndk::ScopedAStatus setChargingLimit(const ChargingLimitInfo& limit) override;

    binder_status_t dump(int fd, const char** args, uint32_t numArgs) override;

  private:
    // 一次 set 是好几次 EC 事务，别让 dump / get 插在中间读到半截状态。
    std::mutex mLock;
};

}  // namespace aidl::vendor::lineage::health
