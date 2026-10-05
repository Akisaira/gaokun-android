/*
 * Copyright (C) 2022 The Android Open Source Project
 * Copyright 2026 The gaokun-android contributors
 * SPDX-License-Identifier: Apache-2.0
 *
 * Based on hardware/interfaces/boot/aidl/default/main.cpp. The AIDL *instance*
 * name must stay "default" even though the service binary is named .gaokun3 —
 * that is the name the framework looks up.
 */

#include "BootControl.h"
#include "Gk3Boot.h"

#include <unistd.h>

#include <android-base/logging.h>
#include <android/binder_manager.h>
#include <android/binder_process.h>

using aidl::android::hardware::boot::BootControl;
using aidl::android::hardware::boot::IBootControl;

// ★ 历史记录：这里曾有一个 EnsureSlotProbeHints()，把
//   /dev/block/by-name/boot_a 与 boot_b symlink 到 /dev/null。
//
//   起因是 InitDefaultBootloaderControl() 靠 stat() 探测
//   <dirname(misc)>/boot_a..boot_d 来数槽位数，而本机当年【根本没有 boot
//   分区】（内核/DTB/ramdisk 是 ESP 上的文件），探不到就按设计回退成
//   kMaxNumSlots = 4。后果很阴：update_engine 取 (current+1) % num_slots，
//   第一次 OTA 还能 _a -> _b，第二次就会切到根本不存在的 _c ——
//   故障要晚一个版本才爆。
//
//   2026-08-20 起本机按 Android 分区规范有了真的 boot_a / boot_b（各 64 MiB，
//   boot 也进了 AB_OTA_PARTITIONS），探测自然数出 2，这个补丁就不需要了。
//   ⚠️★ 而且必须【删掉】而不是留着：那两条路径现在指向真实分区，
//   一旦这段代码抢在 ueventd 建立 by-name 链接之前跑成功，
//   update_engine 就会把 boot 镜像写进 /dev/null —— 静默地毁掉整个更新。
//   （旧代码有 errno != EEXIST 的判断，所以实际没出事，但这个雷不该留。）
//
//   下面 main() 里那句"槽位数必须是 2"的断言保留着，它现在校验的是
//   真实分区被正确探测到。

int main(int, char* argv[]) {
    android::base::InitLogging(argv, android::base::KernelLogger);

    ABinderProcess_setThreadPoolMaxThreadCount(0);
    std::shared_ptr<IBootControl> service = ndk::SharedRefBase::make<BootControl>();

    int32_t slots = 0;
    if (service->getNumberSlots(&slots).isOk() && slots != 2) {
        LOG(ERROR) << "boot control reports " << slots << " slots, expected 2. "
                   << "libboot_control counts slots by stat()ing boot_a..boot_d next to misc, "
                   << "so this means boot_a/boot_b are missing or the bootloader_control block in "
                   << "misc is stale; zero the first 4 KiB of /dev/block/by-name/misc and reboot "
                   << "to let it re-initialise.";
    }

    const std::string instance = std::string(BootControl::descriptor) + "/default";
    auto status = AServiceManager_addService(service->asBinder().get(), instance.c_str());
    CHECK_EQ(status, STATUS_OK) << "Failed to add service " << instance << " " << status;
    LOG(INFO) << "IBootControl AIDL service running with " << slots << " slots";

    // ★ 统一启动入口（2026-10-05，S9）：开机完成线程 —— bless 入口条目、清 GK3 的 boot_streak、
    //   导出事件给 Parts、按 persist.vendor.gaokun3.gk3boot 部署 / 撤掉入口（Gk3Boot.cpp）。
    //   放在 addService 之后：它只等属性、不碰 impl_，不能拖慢 update_verifier 等 HAL 的那几秒。
    gaokun3::StartBootCompletedWorker();

    ABinderProcess_joinThreadPool();
    return EXIT_FAILURE;  // should not reach
}
