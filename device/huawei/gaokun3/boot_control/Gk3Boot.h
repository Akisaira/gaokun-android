/*
 * 统一启动入口（gk3boot.efi）的 Android 侧：开机完成线程。
 * 设计：docs/boot-entry-design.md §4.6.1、§4.11、§4.12；实现说明在 Gk3Boot.cpp 顶部。
 *
 * Copyright 2026 The gaokun-android contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

namespace gaokun3 {

// 起一个分离的线程：等 vendor.gaokun3.boot.done=1（vendor rc 在 sys.boot_completed=1 时设），
// 然后做一次 bless / 清 boot_streak / 导出事件 / 按 persist.vendor.gaokun3.gk3boot 部署或撤掉入口。
// main() 在加入 binder 线程池之前调一次。
void StartBootCompletedWorker();

}  // namespace gaokun3
