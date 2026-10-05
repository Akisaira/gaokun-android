/*
 * vendor.lineage.health IChargingControl for the Huawei MateBook E Go (gaokun3) —— v1.0 PWR-14 / LIVE-9。
 *
 * 用户入口是 LineageOS 现成的「设置 → 电池 → 充电控制」（LineageParts 的 ChargingControlSettings；
 * Settings 的 res/xml/power_usage_summary.xml:80-82 那一项 requiresService="lineagehealth"）。
 * 框架侧（lineage-sdk …/health/ChargingControlController.java:84-86）只认 IChargingControl/default，
 * 本 HAL 只声明 LIMIT 一种模式，于是框架用 ccprovider/Limit.java：
 *   · 关掉 / 拔掉电源 → setChargingLimit({min 0, max 100})（Limit.onReset，:56-58）；
 *   · 打开 → setChargingLimit({min = 目标 - 余量, max = 目标})，余量是 lineage-sdk 的
 *     config_chargingControlBatteryRechargeMargin（默认 10，lineage-sdk/lineage/res/res/values/config.xml:341；
 *     没声明 BYPASS 才用它，Limit.java:29-35），目标默认 80（同文件 :322）⇒ 默认 70–80%。
 *   · 每次电量变化都调 getChargingLimit()，max 不同才再 set（Limit.java:60-71）⇒ 重复写 EC 的只有真变化。
 *
 * ★ 为什么不用 hardware/lineage/interfaces/health/aidl/default 的通用实现（soong_config 配路径就能用）：
 *   EC 的"充电上限"不是两个阈值节点就完了。内核 huawei-gaokun-battery 驱动（构建机 ~/gk3-kernel-72y，
 *   drivers/power/supply/huawei-gaokun-battery.c；上游同名文件）给的是四个节点：
 *     charge_control_start_threshold / charge_control_end_threshold（标准 power_supply 属性，:406-407 读、:465-479 写）、
 *     battery_adaptive_charge（:529-565，EC 的 SMART_CHARGE_ENABLE，DSDT 里叫 SBAC/GBAC）、
 *     smart_charge_delay（:585-627，0 = NO_DELAY_MODE，非 0 = 插电多少小时后才开始限）。
 *   linux-gaokun 的说明（right-0903/linux-gaokun README.MD:132-153）给的用法是四个一起设、并且
 *   battery_adaptive_charge=1；还写明"关机且拔掉电源后这些值不保留"。⇒ 通用实现只写两个阈值，
 *   限不限得住取决于 EC 里那个使能位碰巧是多少 —— 不可接受。这里：
 *     · 设限：smart_charge_delay=0 → end → start → battery_adaptive_charge=1，最后读回核对；
 *     · 解除（max >= 100）：只写 battery_adaptive_charge=0（阈值留着无害，下次设限会重写）；
 *     · 读：使能位是 0 就报 {0, 100}（= 不限），否则报两个阈值。
 *   EC 侧的约束（drivers/platform/arm64/huawei-gaokun-ec.c:307-310 validate_battery_threshold_range）：
 *   end != 0 && start <= end && end <= 100；驱动注释（battery.c:461-464）说 start == end 会"奇怪地失败"
 *   ⇒ 这里保证 start < end。先写 end 再写 start：驱动在 end < 当前 start 时会把 start 拉到 end-1（:471-475），
 *   两步之后一定落在请求值上；反过来先写 start 可能被 :465-469 把 end 顶高。
 *
 * ★ 本进程【启动时不碰 EC】：不 access()、不读不写。chown 在 rc 的 on boot 里做，而 class hal 也在
 *   on boot 起（init.rc 的 class_start hal 先于 vendor rc 的同名动作）⇒ 启动时节点可能还是 root 的，
 *   所以每次调用现开现关，不缓存 fd、不在构造时探测。
 *
 * ⚠️ 写 EC 是有后果的动作（D17：实验要写 EC，需用户同意）：本 HAL 只在框架调用时写，且同值不写。
 *   但装上之后，即使用户从没打开充电控制，框架开机 / 拔电时也会调一次 setChargingLimit({0,100}) ——
 *   EC 里使能位已是 0 时那是空操作；若 EC 里本来就是 1（例如有人手动设过），这里会写 0（= 恢复不限）。
 * ⬜ 未编译（只在构建机上用 NDK clang 对树里的头文件 + aidl 生成的 NDK 头做过 -fsyntax-only -Wall -Werror）、未上机。
 * 上机判据见 docs/TODO.md「批 2 ROM 侧」的 PWR-14 一条。
 */
#define LOG_TAG "gaokun3-health"

#include "ChargingControl.h"

#include <android-base/file.h>
#include <android-base/logging.h>
#include <android-base/parseint.h>
#include <android-base/strings.h>

#include <aidl/vendor/lineage/health/ChargingControlSupportedMode.h>

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <string>

namespace aidl::vendor::lineage::health {

namespace {

constexpr char kBatDir[] = "/sys/class/power_supply/gaokun-ec-battery/";

std::string Node(const char* name) {
    return std::string(kBatDir) + name;
}

const std::string kStart = Node("charge_control_start_threshold");
const std::string kEnd = Node("charge_control_end_threshold");
const std::string kEnable = Node("battery_adaptive_charge");
const std::string kDelay = Node("smart_charge_delay");

bool ReadInt(const std::string& path, int* out) {
    std::string s;
    if (!::android::base::ReadFileToString(path, &s, /*follow_symlinks=*/true)) {
        PLOG(ERROR) << "读 " << path << " 失败";
        return false;
    }
    s = ::android::base::Trim(s);
    if (!::android::base::ParseInt(s, out)) {
        LOG(ERROR) << path << " 的内容不是整数: '" << s << "'";
        return false;
    }
    return true;
}

bool WriteInt(const std::string& path, int v) {
    if (!::android::base::WriteStringToFile(std::to_string(v), path, /*follow_symlinks=*/true)) {
        // errno 可能被 WriteStringToFile 内部的 close 覆盖，只作参考。
        PLOG(ERROR) << "写 " << path << " = " << v << " 失败";
        return false;
    }
    return true;
}

ndk::ScopedAStatus Unsupported() {
    return ndk::ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
}

ndk::ScopedAStatus IllegalState() {
    return ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);
}

}  // namespace

ndk::ScopedAStatus ChargingControl::getChargingEnabled(bool* /* _aidl_return */) {
    return Unsupported();
}

ndk::ScopedAStatus ChargingControl::setChargingEnabled(bool /* enabled */) {
    return Unsupported();
}

ndk::ScopedAStatus ChargingControl::setChargingDeadline(int64_t /* deadline */) {
    return Unsupported();
}

ndk::ScopedAStatus ChargingControl::getChargingDeadline(int64_t* /* _aidl_return */) {
    return Unsupported();
}

ndk::ScopedAStatus ChargingControl::getSupportedMode(int* _aidl_return) {
    // 只有 LIMIT：EC 没有"立刻停充"的开关（TOGGLE），也没有证据表明停充时走旁路供电（BYPASS）——
    // 不报 BYPASS，框架就按 config_chargingControlBatteryRechargeMargin 留回充余量（Limit.java:29-35）。
    *_aidl_return = static_cast<int>(ChargingControlSupportedMode::LIMIT);
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ChargingControl::getChargingLimit(ChargingLimitInfo* _aidl_return) {
    std::lock_guard<std::mutex> lock(mLock);
    int enabled = 0;
    if (!ReadInt(kEnable, &enabled)) return IllegalState();
    if (enabled == 0) {
        _aidl_return->min = 0;
        _aidl_return->max = 100;
        return ndk::ScopedAStatus::ok();
    }
    int start = 0, end = 0;
    if (!ReadInt(kStart, &start) || !ReadInt(kEnd, &end)) return IllegalState();
    _aidl_return->min = start;
    _aidl_return->max = end;
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus ChargingControl::setChargingLimit(const ChargingLimitInfo& limit) {
    std::lock_guard<std::mutex> lock(mLock);
    int enabled = 0;
    if (!ReadInt(kEnable, &enabled)) return IllegalState();

    // 解除限制：框架的 reset 发的是 {0, 100}（Limit.java:64-66）。
    if (limit.max >= 100) {
        if (enabled != 0) {
            LOG(INFO) << "解除充电上限（battery_adaptive_charge 1 → 0）";
            if (!WriteInt(kEnable, 0)) return IllegalState();
        }
        return ndk::ScopedAStatus::ok();
    }

    // EC 要求 end ∈ [1, 100]、start <= end，且 start == end 不可靠 ⇒ end ∈ [1, 99]、start ∈ [0, end-1]。
    const int end = std::clamp(limit.max, 1, 99);
    const int start = std::clamp(limit.min, 0, end - 1);
    if (end != limit.max || start != limit.min) {
        LOG(WARNING) << "请求 {" << limit.min << ", " << limit.max << "} 超出 EC 能接受的范围，改为 {"
                     << start << ", " << end << "}";
    }

    int curStart = -1, curEnd = -1, curDelay = -1;
    // 读不到不算致命：读不到就照写。
    ReadInt(kStart, &curStart);
    ReadInt(kEnd, &curEnd);
    ReadInt(kDelay, &curDelay);

    // 插上电就限，不等几十小时（smart_charge_delay 的 0 = NO_DELAY_MODE，battery.c:572-582 的 set_charge_delay）。
    if (curDelay != 0 && !WriteInt(kDelay, 0)) return IllegalState();
    if (curEnd != end && !WriteInt(kEnd, end)) return IllegalState();
    if (curStart != start && !WriteInt(kStart, start)) return IllegalState();
    if (enabled != 1 && !WriteInt(kEnable, 1)) return IllegalState();

    // 读回核对：驱动对单个阈值有自动调整（见文件顶部），EC 也可能拒绝。
    int gotStart = -1, gotEnd = -1, gotEnable = -1;
    if (!ReadInt(kStart, &gotStart) || !ReadInt(kEnd, &gotEnd) || !ReadInt(kEnable, &gotEnable) ||
        gotStart != start || gotEnd != end || gotEnable != 1) {
        LOG(ERROR) << "设充电上限后读回不一致：请求 {" << start << ", " << end << ", 使能 1}，读回 {"
                   << gotStart << ", " << gotEnd << ", 使能 " << gotEnable << "}";
        return IllegalState();
    }
    LOG(INFO) << "充电上限 = " << start << "–" << end << "%";
    return ndk::ScopedAStatus::ok();
}

binder_status_t ChargingControl::dump(int fd, const char** /* args */, uint32_t /* numArgs */) {
    std::lock_guard<std::mutex> lock(mLock);
    int s = -1, e = -1, en = -1, d = -1;
    ReadInt(kStart, &s);
    ReadInt(kEnd, &e);
    ReadInt(kEnable, &en);
    ReadInt(kDelay, &d);
    dprintf(fd, "gaokun3 charging control (EC smart charge), mode LIMIT\n");
    dprintf(fd, "  %s = %d\n", kEnable.c_str(), en);
    dprintf(fd, "  %s = %d\n", kStart.c_str(), s);
    dprintf(fd, "  %s = %d\n", kEnd.c_str(), e);
    dprintf(fd, "  %s = %d\n", kDelay.c_str(), d);
    return STATUS_OK;
}

}  // namespace aidl::vendor::lineage::health
