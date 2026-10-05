/*
 * Slot mirroring from Android's misc partition into systemd-boot's loader.conf.
 *
 * Copyright 2026 The gaokun-android contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "EspSlot.h"

#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include <android-base/file.h>
#include <dirent.h>
#include <fnmatch.h>
#include <unistd.h>

#include <android-base/logging.h>
#include <android-base/strings.h>

namespace gaokun3 {
namespace {

// A wipe install gives the ESP the PARTLABEL `esp`. A dual-boot install reuses
// the Windows ESP untouched, whose PARTLABEL is "EFI system partition"; ueventd
// sanitizes that to EFI_system_partition (system/core/init/devices.cpp,
// SanitizePartitionName). Both names are labeled gaokun3_esp_block_device in
// sepolicy/file_contexts. Anything else falls through to the content probe
// below, which cannot work under enforcing: the node is then generic
// block_device, and domain.te:705 forbids opening that.
constexpr const char* kEspDevices[] = {"/dev/block/by-name/esp",
                                       "/dev/block/by-name/EFI_system_partition"};
constexpr const char* kMountPoint = kEspRoot;
constexpr char kLoaderConf[] = "/mnt/gaokun3_esp/loader/loader.conf";

// The BLS entry filenames are prefixed with the systemd machine-id, which this
// HAL has no business knowing. systemd-boot accepts a glob in `default`, so we
// write a pattern and stay independent of it.
//
// ★ 统一启动入口（2026-10-05，S9）：这个通配同时匹配 gk3boot 的 efi 条目 gk3boot-android-<x>[+N].conf
//   与上一版入口 gk3prev-android-<x>.conf。这是【设计如此】，不用改：它们的 sort-key（0gk3 / 0gk3prev）
//   排在直连条目（zandroid<x>）前面，systemd-boot 按排序取第一个匹配 ⇒ 正常走 gk3boot，入口计数用完
//   （排到最后）时才落到直连条目（docs/boot-entry-design.md §4.2、§4.6.1）。default 里的字母从此只决定
//   "回落时走哪一槽的直连条目"；真正选槽的是 gk3boot 读 misc。
std::string DefaultLineForSlot(int slot) {
    return std::string("default *-android-") + (slot == 0 ? "a" : "b") + ".conf";
}

// 2026-09-14: a user with a hand-partitioned dual-boot disk had no PARTLABEL on
// the ESP (only a vfat volume label), so /dev/block/by-name/esp did not exist
// and every OTA failed in postinstall — and would have failed here next. Fall
// back to finding the ESP by *content*: the only vfat partition that carries
// loader/entries/*-android-*.conf is ours (a Windows ESP has no such entries).
// ⓘ 2026-10-05：gk3boot / gk3prev 条目也匹配这个通配 —— 它们同样是我们写的，用来"认 ESP"没问题，不排除
//   （gk3boot 条目不会脱离直连条目单独存在：它的 fail-open 要指向直连条目）。
constexpr char kProbeMountPoint[] = "/mnt/gaokun3_esp_probe";

bool LooksLikeOurEsp(const std::string& dev) {
    if (mkdir(kProbeMountPoint, 0700) != 0 && errno != EEXIST) return false;
    if (mount(dev.c_str(), kProbeMountPoint, "vfat", MS_RDONLY | MS_NOATIME, nullptr) != 0)
        return false;
    bool found = false;
    std::string entries = std::string(kProbeMountPoint) + "/loader/entries";
    if (DIR* d = opendir(entries.c_str())) {
        while (struct dirent* e = readdir(d)) {
            if (fnmatch("*-android-*.conf", e->d_name, 0) == 0) { found = true; break; }
        }
        closedir(d);
    }
    umount(kProbeMountPoint);
    return found;
}

std::string FindEspDevice() {
    // The by-name links are candidates, not answers: a disk can carry the
    // Windows ESP ("EFI system partition") next to a separate Android ESP with
    // some other name — the hand-partitioned layout the content probe below was
    // written for. So each candidate must pass the same content check. Both
    // candidates carry gaokun3_esp_block_device, so this works under enforcing.
    const char* named = nullptr;
    for (const char* dev : kEspDevices) {
        if (access(dev, F_OK) != 0) continue;
        if (!named) named = dev;
        if (LooksLikeOurEsp(dev)) return dev;
    }
    LOG(WARNING) << "no by-name ESP candidate holds loader/entries/*-android-*.conf; probing vfat partitions by content"
                 << " (fails under enforcing: those nodes are generic block_device)";
    DIR* d = opendir("/dev/block");
    if (!d) return "";
    std::string result;
    while (struct dirent* e = readdir(d)) {
        std::string name = e->d_name;
        if (fnmatch("nvme*n*p*", e->d_name, 0) != 0 && fnmatch("sd*[0-9]", e->d_name, 0) != 0 &&
            fnmatch("mmcblk*p*", e->d_name, 0) != 0)
            continue;
        std::string dev = "/dev/block/" + name;
        if (LooksLikeOurEsp(dev)) { result = dev; break; }
    }
    closedir(d);
    // Last resort, the pre-2026-09-14 behaviour: trust the name. by-name/esp is
    // what a wipe install creates, so an empty loader/entries there is more
    // likely a damaged ESP than a wrong one.
    if (result.empty() && named) {
        LOG(WARNING) << "content probe found nothing; falling back to " << named;
        return named;
    }
    if (result.empty()) LOG(ERROR) << "no vfat partition with loader/entries/*-android-*.conf found";
    else LOG(INFO) << "ESP found by content: " << result;
    return result;
}

// 挂载点与探测挂载点都是进程内共享的（见 EspSlot.h 里 MountedEsp 的说明）。
std::mutex& EspMutex() {
    static std::mutex m;
    return m;
}

}  // namespace

MountedEsp::MountedEsp(bool read_only) : lock_(EspMutex()) {
    if (mkdir(kMountPoint, 0700) != 0 && errno != EEXIST) {
        PLOG(ERROR) << "mkdir " << kMountPoint;
        return;
    }
    std::string dev = FindEspDevice();
    if (dev.empty()) return;
    if (mount(dev.c_str(), kMountPoint, "vfat", MS_NOATIME | (read_only ? MS_RDONLY : 0), nullptr) != 0) {
        PLOG(ERROR) << "mount " << dev << " -> " << kMountPoint;
        return;
    }
    mounted_ = true;
}

MountedEsp::~MountedEsp() {
    if (mounted_) {
        sync();
        if (umount(kMountPoint) != 0) PLOG(WARNING) << "umount " << kMountPoint;
    }
}

bool SetEspDefaultSlot(int slot) {
    if (slot != 0 && slot != 1) {
        LOG(ERROR) << "SetEspDefaultSlot: invalid slot " << slot;
        return false;
    }

    MountedEsp esp;
    if (!esp.ok()) return false;

    std::string contents;
    if (!android::base::ReadFileToString(kLoaderConf, &contents)) {
        PLOG(ERROR) << "read " << kLoaderConf;
        return false;
    }

    // Replace the existing `default` directive in place so that timeout,
    // console-mode, editor and any comments the operator left survive.
    const std::string wanted = DefaultLineForSlot(slot);
    std::vector<std::string> out;
    bool replaced = false;
    for (const auto& line : android::base::Split(contents, "\n")) {
        if (android::base::StartsWith(android::base::Trim(line), "default")) {
            if (!replaced) {
                out.push_back(wanted);
                replaced = true;
            }
            continue;  // drop any further default lines; systemd-boot honours the first
        }
        out.push_back(line);
    }
    if (!replaced) out.push_back(wanted);

    const std::string result = android::base::Join(out, "\n");

    // Write through a temporary file in the same directory, then rename.
    // vfat has no atomic-rename-over-existing guarantee the way ext4 does, but
    // this still shrinks the window in which loader.conf is truncated, and a
    // torn loader.conf only costs a trip through the boot menu — systemd-boot
    // falls back to showing the entry list.
    const std::string tmp = std::string(kLoaderConf) + ".new";
    if (!android::base::WriteStringToFile(result, tmp)) {
        PLOG(ERROR) << "write " << tmp;
        return false;
    }
    if (rename(tmp.c_str(), kLoaderConf) != 0) {
        PLOG(ERROR) << "rename " << tmp << " -> " << kLoaderConf;
        unlink(tmp.c_str());
        return false;
    }

    LOG(INFO) << "systemd-boot default now: " << wanted;
    return true;
}

}  // namespace gaokun3
