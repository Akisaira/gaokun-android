/*
 * lights HAL for the Huawei MateBook E Go (gaokun3).
 *
 * 为什么要自己写：出厂装的是 AOSP 的示例实现
 * （android.hardware.lights-service.example，跑在 nobody 下），它只把请求
 * 打进日志、从不碰硬件。实测后果是【亮度滑条完全无效】：框架从 1 调到 255，
 * /sys/class/backlight/ae96000.dsi.0/brightness 始终停在 512/4095（12.5%），
 * 机器永远是暗的。以 root 直接写那个节点则立刻生效（写 3800/100/2048 都对），
 * 所以内核这条路是好的，缺的只是一个真的 HAL。
 *
 * 只实现背光一种。这台机器没有通知灯、没有按键背光、没有电池指示灯 ——
 * 与其返回一堆假的灯让框架以为有，不如只报真实存在的那一个
 * （M12 在 sensors HAL 上学过同一课：假传感器会让框架做出错误判断）。
 */
#define LOG_TAG "gaokun3-lights"

#include <aidl/android/hardware/light/BnLights.h>
#include <android-base/file.h>
#include <android-base/logging.h>
#include <android-base/parseint.h>
#include <android-base/strings.h>
#include <android/binder_manager.h>
#include <android/binder_process.h>

#include <dirent.h>
#include <algorithm>
#include <cerrno>
#include <cstring>
#include <string>
#include <vector>

namespace aidl::android::hardware::light {

namespace {

constexpr char kBacklightDir[] = "/sys/class/backlight";

// 背光节点的名字来自设备树（本机是 ae96000.dsi.0）。不写死 —— 换 DTB 或换面板
// 就会变，而一个静默失效的 HAL 比编译失败难查得多。
std::string FindBacklight() {
    std::unique_ptr<DIR, decltype(&closedir)> dir(opendir(kBacklightDir), closedir);
    if (!dir) return "";
    std::vector<std::string> found;
    while (struct dirent* e = readdir(dir.get())) {
        std::string n(e->d_name);
        if (n == "." || n == "..") continue;
        found.push_back(n);
    }
    if (found.empty()) return "";
    std::sort(found.begin(), found.end());
    if (found.size() > 1) {
        LOG(WARNING) << "有 " << found.size() << " 个背光设备，用第一个: " << found[0];
    }
    return std::string(kBacklightDir) + "/" + found[0];
}

int ReadInt(const std::string& path, int fallback) {
    std::string s;
    if (!::android::base::ReadFileToString(path, &s)) return fallback;
    int v = fallback;
    if (!::android::base::ParseInt(::android::base::Trim(s), &v)) return fallback;
    return v;
}

// AOSP 一贯的算法：把 ARGB 折成单个亮度（Rec.601 权重）。框架传下来的其实是
// 0xFFvvvvvv 这种灰阶，但照着标准做法算，别自作聪明只取一个通道。
uint32_t RgbToBrightness(int32_t color) {
    uint32_t c = static_cast<uint32_t>(color);
    return ((77 * ((c >> 16) & 0xff)) + (150 * ((c >> 8) & 0xff)) + (29 * (c & 0xff))) >> 8;
}

}  // namespace

class Lights : public BnLights {
  public:
    Lights() : mPath(FindBacklight()) {
        if (mPath.empty()) {
            LOG(ERROR) << "在 " << kBacklightDir << " 下没找到背光设备 —— 亮度将无法调节";
            return;
        }
        mMax = ReadInt(mPath + "/max_brightness", 255);
        if (mMax <= 0) mMax = 255;
        LOG(INFO) << "背光: " << mPath << "  max_brightness=" << mMax;
    }

    ::ndk::ScopedAStatus setLightState(int32_t id, const HwLightState& state) override {
        if (id != kBacklightId) {
            // 其余类型本机没有硬件。返回成功而不是报错：框架对失败会重试并刷日志。
            return ::ndk::ScopedAStatus::ok();
        }
        // ★ 这个 HAL 对背光【永远】返回 ok()，失败只记日志（LIVE-1 / PERF-1 / APP-7）。
        //   框架不接错误：LightsService.setLightUnchecked 不捕获 ServiceSpecificException，
        //   它在 DisplayPowerState$PhotonicModulator 线程里抛出 ⇒ system_server 被杀、整机
        //   软重启。2026-10-02 dropbox 里实有一条（code -5 = 下面原来返回的 -EIO，亮灭屏过渡中）。
        //   丢一次写入的代价远小于软重启：熄屏过渡中丢的那次本来就看不见；亮屏那次若丢了，
        //   面板停在旧亮度，直到下一次调亮度（自动亮度 / 滑条）覆盖。
        if (mPath.empty()) {
            return ::ndk::ScopedAStatus::ok();  // 构造时已经报过 ERROR，这里不再刷屏
        }

        uint32_t v = RgbToBrightness(state.color);          // 0..255
        // 线性映射到面板刻度。曲线（感知亮度）是框架的活，它有自己的
        // brightness→nits 映射；HAL 再叠一层曲线只会两边打架。
        int out = static_cast<int>((static_cast<int64_t>(v) * mMax + 127) / 255);
        out = std::max(0, std::min(mMax, out));

        if (!::android::base::WriteStringToFile(std::to_string(out), mPath + "/brightness")) {
            const int err = errno;  // 先存下来，后面的日志调用会改 errno
            // 限流：一串连续失败只记第一条和之后每第 kLogEvery 条，恢复时补一条总数。
            // 根因未实测（怀疑面板 / DSI 下电时 himax_bl_update_status 仍发 DCS），
            // 所以第一条一定要带 errno 与要写的值 —— 下次复现靠它查。
            ++mFailStreak;
            if (mFailStreak == 1 || mFailStreak % kLogEvery == 0) {
                LOG(ERROR) << "写 " << mPath << "/brightness=" << out << " 失败: "
                           << strerror(err) << " (errno " << err << ")，连续第 " << mFailStreak
                           << " 次；上次成功写入的值 " << mLastOk
                           << "（EACCES 看 init 里的 chown；忽略本次，不向框架报错）";
            }
            return ::ndk::ScopedAStatus::ok();
        }
        if (mFailStreak > 0) {
            LOG(WARNING) << "背光写入恢复（此前连续失败 " << mFailStreak << " 次），当前值 " << out;
            mFailStreak = 0;
        }
        mLastOk = out;
        return ::ndk::ScopedAStatus::ok();
    }

    ::ndk::ScopedAStatus getLights(std::vector<HwLight>* lights) override {
        lights->clear();
        if (!mPath.empty()) {
            HwLight l;
            l.id = kBacklightId;
            l.ordinal = 0;
            l.type = LightType::BACKLIGHT;
            lights->push_back(l);
        }
        return ::ndk::ScopedAStatus::ok();
    }

  private:
    static constexpr int32_t kBacklightId = 0;
    static constexpr int kLogEvery = 100;
    const std::string mPath;
    int mMax = 255;
    // 只在 binder 线程里改。线程池上限是 0（main 里），只有 main 线程自己
    // joinThreadPool 处理调用 ⇒ 单线程，不用加锁。
    int mFailStreak = 0;
    int mLastOk = -1;  // -1 = 本次开机还没写成功过
};

}  // namespace aidl::android::hardware::light

int main() {
    ABinderProcess_setThreadPoolMaxThreadCount(0);
    auto lights = ::ndk::SharedRefBase::make<aidl::android::hardware::light::Lights>();

    const std::string name =
            std::string(aidl::android::hardware::light::Lights::descriptor) + "/default";
    binder_status_t st = AServiceManager_addService(lights->asBinder().get(), name.c_str());
    if (st != STATUS_OK) {
        LOG(FATAL) << "注册 " << name << " 失败: " << st;
    }
    ABinderProcess_joinThreadPool();
    return EXIT_FAILURE;  // 不该走到这里
}
