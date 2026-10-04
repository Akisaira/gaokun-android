<!--
  Maintenance (not rendered):
  * This list is "what you should know before installing this ROM": long-standing limitations, unsupported features,
    and the security and licensing trade-offs. Bugs specific to one release go into that release's Known issues, not here.
  * The comment after each entry names its id in docs/v1.0-plan.md. Check every entry before a release; delete an entry
    once it is fixed, rewrite it when the trade-off changes (e.g. SELinux goes enforcing, a Chinese IME is preinstalled).
  * Keep this file and known-limitations.zh-CN.md in sync. Evidence (file:line / on-device checks) is in the
    comments of the Chinese file; it is the same for both.
-->
# Known limitations and unsupported features

[**中文 → known-limitations.zh-CN.md**](known-limitations.zh-CN.md) · [FAQ](FAQ.md) · [Installing](INSTALL.md)

This ROM was built from scratch for a machine that has **no vendor Android support at all**. Below is what you should
know before installing it. Some of these are deliberate trade-offs, some are not done yet, and some cannot be done on
this hardware.

Every entry has the same three parts: **what you see**, **why** (in one sentence or two), and **what to do instead**.

Problems specific to one release are in that release's [release notes](relnotes/).

---

## 1. Security and privacy (read this part first)

### The system is signed with Android's public test keys
<!-- B2 / SEC-2 (user decision D2, 2026-10-04: keep test-keys, disclose). -->
* **What you see**: nothing. The build information says `release-keys`, but that is only a label.
* **Why**: the system, the system apps and the OTA update packages are signed with the test keys that ship **publicly**
  in the AOSP source; anyone can download the private keys. So **anyone** can build an OTA package, or an app that runs
  with system privileges, that this ROM will accept as genuine. The safety of this machine therefore rests on the
  download channel not being taken over, and on you not installing "system components" from unknown sources.
* **What to do**:
  * Update only through the built-in system updater in Settings, or from this project's GitHub Releases page.
  * Do not install APKs or zips that someone sends you as a "system patch" or "system component".
  * On a fresh install the installer checks `install-artifacts.sha256` before writing to the disk. Don't skip it.

### `/data` (all your personal data) is not encrypted
<!-- B3 / SEC-3 (user decision D3: no encryption in 1.0, disclose honestly). -->
* **What you see**: the lock screen protects the machine while it is running, and nothing more. It does not protect
  your data from someone who has the machine in their hands.
* **Why**: the data partition is plain ext4. Secure Boot has to be off; the boot menu offers the installer and a rescue
  system, both of which give a root login at the local console without a password; and any Linux USB stick works too.
  Whoever holds the machine can read your photos, chats, browser logins, Wi-Fi passwords and everything else.
* **What to do**:
  * Treat this machine as one whose data anyone holding it can read. Don't keep sensitive material on it.
  * Before you sell it, send it for repair or lend it out, wipe it with the graphical installer's
    **Reinstall Android** (wipes data by default), see the [FAQ](FAQ.md#factory-reset--wiping-before-you-sell).
  * If encryption arrives later, getting it will mean wiping and reinstalling. An OTA update cannot encrypt an
    existing installation.

### Root is built in (KernelSU / ReSukiSU)
<!-- SEC-12 / REL-10 (user decision D6: keep root, disclose fully; no root-less variant before 1.0).
     ⚠️ v0.7.1 and earlier do NOT preinstall the manager APK (TODO B11). If 1.0 preinstalls it, say so in the first
     sentence; the "without the manager" sentence stays true either way. -->
* **What you see**: the kernel contains a root implementation, KernelSU (the ReSukiSU fork). Some banking and payment
  apps, and games with anti-cheat, may detect it and warn about a "risky device" or refuse to run.
* **Why**: root is essential for development and troubleshooting, and we decided to keep it in release builds.
  The **ReSukiSU manager** app decides who gets root: only apps you approve in the manager do. Without the manager
  installed, no app can get root.
* **What to do**:
  * If you don't need root, don't grant it to any app in the manager.
  * There is no build without root yet, and the kernel's root capability cannot be switched off.
  * In our smoke tests, *Delta Force* and *Strinova* (both protected by ACE anti-cheat) ran normally. Banking and payment
    apps have not been tested systematically. Reports are welcome.

### SELinux runs in permissive mode
<!-- SEC-4 / D5. Delete or rewrite this entry in the release that switches to enforcing. -->
* **What you see**: nothing.
* **Why**: Android sandboxes apps in two layers: ordinary user permissions, and SELinux. The SELinux rules for this
  machine are not finished, so SELinux only logs violations and does not block them. So an app that finds a vulnerability
  can do much more than it could on a normal phone. For example, any app can use the kernel's performance counters.
* **What to do**: install apps only from sources you trust.

### The boot chain is unlocked, and system partitions are not verified
* **What you see**: nothing at boot checks whether the system has been modified. Play Integrity never passes (see
  *Not Google-certified* below).
* **Why**: the machine boots through UEFI and systemd-boot with Secure Boot off; the kernel is unsigned, and dm-verity is
  off. That open boot chain is exactly what makes installing another OS on this machine possible.
* **What to do**: nothing; this is the price of running Android on this machine at all.

---

## 2. Proprietary components shipped in the images

<!-- SEC-10 / REL-15 (D20: disclose, and prepare a build switch without Histen). NOTICE still says only "not in this
     repository" and does not cover binary releases; that is handled by another item. -->
The source code of this project is released under GPL and other open-source licenses (see [NOTICE](../NOTICE)). The
**system images, OTA packages and installer images** we publish also contain the components below, which are **not
part of this project and not open source**. Without them there is no GPU, Wi-Fi, Bluetooth, sound or sensors:

| Component | Where on the system | Comes from | Notes |
|---|---|---|---|
| Huawei firmware: GPU zap shader, ADSP / CDSP / SLPI firmware, audio topology, pd_mapper service tables | `/vendor/firmware/qcom/sc8280xp/HUAWEI/gaokun3/` | Huawei's Windows driver packages | Not licensed by Huawei for redistribution. The installer image carries the GPU one as well |
| Sensor DSP configuration (SLPI JSON files and registry) | `/vendor/etc/hexagonrpcd-root/` | Same (Qualcomm reference configuration) | Same |
| Histen audio engine `libhw_histen_processing.so` | `/vendor/lib64/soundfx/` | Huawei Windows driver | Proprietary to Huawei, not licensed for redistribution, and binary-patched. It processes audio only when *Speaker enhancement (experimental)* is turned on |
| Google apps and services (MindTheGapps: Play Store, Play services, …) | `/system_ext`, `/product` | Google | Closed source, under Google's terms |
| GPU microcode, Wi-Fi and Bluetooth firmware | `/vendor/firmware/` | linux-firmware | Under Qualcomm's redistributable license; not affected by the above |

So if a rights holder asks for it, the downloads could be taken down. If you mirror or redistribute the images
yourself, you should know that they contain these components.

---

## 3. Unsupported or incomplete features

### *Erase all data* (factory reset) in Settings does nothing
<!-- B6 / A5 (user decision D4: to be handled by a future fastboot; design in progress). Rewrite once fastboot ships. -->
* **What you see**: the machine reboots and **all your data is still there**, with no message.
* **Why**: that feature relies on recovery to carry it out, and recovery cannot boot on this machine, so after the reboot
  nothing acts on the request. A fastboot-based factory reset is being designed.
* **What to do**: use the graphical installer's **Reinstall Android**, which wipes data by default. Steps in the
  [FAQ](FAQ.md#factory-reset--wiping-before-you-sell).

### No file transfer over USB (no MTP / PTP)
<!-- PWR-6 / BKUP-7 / STOR-7 (1.0: documentation only; the real thing is after 1.0). -->
* **What you see**: when you connect the tablet to a computer, no drive or "portable device" appears on the computer, and
  the tablet shows no "USB preferences / File transfer" notification or setting.
* **Why**: on the USB device side only adb debugging is implemented. File transfer needs the whole USB function-switching
  machinery, which must be tested together with a known USB-C port problem; it is planned for after 1.0.
* **What to do**:
  * Use a local-network transfer app (e.g. LocalSend) or a cloud drive.
  * With adb: enable USB debugging, then `adb pull /sdcard/DCIM/ .` or `adb push file /sdcard/Download/`.
  * While it is plugged into a computer's USB port the machine does not go to standby (deliberately: standby in that
    state resets the board). Unplug when you are done.

### USB sticks are not recognised
<!-- STOR-1 / BKUP-6 (planned for batch 1: voldmanaged in fstab). Delete once fixed and tested. -->
* **What you see**: a USB stick or external drive does not appear in the file manager.
* **Why**: the kernel does see it, but the system's partition table doesn't declare any removable storage, so Android
  never mounts it.
* **What to do**: nothing yet. Use the network to copy files.

### Fingerprint does not work (in progress)
<!-- HW-5 / T6 (D12: not a 1.0 gate). -->
* **What you see**: the fingerprint reader in the power button does not exist as far as Android is concerned; Settings
  has no fingerprint option.
* **Why**: matching runs inside Huawei-signed secure firmware, and its command protocol has to be reverse-engineered from
  the Windows driver. Huawei's fingerprint program can already be loaded into the secure environment; the kernel driver
  and the Android fingerprint service are still missing.
* **What to do**: unlock with a PIN or password. Even once fingerprint works, fingerprint payments in payment apps will
  most likely still be unavailable.

### Stylus (Huawei M-Pencil) is not supported
<!-- DISP-13. Postponed past 1.0 (needs reverse-engineering of raw frames). -->
* **What you see**: the pen does nothing at all: no pressure, no hover.
* **Why**: the touch points are computed by the kernel driver itself from raw capacitance data, and that algorithm only
  knows fingers. Nobody has reverse-engineered the pen's signal format yet.
* **What to do**: nothing.

### No automatic brightness
<!-- DISP-8 / HW-4 / A3 (#121). -->
* **What you see**: there is no *Adaptive brightness* in Settings; brightness is manual only.
* **Why**: the light sensor answers on its bus, but turning it on crashes the DSP that runs the sensors, so it stays off.
* **What to do**: adjust brightness by hand.

### Location mostly does not work (no GPS)
<!-- APP-13 / NET-5. Whether domestic apps' own Wi-Fi location SDKs work: not tested yet (batch 4). -->
* **What you see**: maps, weather, delivery and ride-hailing apps cannot get a position, or keep "locating".
* **Why**: the system has no GPS. Network location is provided by Google Play services, which cannot reach Google from
  mainland China.
* **What to do**:
  * Choose your city manually in weather apps and similar.
  * Apps with their own location SDK (for example map apps that locate by Wi-Fi) may work; we have not tested them.
  * Use a phone for navigation.

### No DRM-protected video (no Widevine)
<!-- AV-9 / APP-6 (D11: don't ship it, disclose). Impact on Chinese video apps' VIP content: not tested. -->
* **What you see**: Netflix, Disney+, Prime Video and the like will not play their shows; they report a DRM or "device
  not supported" error. Some paid or licensed content in Chinese video apps may be affected too (not tested yet).
* **Why**: the system has no DRM module at all. Widevine is a closed Google component that needs licensing and
  certification, which we cannot provide.
* **What to do**: watch such content on another device.

### Bluetooth headset microphone does not work in calls
<!-- AV-2 (1.0: disclose only). AV-3: A2DP playback never fully verified on hardware. AV-10: the wired headset mic is
     broken too (planned for batch 2; drop that sentence once fixed). -->
* **What you see**: in WeChat voice calls, Tencent Meeting, in-game voice chat and the like, the microphone on a
  Bluetooth headset does not work, and the call audio may not go to the headset either. The microphone on a wired headset
  does not work at the moment either.
* **Why**: Bluetooth calls need a dedicated audio path. Phones get it from Qualcomm's Android software, which this
  machine doesn't have, and the system has no replacement for it yet.
* **What to do**: use the tablet's built-in microphone and speakers for calls. Listening to music over Bluetooth (A2DP)
  takes a different path and is not affected, though it has not been fully tested on hardware yet.

### No push notifications while in standby
<!-- APP-5 / NET-9 / PWR-12 (1.0: measure, then disclose; WoW after 1.0). Fill in measured delays after batch 4. -->
* **What you see**: once the screen is off and the machine is in standby, new WeChat, QQ and other messages do not
  arrive in real time. They arrive together when you turn the screen on (or when the system wakes up on a timer).
  After each wake, Wi-Fi takes a few seconds to reconnect.
* **Why**: in standby the Wi-Fi chip is powered off completely, so nothing arriving over the network can wake the
  machine. Chinese apps also have no vendor push channel available on this system.
* **What to do**:
  * When you need messages promptly, keep the screen on, or receive them on your phone.
  * Or turn standby off completely, which costs noticeably more battery with the screen off. This needs root (grant it
    to Shell in the ReSukiSU manager):
    `adb shell su -c "setprop persist.vendor.gaokun3.allow_suspend 0"`. The setting survives reboots; set it back to `1`
    to get standby back.

### Not Google-certified
<!-- T2 / INST-14 / APP-4. -->
* **What you see**: the Play Store says "This device isn't Play Protect certified" and some apps will not install. Apps
  that depend on Play Integrity (Google Wallet, some banks outside China) do not work.
* **Why**: this ROM is not on Google's list of certified devices. Play Integrity also requires a locked boot chain and a
  Google-signed system, which this machine can never meet.
* **What to do**: register the device once, as described in
  [INSTALL.md, "This device isn't Play Protect certified"](INSTALL.md#this-device-isnt-play-protect-certified), and the
  Play Store works normally. There is nothing to be done about Play Integrity.

### Google apps are built in, unusable in mainland China, and there is no Chinese app store
<!-- APP-12 (user decision D7: ship only the GApps build, no vanilla build). Battery cost of GMS retrying: not measured. -->
* **What you see**: without a proxy, neither the Play Store nor Google services can connect, and Google services keep
  retrying in the background (battery impact not measured). There is no Chinese app store on the system.
* **Why**: we only ship the build with Google apps.
* **What to do**: download APKs with the browser, from each app's official website or from the web version of a Chinese
  app store.

### Other hardware that is not there
* **No cellular network, no SIM**: the machine has no modem.
* **No compass**: there is no magnetometer. Auto-rotate works; it uses the accelerometer and gyroscope.

---

## 4. Other common problems (planned to improve)

These are bugs, not trade-offs, and they will be removed from this list once fixed.

<!-- NET-2 (batch 2). The v0.7.1 notes blamed the chip; iw shows the driver supports STA+AP, the software config does not. -->
* **Turning on the Wi-Fi hotspot disconnects the tablet from Wi-Fi.** With no modem, the hotspot then has no
  connection to share. The current software configuration cannot run Wi-Fi and the hotspot at the same time; this is
  not a limit of the chip.
<!-- DISP-3 (D10). Delete once a Chinese IME is preinstalled. -->
* **No Chinese input method is included.** The built-in keyboard has no Chinese. Install a Chinese IME yourself
  (download the APK from the IME's website).
