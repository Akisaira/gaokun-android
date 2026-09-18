# Installing

> ### ⚠️ This erases the internal disk — Windows included.
> There is no undo, and no image of the factory state exists anywhere. If you
> want Windows back you will have to reinstall it yourself from Huawei's
> recovery media. Read all of this before starting.

## Before you begin

| Requirement | Why |
|---|---|
| **Huawei MateBook E Go, GK-W7X** | The only model this has been built and tested on |
| **BIOS 2.16** | **Do not upgrade to 2.17.** The touch SPI bus and GPIO numbering differ, and the upstream touch driver targets 2.16. Check in the firmware setup screen |
| **Secure Boot disabled** | The kernel is unsigned |
| An arm64 Linux live USB | Ubuntu/Debian arm64 desktop images work. This is the environment you run the installer from |
| A second machine with `adb` | For provisioning after first boot, and for everything afterwards |
| The proprietary firmware for **your** device | See [Firmware](#firmware) |

You should be comfortable recovering a machine that will not boot. Nothing here
is irreversible except the disk erase — but that one is.

## 1. Get the release

Download from [Releases](../../releases) and unpack into one directory:

| File | What it is |
|---|---|
| `super.img.zst` | system / system_ext / product / vendor |
| `boot.img` | Kernel, device tree and first-stage ramdisk in one standard Android boot image (header v2). Written to both `boot_a` and `boot_b`; the installer also unpacks it onto the ESP for systemd-boot |
| `recovery-ramdisk.img` | Android recovery. **No release ships this yet** — recovery is built but reset-loops on this machine, so it is deliberately not published. The installer accepts it if you build one yourself: it shares the kernel and DTB with the system, so only the ramdisk is needed, and it lands on the ESP for both slots. The boot menu entry is *not* created unless you set `ENABLE_RECOVERY_ENTRY=1` |
| `crDroidAndroid-*.zip` | The OTA package. **Not needed to install** — this is what the updater consumes later |

```sh
zstd -d super.img.zst          # the installer also accepts the .zst directly
sha256sum -c install-artifacts.sha256
```

## 2. Boot the live USB and run the installer

```sh
sudo apt install gdisk dosfstools android-sdk-libsparse-utils systemd-boot rsync zstd
sudo ./install-gaokun3.sh /path/to/release-dir
```

It prints the partition table it is about to destroy and waits for you to type
`ERASE`. Nothing is written before that.

The script is short and commented; read it rather than trusting this page. In
particular it explains **why** each partition exists, which is not obvious on a
machine with no fastboot, no A/B boot partitions and no recovery partition.

What you end up with:

| Partition | Size | Purpose |
|---|---|---|
| `esp` | 300 MiB | systemd-boot, plus the kernel/DTB/ramdisk it actually loads, one directory per slot |
| `misc` | 4 MiB | A/B slot state (`bootloader_control`) |
| `metadata` | 32 MiB | Android metadata |
| `super` | 12 GiB | The dynamic partitions, A/B |
| `boot_a`, `boot_b` | 64 MiB each | Android boot images, A/B. These are what OTA updates; the ESP copies are unpacked from them |
| `rescue` | 24 GiB | **A full Linux — this machine's recovery environment** |
| `userdata` | rest | `/data` |

### About that rescue partition

It is not optional padding. This machine has no recovery partition and no
serial console, so an ordinary Linux install *is* the recovery environment: a
system you can SSH into and repair from, with a full set of partitioning and
filesystem tools.

**How you get back into it: the 15-second boot menu.** Every boot stops at
systemd-boot's menu for 15 seconds; the rescue system is one entry there. If
Android hangs, hold the power button, and pick the rescue entry when the menu
comes up.

> ⚠️ Do **not** expect the machine to fall back to rescue on its own. The
> installer does write the rescue system as the default entry, but Android's
> `boot_control` HAL rewrites `default` to the currently running slot on every
> boot — by design, so that A/B slot switches survive. So after the first
> successful Android boot, the default entry *is* Android. Recovering from a
> hang means somebody picks the rescue entry from the menu. Earlier versions of
> this document promised an automatic fallback; that promise was never true
> after first boot, and it has been withdrawn rather than papered over.

To boot Android: choose it from the 15-second menu, or from the rescue system

```sh
sudo bootctl set-oneshot <machine-id>-android-a.conf && sudo reboot
```

## 3. Firmware

The proprietary Huawei firmware (`.mbn`, `.jsn`, the audioreach topology) is
**not** in this repository. Without it: no GPU (the zap shader is one of these
blobs), no Wi-Fi, no Bluetooth, no sound card.

The release images already contain it, so a fresh install needs nothing extra.
If you are *building* from source, see
[`device/huawei/gaokun3/firmware/README.md`](../device/huawei/gaokun3/firmware/README.md)
— the shortest path is to pull it from your own machine's Windows driver store
or from a mainline Linux install on the same hardware.

## 4. First boot

Two to three minutes, and then you are done — there is no provisioning script
to run. Screen-off timeout, captive-portal probe endpoints reachable from
China, adb over TCP and the large-screen letterboxing behaviour are all baked
into the image.

**One manual step remains: connect Wi-Fi once by hand.** If the framework ever
decides a network has no internet it marks it permanently disabled, and only a
*user-initiated* connection with a password clears that flag. Nothing shipped
in an image can do that for you.

### "This device isn't Play Protect certified"

Google keeps a list of device build identities it has certified, and a ROM
built outside that programme is not on it. The Play Store will say so, and
some apps will refuse to install until you fix it. The fix is free, takes a
minute, and you only do it once.

1. Sign in to your Google account on the tablet.
2. Read the device's Android ID:

   ```
   bash scripts/google/gsf-android-id.sh
   ```

   (It needs adb root. The ID lives in Google Play services' private storage —
   the widely-quoted `sqlite3 .../gsf/databases/gservices.db` recipe no longer
   works on current Play services, which is why this script exists.)
3. Open <https://www.google.com/android/uncertified/> **signed in as the same
   Google account**, paste the ID, and register it.
4. Give it a few minutes, then clear the Play Store's data:
   `adb shell pm clear com.android.vending`.

Re-register after a factory reset or after clearing Play services data — the
ID changes.

> **What this does not fix.** Play Integrity — the stronger attestation that
> banking and some payment apps use — will still fail, and no amount of
> configuration on our side changes that: it wants a locked bootloader running
> a Google-signed build. This machine boots an unlocked UEFI chain by design,
> because that is what makes installing another OS possible at all. If an app
> hard-requires Play Integrity, it will not work here.

## 5. Updating

Android 16 A/B (Virtual A/B) is wired up, so updates install into the inactive
slot while you keep using the machine, and take effect on the next reboot.

Because the kernel lives on the ESP rather than in a boot partition, the
`boot_control` HAL in this port also mirrors the active slot into
systemd-boot's `loader.conf` — see
[`device/huawei/gaokun3/boot_control/`](../device/huawei/gaokun3/boot_control/)
for how, and why the stock HAL cannot work here.

**Kernel updates arrive over OTA too**, as of 2026-08-20. `boot_a`/`boot_b` are
real Android boot partitions and `boot` is in `AB_OTA_PARTITIONS`, so a kernel
change ships as an ordinary update.

There is one extra step under the hood, because systemd-boot cannot read an
Android boot image: after `update_engine` has written the inactive slot, a
postinstall hook unpacks that slot's boot image and drops the kernel, DTB and
ramdisk into a per-slot directory on the ESP. The boot partitions are the
source of truth; the ESP copies are derived. Since the hook only ever writes
into the slot it just flashed, an update cannot touch the kernel you are
currently running — which is what makes rollback safe.

> **Partitioned by hand (dual boot)?** The hook and the boot-control HAL look
> for the ESP through `/dev/block/by-name/esp`, which only exists when the GPT
> partition *name* (PARTLABEL, not the vfat volume label) is exactly `esp`. A
> v0.6.0 user hit this: every OTA failed with `/dev/block/by-name/esp 不存在`.
> Fix once from any Linux: `sgdisk -c <N>:esp /dev/nvme0n1` (N = your ESP's
> partition number). From v0.6.1 on both components also fall back to finding
> the ESP by content (the vfat partition holding `loader/entries/*-android-*.conf`).

If the hook fails (the usual reason is a full ESP), the whole update fails
loudly rather than leaving you with a new system and an old kernel.

## Recovery — built, but it does not boot yet

There is **no working recovery on this device.** The image is built and shipped
(the ramdisk lands on the ESP), but booting it reset-loops the machine, so the
boot menu entry is **deliberately not created**. See
[#39](stage4-findings.md) for what was measured and ruled out.

What that costs you today:

* No `adb sideload`. Not a big loss — updates come through Settings, and the
  rescue Linux can write any partition directly.
* No `fastbootd`.
* ⚠️ **Erase all data in Settings probably does nothing.** That path writes
  `boot-recovery` into the bootloader control block in `misc` and reboots,
  expecting the bootloader to hand control to recovery. systemd-boot does not
  read that block, so the request lands nowhere — and indeed `misc` on a running
  device still has a stale `boot-recovery` sitting in it. To wipe `/data`, do it
  from the rescue Linux: `mkfs.ext4 -F /dev/disk/by-partlabel/userdata`.

If you want to debug it, `ENABLE_RECOVERY_ENTRY=1` makes the installer create
the entry, and `persist.vendor.gaokun3.recovery_entry=1` makes the OTA hook create it
(renamed from `persist.gaokun3.*` on 2026-09-18 — the old name is unwritable once
SELinux goes enforcing, see `docs/stage4-findings.md` #117).
⚠️ Be at the machine when you do: recovering from the loop needs the power
button.

## If it will not boot

| Symptom | Cause |
|---|---|
| Reboots a few seconds in, nothing in any log | First-stage mount failed. `/sys/fs/pstore` will be **empty** — Android init calls `reboot()` rather than panicking, so pstore never sees it. Add `androidboot.init_fatal_panic=true` to the entry to turn that into a real panic that efi_pstore does capture |
| Black screen, no menu | Secure Boot is still on, or the ESP was not written |
| Boots but no GPU / no Wi-Fi / no sound | Firmware missing from `/vendor/firmware/` |
| adb disappears after unplugging USB | Known ([#27](stage4-findings.md)). adb over TCP on port 5555 is enabled by default (`persist.adb.tcp.port`) — `adb connect <ip>:5555`. Disable with `setprop persist.adb.tcp.port -1` if you would rather not have the listener |

The rescue system is reachable over SSH on the LAN and can reflash everything.
That is what it is for.

## Reporting problems

Open an issue with your **BIOS version**, **SKU**, what you did and what
happened. `dmesg` and `logcat -b all` from the rescue system or over adb are
worth more than a description. Reports of what breaks are as useful as patches.
