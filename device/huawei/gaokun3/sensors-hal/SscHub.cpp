/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "SscHub.h"

#include <android-base/logging.h>

#include <chrono>
#include <vector>

#include "ssc-sensor-accelerometer.pb.h"

namespace gaokun3 {
namespace {
// 50 Hz 足够自动旋转与体感；SSC 会给出它实际采用的速率。
constexpr float kRateHz = 50.0f;
// hexagonrpcd 刚起来时 SSC 约需 20 秒沉降，给足余量（实测 6 秒读不到）。
constexpr int kServiceWaitMs = 60000;
// 全部停用后，先把 socket 里已在途的上报读掉再睡，免得下次使能时先读到
// 停用前的旧样本。SSC 约 5 Hz 成批投递（#119 §4），半秒足够收尾。
constexpr int kDrainMs = 500;
}  // namespace

SscHub& SscHub::Get() {
    static SscHub instance;
    return instance;
}

void SscHub::EnsureStarted() {
    std::call_once(started_, [this]() {
        thread_ = std::thread([this]() { ReaderLoop(); });
    });
}

Sample SscHub::Accel() {
    EnsureStarted();
    std::lock_guard<std::mutex> lk(m_);
    return accel_;
}

Sample SscHub::Gyro() {
    EnsureStarted();
    std::lock_guard<std::mutex> lk(m_);
    return gyro_;
}

void SscHub::SetAccelWanted(bool on) {
    EnsureStarted();
    {
        std::lock_guard<std::mutex> lk(m_);
        want_accel_ = on;
    }
    cv_.notify_all();
}

void SscHub::SetGyroWanted(bool on) {
    EnsureStarted();
    {
        std::lock_guard<std::mutex> lk(m_);
        want_gyro_ = on;
    }
    cv_.notify_all();
}

void SscHub::ReaderLoop() {
    while (!stop_) {
        SscClient client;
        std::string err;

        if (!client.Open(&err)) {
            LOG(ERROR) << "SscHub: 打开 SSC 失败: " << err;
            std::this_thread::sleep_for(std::chrono::seconds(5));
            continue;
        }
        if (!client.WaitForService(kServiceWaitMs, &err)) {
            LOG(ERROR) << "SscHub: SSC 未就绪: " << err;
            std::this_thread::sleep_for(std::chrono::seconds(5));
            continue;
        }
        LOG(INFO) << "SscHub: SSC 就绪，服务在 node " << client.service_node()
                  << " port " << client.service_port();

        // ★★ 物理传感器比 registry 服务【晚】注册，所以刚就绪时查 accel 会
        //    得到"没有传感器提供"。必须在【同一个 client 上】重试等它出现。
        //    ⚠️ 千万不要为此重建会话：每次重建都在 SSC 上留下一个被丢弃的
        //    客户端，实测那种 churn 会把传感器枚举彻底弄坏 —— 之后连独立
        //    命令行客户端都找不到 accel，必须重启 hexagonrpcd 才恢复。
        //    这是 2026-08-20 实测定位到的真实故障，不是防御性编程。
        //
        //    本机只有这两个可用：mag 没有硬件、rotv 未注册，
        //    ambient_light 一使能就污染会话（#37），所以坚决不碰。
        SscUid accel_uid, gyro_uid;
        bool has_accel = false, has_gyro = false;
        for (int round = 0; round < 30 && !stop_; round++) {
            if (!has_accel) has_accel = client.FindSensor("accel", &accel_uid, &err);
            if (!has_gyro) has_gyro = client.FindSensor("gyro", &gyro_uid, &err);
            if (has_accel && has_gyro) break;
            std::this_thread::sleep_for(std::chrono::seconds(2));
        }
        if (!has_accel && !has_gyro) {
            LOG(ERROR) << "SscHub: 等了 60 秒仍没有任何传感器注册，重建会话";
            std::this_thread::sleep_for(std::chrono::seconds(30));
            continue;
        }
        LOG(INFO) << "SscHub: accel=" << has_accel << " gyro=" << has_gyro;

        // ★ 按订阅启停（PWR-3）：此前会话一建好就 EnableContinuous、之后再不停，
        //   框架没有任何订阅者时 SLPI 也 50 Hz 常开、几乎不睡。现在只开"有人要"的
        //   那一路，最后一个订阅者走了就 Disable。
        //   ⚠️ 启停一律在【这个 client】上做，绝不为此重建会话（理由见上）。
        //   on_* = 此刻在 SSC 上实际开着的，只有本线程读写；会话刚建好时全是
        //   false，下面按 want_* 补开 —— 重建会话后原有订阅也就自动恢复。
        bool on_accel = false, on_gyro = false;
        auto drain = [&client]() {
            const auto until = std::chrono::steady_clock::now() +
                               std::chrono::milliseconds(kDrainMs);
            while (std::chrono::steady_clock::now() < until) {
                std::vector<SscReport> junk;
                std::string ignore;
                client.ReadReports(&junk, 100, &ignore);
            }
        };

        // 收数。连续空转说明会话坏了（例如别的进程去碰了光感）。
        // 先在同一个 client 上重新使能一次，还是不行才整条重建 —— 同样是为了
        // 少制造客户端 churn。
        // ★ 看门狗只在"有人要、流该开着"时计时：都停用时读数本来就是 0，照算的话
        //   15 秒后它会自己把流重新打开、60 秒后重建会话 —— 恰好制造上面警告的 churn。
        int idle = 0;
        bool re_enabled = false;
        while (!stop_) {
            bool want_accel, want_gyro;
            {
                std::lock_guard<std::mutex> lk(m_);
                want_accel = want_accel_ && has_accel;
                want_gyro = want_gyro_ && has_gyro;
                // 要停用的那一路缓存作废：下次使能、新数据到之前报 UNRELIABLE，
                // 而不是拿停用前的旧值当真值（旧的角速度会让游戏视角一直漂）
                if (on_accel && !want_accel) accel_ = Sample();
                if (on_gyro && !want_gyro) gyro_ = Sample();
            }
            const bool was_on = on_accel || on_gyro;
            if (want_accel != on_accel) {
                const bool ok = want_accel
                        ? client.EnableContinuous(accel_uid, kRateHz, &err)
                        : client.Disable(accel_uid, &err);
                LOG(INFO) << "SscHub: accel " << (want_accel ? "使能" : "停用")
                          << (ok ? "" : " 失败: " + err);
                on_accel = want_accel;
                idle = 0;
                re_enabled = false;
            }
            if (want_gyro != on_gyro) {
                const bool ok = want_gyro
                        ? client.EnableContinuous(gyro_uid, kRateHz, &err)
                        : client.Disable(gyro_uid, &err);
                LOG(INFO) << "SscHub: gyro " << (want_gyro ? "使能" : "停用")
                          << (ok ? "" : " 失败: " + err);
                on_gyro = want_gyro;
                idle = 0;
                re_enabled = false;
            }

            // 都没人要：读掉在途的上报，然后不收数、不计空转，睡到有人 activate
            if (!on_accel && !on_gyro) {
                if (was_on) drain();
                idle = 0;
                re_enabled = false;
                std::unique_lock<std::mutex> lk(m_);
                cv_.wait(lk, [&]() {
                    return stop_ || (want_accel_ && has_accel) ||
                           (want_gyro_ && has_gyro);
                });
                continue;
            }

            std::vector<SscReport> reports;
            std::string ignore;
            if (!client.ReadReports(&reports, 1000, &ignore)) {
                if (++idle == 15 && !re_enabled) {
                    LOG(WARNING) << "SscHub: 15 秒无读数，在同一会话上重新使能";
                    if (on_accel) client.EnableContinuous(accel_uid, kRateHz, &err);
                    if (on_gyro) client.EnableContinuous(gyro_uid, kRateHz, &err);
                    re_enabled = true;
                    continue;
                }
                if (idle >= 60) break;   // 真的坏了，重建
                continue;
            }
            idle = 0;
            re_enabled = false;
            for (size_t i = 0; i < reports.size(); i++) {
                const SscReport& r = reports[i];
                if (r.msg_id != kMsgReportMeasurement) continue;
                SscAccelerometerResponse m;
                if (!m.ParseFromString(r.payload)) continue;
                if (m.acceleration_size() < 3) continue;

                Sample s;
                s.v[0] = m.acceleration(0);
                s.v[1] = m.acceleration(1);
                s.v[2] = m.acceleration(2);
                s.accuracy = m.accuracy();
                s.valid = true;

                // 只写开着的那一路：刚停用的那一路可能还有在途的上报
                std::lock_guard<std::mutex> lk(m_);
                if (on_accel && r.uid_low == accel_uid.low() &&
                    r.uid_high == accel_uid.high()) {
                    accel_ = s;
                } else if (on_gyro && r.uid_low == gyro_uid.low() &&
                           r.uid_high == gyro_uid.high()) {
                    gyro_ = s;
                }
            }
        }
        if (on_accel) client.Disable(accel_uid, &err);
        if (on_gyro) client.Disable(gyro_uid, &err);
        LOG(WARNING) << "SscHub: 60 秒没有读数，重建 SSC 会话";
    }
}

}  // namespace gaokun3
