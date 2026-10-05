/*
 * Slot mirroring from Android's misc partition into systemd-boot's loader.conf.
 *
 * Copyright 2026 The gaokun-android contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#include <mutex>

namespace gaokun3 {

// Point systemd-boot at the given slot (0 = _a, 1 = _b) by rewriting the
// `default` line of loader.conf on the ESP. Returns false if the ESP could
// not be mounted or written; the caller should surface that as a HAL error
// so update_engine does not believe the switch happened.
bool SetEspDefaultSlot(int slot);

// ESP 挂在这里（MountedEsp 存活期间）。
inline constexpr char kEspRoot[] = "/mnt/gaokun3_esp";

// 挂上 ESP，析构时 sync + umount。
//
// ★ 2026-10-05（统一启动入口 S9）：带一把进程内的锁。原来只有 binder 线程（setActiveBootSlot /
//   markBootSuccessful）用它；现在开机完成线程（Gk3Boot.cpp：bless、部署入口）也要挂 ESP，两边用的是
//   同一个挂载点 —— 没有锁，一个线程的析构会把另一个线程正在写的 ESP 卸掉。锁在挂载之前拿、卸载之后放。
//
// read_only：只读挂（MS_RDONLY）。开机完成线程先只读挂上把要做的事算一遍，确实要改才读写挂 ——
//   vfat 读写挂载本身就会在盘上置 / 清"脏"位，正常开机要做到对 ESP 零写入（设计稿 §4.12）。
class MountedEsp {
  public:
    explicit MountedEsp(bool read_only = false);
    ~MountedEsp();
    bool ok() const { return mounted_; }

    MountedEsp(const MountedEsp&) = delete;
    MountedEsp& operator=(const MountedEsp&) = delete;

  private:
    std::unique_lock<std::mutex> lock_;
    bool mounted_ = false;
};

}  // namespace gaokun3
