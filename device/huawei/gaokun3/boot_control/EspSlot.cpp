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
constexpr char kMountPoint[] = "/mnt/gaokun3_esp";
constexpr char kLoaderConf[] = "/mnt/gaokun3_esp/loader/loader.conf";

// The BLS entry filenames are prefixed with the systemd machine-id, which this
// HAL has no business knowing. systemd-boot accepts a glob in `default`, so we
// write a pattern and stay independent of it.
std::string DefaultLineForSlot(int slot) {
    return std::string("default *-android-") + (slot == 0 ? "a" : "b") + ".conf";
}

// 2026-09-14: a user with a hand-partitioned dual-boot disk had no PARTLABEL on
// the ESP (only a vfat volume label), so /dev/block/by-name/esp did not exist
// and every OTA failed in postinstall — and would have failed here next. Fall
// back to finding the ESP by *content*: the only vfat partition that carries
// loader/entries/*-android-*.conf is ours (a Windows ESP has no such entries).
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
    for (const char* dev : kEspDevices) {
        if (access(dev, F_OK) == 0) return dev;
    }
    LOG(WARNING) << "no by-name/esp or by-name/EFI_system_partition; probing vfat partitions by content"
                 << " (fails under enforcing: the nodes are generic block_device)";
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
    if (result.empty()) LOG(ERROR) << "no vfat partition with loader/entries/*-android-*.conf found";
    else LOG(INFO) << "ESP found by content: " << result;
    return result;
}

class MountedEsp {
  public:
    MountedEsp() {
        if (mkdir(kMountPoint, 0700) != 0 && errno != EEXIST) {
            PLOG(ERROR) << "mkdir " << kMountPoint;
            return;
        }
        std::string dev = FindEspDevice();
        if (dev.empty()) return;
        if (mount(dev.c_str(), kMountPoint, "vfat", MS_NOATIME, nullptr) != 0) {
            PLOG(ERROR) << "mount " << dev << " -> " << kMountPoint;
            return;
        }
        mounted_ = true;
    }
    ~MountedEsp() {
        if (mounted_) {
            sync();
            if (umount(kMountPoint) != 0) PLOG(WARNING) << "umount " << kMountPoint;
        }
    }
    bool ok() const { return mounted_; }

    MountedEsp(const MountedEsp&) = delete;
    MountedEsp& operator=(const MountedEsp&) = delete;

  private:
    bool mounted_ = false;
};

}  // namespace

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
