/*
 * SscHub —— sensors HAL 与 SLPI 之间的唯一通道
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * 设计要点：**整个 SSC 会话由一个线程独占**。
 * SscClient 的收发都在那个线程上做（它有 txn 计数器，而且 FindSensor 内部
 * 自己也在 recv），多线程同时用同一个 client 一定会互相抢包。
 * 所以 HAL 各传感器的 readEventPayload 只读缓存，不碰 socket。
 *
 * 背景：本机没有 AP 侧传感器驱动，整套跑在 SLPI DSP 上，
 * 见 docs/stage4-findings.md #37 与 docs/sensors-ssc-protocol.md。
 */
#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>

#include "ssc_client.h"

namespace gaokun3 {

struct Sample {
    float v[3] = {0.f, 0.f, 0.f};
    int accuracy = 0;   // 0=不可信 … 3=最高
    bool valid = false;
};

class SscHub {
  public:
    static SscHub& Get();

    // 取最新一条样本。首次调用会启动后台线程（连 SSC、找传感器）。
    // 数据还没来时返回 valid=false —— 上层应据此报 UNRELIABLE，
    // 而不是拿 0 当真值。SSC 侧停用期间同样是 valid=false。
    Sample Accel();
    Sample Gyro();

    // 框架 activate(true/false) 时由 Sensor::activate 调用。
    // ★ 只记下"想要"，真正的 EnableContinuous / Disable 由读线程在【同一个
    //   client】上做（线程模型见文件头）。没人要时 SSC 侧停用，SLPI 才能睡
    //   （v1.0 计划 PWR-3 / LIVE-2 / HW-3：此前一被读过就 50 Hz 常开到重启）。
    void SetAccelWanted(bool on);
    void SetGyroWanted(bool on);

  private:
    SscHub() = default;
    void EnsureStarted();
    void ReaderLoop();
    // 请 init 把整条传感器链收拾一遍（etc/sscrecover.rc → bin/gaokun3-ssc-recover.sh：
    // 停本 HAL → 重启 hexagonrpcd → 起本 HAL）。v1.0 DISP-14 / HW-1（B21）：会话坏了
    // 不再在进程里重建（那正是 README 里警告的 churn），交给外面按 #121 §3 的办法重来。
    void RequestRecovery(const char* why);
    // 缓存里的样本超过这么久没刷新就当作没有（B21：SLPI 崩了以后 HAL 不能一直报旧值）
    static Sample Fresh(const Sample& s, std::chrono::steady_clock::time_point at);

    std::once_flag started_;
    std::thread thread_;
    std::atomic_bool stop_{false};

    std::mutex m_;
    std::condition_variable cv_;   // want_* 变了就叫醒空闲中的读线程
    bool want_accel_ = false;      // 以下六个都由 m_ 保护
    bool want_gyro_ = false;
    Sample accel_;
    Sample gyro_;
    std::chrono::steady_clock::time_point accel_at_;   // 上一次写进 accel_ / gyro_ 的时刻
    std::chrono::steady_clock::time_point gyro_at_;
};

}  // namespace gaokun3
