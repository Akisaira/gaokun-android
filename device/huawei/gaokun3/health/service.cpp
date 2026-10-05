/*
 * vendor.lineage.health-service.gaokun3 —— 只注册 IChargingControl/default（v1.0 PWR-14）。
 * 写法照 hardware/lineage/interfaces/health/aidl/default/service.cpp（crDroid 16.0 构建树），
 * 去掉了 IFastCharge：本机没有快充档位节点，不声明就不会被框架当成"支持"（FastChargeController
 * 用 waitForDeclaredService，没声明直接拿到 null）。
 */
#define LOG_TAG "gaokun3-health"

#include "ChargingControl.h"

#include <android-base/logging.h>
#include <android/binder_manager.h>
#include <android/binder_process.h>

#include <cstdlib>
#include <string>

using ::aidl::vendor::lineage::health::ChargingControl;

int main() {
    ABinderProcess_setThreadPoolMaxThreadCount(0);
    std::shared_ptr<ChargingControl> cc = ndk::SharedRefBase::make<ChargingControl>();

    const std::string instance = std::string() + ChargingControl::descriptor + "/default";
    binder_status_t status = AServiceManager_addService(cc->asBinder().get(), instance.c_str());
    CHECK_EQ(status, STATUS_OK) << "注册 " << instance << " 失败";

    ABinderProcess_joinThreadPool();
    return EXIT_FAILURE;  // should not reach
}
