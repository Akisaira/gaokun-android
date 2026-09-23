/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * libcamera 的【伞头文件】（umbrella header）—— 本项目的 HAL 用 <libcamera/libcamera.h>
 * 一次性拿到公开 API，而上游 libcamera 只提供单个头文件、并没有这个名字的文件。
 *
 * ⚠️ 来历要说清楚（这是本仓第 N 次遇到同一类坑）：
 *   上游 `include/libcamera/` 里没有 libcamera.h；AOSP 的 platform/external/libcamera
 *   也没有（2026-09-19 在 android-16.0.0_r4 上复核过）。而 device/huawei/gaokun3/camera
 *   的 Device.h / Provider.h / Session.h **都 include 了它**，且 `Android.bp` 的
 *   include_dirs 里有 `external/libcamera/include` —— 说明当年构建机上的
 *   `external/libcamera/include/libcamera/libcamera.h` 是**手工放进去的、从未入库**
 *   （与 `adb_keys` / `firmware` 整个目录 / mesa 那份生成出来的 Android.bp 同一类）。
 *   ⚠️ 写注释别出现两个连续字符「斜杠 + 星号」—— 在块注释里那是嵌套注释开始，
 *      clang 会以 -Werror,-Wcomment 直接判死（本文件第一次就是这么挂的，4 个 TU 全挂）。
 *   本文件是**按 HAL 实际用到的符号重建**的，一并在 prep 里安装，别再让它只活在构建机上。
 *
 * 内容取自 HAL 真正用到的东西（`grep -rhoE 'libcamera::[A-Za-z_:]+'`，2026-09-19）：
 *   Camera / CameraConfiguration / CameraManager / ControlList / FrameBuffer /
 *   FrameBufferAllocator / Request / Size / Stream / StreamConfiguration / StreamRole
 *   controls::{AnalogueGain, ExposureTime}  formats::RGB  properties::{...}
 * 故意【不】包含 logging.h / fence.h 这类会引入宏或额外类型的头 —— 用不到就别拉进来。
 */
#pragma once

#include <libcamera/camera.h>
#include <libcamera/camera_manager.h>
#include <libcamera/controls.h>
#include <libcamera/framebuffer.h>
#include <libcamera/framebuffer_allocator.h>
#include <libcamera/geometry.h>
#include <libcamera/request.h>
#include <libcamera/stream.h>

/* 这三个是构建时【生成】的头（在 generated/include/libcamera/ 下）：
 * control_ids.h / formats.h 来自 .yaml + gen-controls.py，property_ids.h 同理。 */
#include <libcamera/control_ids.h>
#include <libcamera/formats.h>
#include <libcamera/property_ids.h>
