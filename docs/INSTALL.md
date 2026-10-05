# Installing

There are two ways in, and both end up running the same installer backend:

* **The graphical installer — preview** (first released with v0.7.0-alpha).
  Touch-friendly, can install **next to Windows**, and can start from Windows
  **without a USB stick**. This is the way to install.
* **The command-line installer** ([Advanced](#advanced-the-command-line-installer)).
  Erases the whole disk. Same backend, a text front end — for people who would
  rather type.

**Read [what has been tested on real hardware](#what-has-been-tested-on-real-hardware)
before you start.** There is one test machine, and it is the developer's own,
so most of the paths a new user takes have so far only run against test disks.

> ### ⚠️ Erasing the disk erases Windows too.
> There is no undo, and no image of the factory state exists anywhere. If you
> want Windows back you will have to reinstall it yourself from Huawei's
> recovery media. Read all of this before starting.

## What has been tested on real hardware

| Path | On real hardware? |
|---|---|
| Graphical installer, **Reinstall Android** + *Keep user data*, started from a copy of the installer on the internal disk | ✅ 2026-09-26 (payload on the medium) and 2026-09-27 (downloaded over Wi-Fi, from a local mirror) |
| Graphical installer, **Reinstall Android** wiping data (the default of that mode) | ⬜ test disks only |
| Graphical installer, **Erase the whole disk** | ⬜ test disks only |
| Graphical installer, **Keep the current system** (dual boot) | ⬜ test disks only |
| Graphical installer, **Adjust the disk** | ⬜ test disks only |
| **Booting the installer from a USB stick** | ⬜ never — the same system has booted many times from the internal disk |
| **Windows script** (start the installer without a USB stick) | ⬜ only in a Windows 11 ARM virtual machine |
| **Command-line installer** (= *Erase the whole disk*) | ⬜ test disks only since 2026-09-24, when it was rebuilt on the graphical installer's backend. The script it replaced is what the developer's machine was originally installed with |

"Test disks" means loop devices in a container, with every write checked
(`scripts/live/test-apply.sh`). That catches a lot — it caught dual boot never
working at all — but it is not a real NVMe disk behind real firmware.

## Before you begin

| Requirement | Why |
|---|---|
| **Huawei MateBook E Go, GK-W7X** | The only model this has been built and tested on |
| Any BIOS version | Earlier versions of this page required 2.16 and refused 2.17. That restriction has been lifted (2026-09-25): it has been verified not to depend on the BIOS version. The installer still reports the version it sees, because a bug report needs it |
| **Secure Boot disabled** | The kernel is unsigned. Both installers check this and stop if it is on. From Windows 11 the firmware settings are under Settings → System → Recovery → *Advanced startup* → Troubleshoot → Advanced options → *UEFI Firmware Settings*. ⬜ Which key opens the firmware setup and its boot menu at power-on on this model has not been written down from a measurement yet |
| **A USB stick of 1 GB or more** — or **Windows** still on the machine | The installer runs from the stick, or from a small partition the Windows script creates |
| **Wi-Fi** | The installer downloads the system (about 1.3 GB) unless the medium already carries it. Over the Windows route you can carry it with you: see [offline install](#from-windows-no-usb-stick) |
| The keyboard cover | Only for the command-line installer and the terminal. The graphical installer works by touch and has an on-screen keyboard |

Nothing else: no second computer, no `adb`, no checkout of this repository, no
firmware of your own (the release images already contain it — see
[Firmware](#firmware)).

You should be comfortable recovering a machine that will not boot. Nothing here
is irreversible except erasing a disk — but that one is.

### Your data is not encrypted

`/data` is a plain ext4 file system: there is no file-based encryption
(`ro.crypto.state` is `unsupported`), and that is the decision for 1.0 too.
Secure Boot is off and the boot menu carries the installer / rescue system,
whose console logs in as `root` without a password. Anyone who has the tablet
in their hands can read everything on it; the lock-screen PIN only stops
someone using the screen. Turning encryption on later would mean erasing
`/data`.

## Downloads

| What | Where |
|---|---|
| **Graphical installer** `gaokun3-installer-<version>-…` (plus `rescue.squashfs`, `initramfs.img` for the command line, from its next release on) | GitHub: the release page it was published with — so far only **[v0.7.0-alpha](https://github.com/vahiru/gaokun-android/releases/tag/v0.7.0-alpha)**; later releases have not re-attached it. Mirror: `https://ota.072172.xyz/installer/<version>/<file>` — ⬜ nothing uploaded there yet; the next installer release goes to both |
| **System images** `boot.img`, `super.img.zst`, `install-artifacts.sha256` (command line only; the graphical installer downloads these itself) | GitHub: [latest release](https://github.com/vahiru/gaokun-android/releases/latest). Mirror, usually reachable where GitHub's download servers are not (mainland China): `https://ota.072172.xyz/install/<build>/<file>` |

`<build>` is the name of that release's OTA package without `.zip`. For
v0.7.1-alpha:

```
https://ota.072172.xyz/install/crDroidAndroid-16.0-20261003-gaokun3-v12.11/boot.img
https://ota.072172.xyz/install/crDroidAndroid-16.0-20261003-gaokun3-v12.11/super.img.zst
https://ota.072172.xyz/install/crDroidAndroid-16.0-20261003-gaokun3-v12.11/install-artifacts.sha256
```

The current build name is the `filename` field of
<https://ota.072172.xyz/ota/gaokun3.json> (the same file the updater reads).

## Graphical installer (preview)

Files (see [Downloads](#downloads)): `gaokun3-installer-<version>-usb.img.xz`
(a bootable USB image) and `gaokun3-installer-<version>-windows.zip` (start
from Windows, no USB stick). `gaokun3-installer-<version>-SHA256SUMS` lists
both, plus the decompressed USB image. The installer's version is shown at the
bottom of its side bar and in `gaokun3/release.txt` on the medium — put it in
bug reports.

What it can do:

| On the install-mode page | What happens | Tested on hardware |
|---|---|---|
| **Keep the current system** (dual boot) | Android goes into free space; nothing that exists is touched. Windows stays in the boot menu | ⬜ not yet (only on test disks) |
| **Erase the whole disk** | Everything on the disk is replaced by the layout in [Advanced](#what-you-end-up-with) | ⬜ not yet (only on test disks) |
| **Reinstall Android** (Android already on the disk) | Rewrites Android in its existing partitions; wipes data by default, or keeps it (*Keep user data*) | ✅ keeping data, same version, from the medium and over the network. ⬜ wiping data |
| **Adjust the disk** | Delete / shrink / grow / create / format partitions, one confirmed step at a time | ⬜ not yet (only on test disks) |

The system image comes from the medium if it carries one, or is downloaded
over Wi-Fi from the mirror above (the latest release, about 1.3 GB). If the
medium carries the image, a small rescue system (the installer itself) goes
into its own 1 GiB partition, as a non-default boot entry — see
[About the rescue system](#about-the-rescue-system).

**Before you start, in Windows:** turn off *Fast Startup* (Control Panel →
Power Options → *Choose what the power buttons do*) and shut down with *Shut
down*, not *Hibernate*. A hibernated Windows volume must not be resized — the
installer checks for this and refuses — and Windows cannot mount it safely
afterwards either.

**BitLocker / device encryption, in this order** (the Windows script below
walks you through it the same way): first make sure you have the recovery key
(<https://aka.ms/myrecoverykey>); then suspend BitLocker on the system drive
for two restarts — the script asks and runs
`Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 2` (normally C:) for you; only **then**
restart into the firmware setup and turn Secure Boot off. Turning Secure Boot
off, or the changed boot path afterwards, is what can make Windows ask for the
recovery key, so it must not come first. (The script also checks that the
machine booted in UEFI mode before it suspends anything.) ⬜ Whether two
restarts are enough on this tablet, and how BitLocker re-seals afterwards,
has not been checked on hardware.

### From Windows, no USB stick

1. Unzip `…-windows.zip`, double-click **`gaokun3-setup.cmd`** (it asks for
   administrator rights) and read what it prints. It checks the model, UEFI and
   Secure Boot, then asks you to type `YES` before touching the disk.
2. It lets Windows shrink **D:** by only what the installer itself needs
   (about 0.5–2 GB), creates a small FAT32 partition `GK3LIVE` with the
   installer, adds a boot entry, and sets the **next** boot only to go into the
   installer. The space for Android is chosen later, in the installer.
   Two exceptions it asks about: if Fast Startup is on it offers to turn it off
   (the installer refuses to shrink a partition Windows left hibernated), and
   if D: is encrypted with BitLocker / device encryption — which the installer
   cannot shrink — it offers to free the space for Android right now instead.
   Options: `-AndroidGiB 64` (free that much for Android now), `-ShrinkDrive C`,
   `-Wifi none`.
3. Reboot. In the installer choose **Shrink an existing partition to make
   room** (D:), then **Keep the current system**. (If the space for Android was
   already freed in Windows, go straight to the latter.)
   The next time Windows starts after the installer shrank D:, it runs a disk
   check first — that is expected: the resize tool asks for it on purpose.

**Offline install:** put `boot.img`, `super.img.zst` and
`install-artifacts.sha256` (from [Downloads](#downloads)) into a folder named
`payload` next to `gaokun3-setup.cmd` before step 1. The script copies them
onto `GK3LIVE`, and the installer then installs from them without Wi-Fi.

If you change your mind before installing, run `gaokun3-setup.cmd -Uninstall`:
it removes the partition and the boot entry, grows D: back and restores Fast
Startup if it turned it off. If the machine
boots straight back into Windows (the firmware ignored the one-time boot —
not yet verified on Huawei's firmware), run it again with
`-UseFallbackPath`.

⚠️ This script has been run end to end in a Windows 11 ARM virtual machine,
not yet on a MateBook E Go (and the "only its own space" default, the
encryption question and the Fast Startup step so far only in unit tests).

### From a USB stick

Write the image to a USB stick of 1 GB or more (balenaEtcher and Rufus read
`.xz` directly; on Linux:
`xz -dc gaokun3-installer-<version>-usb.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress`),
plug it in, and pick it from the firmware's boot menu. Secure Boot must be off.

⚠️ The USB image of this installer has not been booted on hardware yet; the
same system has, many times, from the internal disk. Which of the two USB-C
ports works for booting has not been checked either. (For USB debugging under
Android it is the port next to the power button; the other port is host-only.)

### If an install fails: the logs

The installer writes its log onto the medium it started from, in
`gaokun3/diag/` (`installer.log`). From Windows (the no-USB path) that is the
`GK3LIVE` drive. On the USB
stick it is harder: its only partition is an EFI system partition, which
Windows and macOS do not mount by themselves. Easiest is a second USB stick
formatted FAT32 or exFAT: plug it in and, in the installer's terminal
(Ctrl+Alt+F2, `root`, no password), run

```sh
bash -c '. /usr/share/gaokun3/installer-lib.sh && gk3_save_logs'
```

It copies the logs, `dmesg`, the boot journal, the disk layout and the
partition-table backups into a `gaokun3-logs-<time>` folder on that stick
(no Wi-Fi passwords). A *Save logs* button on the failure page is planned.
⬜ Not yet run on hardware.

## Advanced: the command-line installer

It erases the whole disk — the same thing as **Erase the whole disk** in the
graphical installer, through the same backend. Run it from the **terminal of
the installer USB stick**: everything it needs is already there.

### 1. Get the release

Three files from [Downloads](#downloads), into one directory:

| File | What it is |
|---|---|
| `super.img.zst` | system / system_ext / product / vendor |
| `boot.img` | Kernel, device tree and first-stage ramdisk in one standard Android boot image (header v2). Written to both `boot_a` and `boot_b`; the installer also unpacks it onto the ESP for systemd-boot |
| `install-artifacts.sha256` | Checksums. The installer checks both images against it **before** touching the disk, so a download that stopped halfway is refused instead of leaving a half-written disk behind |

Do not decompress anything: keep `super.img.zst` compressed — the installer
streams it straight onto the disk, so there is no 12 GiB intermediate file.
The `crDroidAndroid-*.zip` on the release page is the OTA package; it is not
needed to install.

### 2. Run it from the installer stick's terminal

1. Boot the [installer USB stick](#from-a-usb-stick). If you need Wi-Fi for the
   download, connect on the installer's *Connect to Wi-Fi* page first.
2. Switch to the terminal: **Quit to terminal** on the installer's first page,
   or Ctrl+Alt+F2 (Ctrl+Alt+F1 goes back). Log in as `root` — there is no
   password.
3. Fetch the release into RAM (the live system's writable layer is RAM; the
   1.3 GB fit) and run the installer:

   ```sh
   mkdir -p /tmp/rel && cd /tmp/rel
   B=crDroidAndroid-16.0-20261003-gaokun3-v12.11      # the build you want, see Downloads
   for f in boot.img super.img.zst install-artifacts.sha256; do
       curl -fLO "https://ota.072172.xyz/install/$B/$f" || echo "FAILED: $f"
   done
   /usr/share/gaokun3/install-gaokun3.sh /tmp/rel
   ```

   (The GitHub release URLs work the same way if you can reach them.)

⬜ This exact sequence — the stick's terminal, a download into RAM, a whole-disk
install — has not been run on real hardware yet (see
[the table above](#what-has-been-tested-on-real-hardware)).

It checks the machine (model, Secure Boot, tools; the BIOS version is reported,
not checked), prints the partition table it is about to destroy and the layout
it will create, and waits for you to type `ERASE`. Nothing is written before
that. The target disk defaults to `/dev/nvme0n1`; set `DISK=` to install
elsewhere.

The script is short and commented; read it rather than trusting this page. In
particular it explains **why** each partition exists, which is not obvious on a
machine with no fastboot, no A/B boot partitions and no recovery partition.

*From any other Linux:* the installer also runs from a full checkout of this
repository (`sudo scripts/install-gaokun3.sh <release-dir>`; it sources its
backend from `scripts/live/`, so a lone copy of the one file will not run; it
needs `gdisk dosfstools e2fsprogs zstd python3 systemd-boot-efi`). But no
generic distribution image (Ubuntu, Debian, …) has been shown to boot on this
machine — this is a device-tree-only Snapdragon, not an ACPI PC — so you are on
your own getting there. You also get no rescue system that way, unless you put
`rescue.squashfs` and `initramfs.img` into the release directory (see
[About the rescue system](#about-the-rescue-system) for where to get them).

### What you end up with

| Partition | Size | Purpose |
|---|---|---|
| `esp` | 300 MiB | systemd-boot, plus the kernel/DTB/ramdisk it actually loads, one directory per slot |
| `misc` | 4 MiB | A/B slot state (`bootloader_control`) |
| `metadata` | 32 MiB | Android metadata |
| `super` | 12 GiB | The dynamic partitions, A/B |
| `boot_a`, `boot_b` | 64 MiB each | Android boot images, A/B. These are what OTA updates; the ESP copies are unpacked from them |
| `gk3rescue` | 1 GiB | *Optional* rescue system — see below |
| `userdata` | rest | `/data` |

### About the rescue system

This machine has no working Android recovery and no serial console, so a
small Linux you can boot from the menu is how you repair it.

It is the installer itself — the same system as the USB stick, graphical
installer included, so it can also reinstall Android. It sits as a compressed
image (squashfs) on its own 1 GiB partition and is mounted from there
read-only, sharing the kernel with Android; whatever you change while it runs
lives in RAM and is gone at the next boot. It goes in only when the installer
has the image: the installer USB stick carries it, and so does the `GK3LIVE`
partition the Windows package creates (the graphical installer offers it as
*Also install the rescue system*; ⬜ the Windows path has only been checked in
offline tests). For the command-line installer, put `rescue.squashfs` and
`initramfs.img` into the release directory — they are attached to the
release next to the graphical installer from its next release on (⬜ not
published yet), or take them from a USB stick image (`gaokun3/rescue.squashfs`,
`gaokun3/initramfs.img` on its FAT partition).

**Logging in over the network** needs your SSH public key — the published
image carries nobody's. Put it on the installer stick as
`gaokun3/authorized_keys` (or in the release directory as `authorized_keys`)
before installing; the installer copies it into the rescue partition, along
with the Wi-Fi network you connected to. Without a key, the rescue system is
only usable at the machine itself.

> ⚠️ Changed on 2026-09-24. The installer used to create a 24 GiB `rescue`
> partition and copy whatever live system you had booted into it. That is gone:
> the installer and the graphical installer now share one implementation, and
> the rescue system is the small image above. If you installed with the old
> script, nothing changes on your machine.

**How you get into it: the 15-second boot menu.** Every boot stops at
systemd-boot's menu for 15 seconds; the rescue system is one entry there. If
Android hangs, hold the power button, and pick the rescue entry when the menu
comes up. It is never the default entry.

> ⚠️ Do **not** expect the machine to fall back to rescue on its own. Android's
> `boot_control` HAL rewrites `default` to the currently running slot on every
> boot — by design, so that A/B slot switches survive. Recovering from a hang
> means somebody picks the rescue entry from the menu. Earlier versions of this
> document promised an automatic fallback; that promise was never true after
> first boot, and it has been withdrawn rather than papered over. (The old
> script also made rescue the default entry at install time; that only ever
> lasted until the first Android boot, so the installer now simply defaults
> to Android.)

To get back to Android from the rescue system, a plain `reboot` is enough: the
rescue entry is never the default, so the menu falls through to Android after
15 seconds. To skip the menu, or to start a particular slot, use the helper
that comes with the rescue system:

```sh
gk3-boot-android b --reboot    # next boot only: slot b's entry, then reboot now
gk3-boot-android a             # same for slot a, without rebooting
gk3-boot-android --list        # what is on the ESP, and what is set
gk3-boot-android --clear       # undo
```

It finds the ESP itself, picks the entry `<machine-ID>-android-<slot>.conf`
(the machine-ID in that name is the installed system's, not the rescue
system's own, which is generated anew on every boot) and sets it as
systemd-boot's one-time entry (`LoaderEntryOneShot`); after that one boot the
menu's default applies again. It refuses if the slot has no such entry, has
more than one, or the kernel that entry points to is missing from the ESP.
The image has no `bootctl`, so the `bootctl set-oneshot` recipe found
elsewhere does not apply here.

⬜ Not yet tried in the rescue system on the tablet (only in offline tests):
in particular whether writing EFI variables works there — it does from
Android, with the same kernel.

There are **two** rescue entries, one using slot a's kernel and one using
slot b's: if an update leaves one slot's kernel unbootable, the other entry
still starts the rescue system. Both use the same rescue image; the second
one takes no extra space on the ESP. Machines installed before this change
get the second entry with their next update to slot b.

## Firmware

The proprietary Huawei firmware (`.mbn`, `.jsn`, the audioreach topology) is
**not** in this repository. Without it: no GPU (the zap shader is one of these
blobs), no Wi-Fi, no Bluetooth, no sound card.

The release images already contain it, so a fresh install needs nothing extra.
If you are *building* from source, see
[`device/huawei/gaokun3/firmware/README.md`](../device/huawei/gaokun3/firmware/README.md)
— the shortest path is to pull it from your own machine's Windows driver store
or from a mainline Linux install on the same hardware.

## First boot

Two to three minutes, and then you are done — there is no provisioning script
to run. Screen-off timeout, captive-portal probe endpoints reachable from
China and the large-screen letterboxing behaviour are all baked into the image.

**One manual step remains: connect Wi-Fi once by hand.** If the framework ever
decides a network has no internet it marks it permanently disabled, and only a
*user-initiated* connection with a password clears that flag. Nothing shipped
in an image can do that for you.

### adb

Not needed to install or use the tablet. If you want it: enable *Developer
options* (tap *Build number* in Settings → About tablet seven times), then
*USB debugging* or *Wireless debugging*. Both work the standard Android way:
the tablet asks you to authorize each computer.

In release builds after v0.7.1-alpha, *USB debugging* switches itself back off
at every reboot, so turn it on again after each restart. That is a known
limitation of this port, not a setting that failed to save: the part of
Android that normally remembers it (its USB device manager) does not run on
the mainline kernel. See [Known limitations](known-limitations.md).
⬜ Not yet confirmed on hardware.

> Releases up to v0.7.1-alpha were different: they listened for adb on TCP port
> 5555 on every network, **without asking for authorization**, so anyone on the
> same network could get a root shell. Release builds after v0.7.1-alpha no
> longer do. If you are still on one of those versions, update.

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

   It needs a checkout of this repository on the computer, [adb](#adb), and
   root, because the ID lives in Google Play services' private storage (the
   widely-quoted `sqlite3 .../gsf/databases/gservices.db` recipe no longer
   works on current Play services, which is why this script exists). How the
   script gets root:

   * **Development builds:** through `adb root`; the script does that itself.
   * **Release builds** (after v0.7.1-alpha) no longer allow `adb root`.
     Install the ReSukiSU manager app first and grant root to **Shell** in it;
     the script then falls back to `adb shell su -c …` on its own.
     ⬜ Not yet tried on a release build.

   A page in the tablet's own settings that shows this ID, so that no computer
   is needed, is planned ([`v1.0-plan.md`](v1.0-plan.md), INST-14).
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

## Updating

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
into the slot it just flashed, installing an update cannot touch the kernel you
are currently running.

> **There is no going back to the previous version after an update.** Under
> Virtual A/B the previous version's partitions only survive until the new
> version has booted successfully once; after that they are merged away. The
> boot menu still lists the other slot (`… — slot _b` or `_a`), but from then
> on that entry cannot boot: picking it costs one failed boot attempt, after
> which the machine restarts into the current version. (On a fresh install
> the `_b` entry has never had a system behind it at all.) Nothing falls back
> on its own either. If an update leaves something broken that you cannot live
> with, the way back is the graphical installer (the rescue entry in the boot
> menu, or the USB stick) → **Reinstall Android** with the version you want;
> keeping your data while going back to an older version may not boot.

> **Partitioned by hand (dual boot)?** The hook and the boot-control HAL look
> for the ESP through `/dev/block/by-name/esp`, which only exists when the GPT
> partition *name* (PARTLABEL, not the vfat volume label) is exactly `esp`. A
> v0.6.0 user hit this: every OTA failed with `/dev/block/by-name/esp 不存在`.
> Fix once from any Linux: `sgdisk -c <N>:esp /dev/nvme0n1` (N = your ESP's
> partition number). From v0.6.1 on both components also fall back to finding
> the ESP by content (the vfat partition holding `loader/entries/*-android-*.conf`).

If the hook fails (the usual reason is a full ESP), the whole update fails
loudly rather than leaving you with a new system and an old kernel.

## Erasing your data (factory reset)

⚠️ **Settings → System → Reset options → *Erase all data* currently does
nothing.** That path writes `boot-recovery` into the bootloader control block
in `misc` and reboots, expecting the bootloader to hand control to recovery.
systemd-boot does not read that block and there is no working recovery here
(see below), so the request lands nowhere — your data is still there
afterwards. For 1.0 this is to be taken over by a fastboot for this machine
(being designed).

**To really erase `/data` today:** boot the graphical installer (the rescue
entry in the boot menu, or the USB stick) → **Reinstall Android**, leaving
*Keep user data* off — wiping is that mode's default. ⬜ The wiping variant has
so far only run on test disks, not on real hardware. Step by step, including
before you sell the machine or send it for repair: see the
[FAQ](FAQ.md#factory-reset--wiping-before-you-sell).

## Recovery — built, but it does not boot yet

There is **no working recovery on this device.** The image is built, but
booting it reset-loops the machine, so no release ships it and the boot menu
entry is **deliberately not created**. See [#39](stage4-findings.md) for what
was measured and ruled out.

What that costs you today:

* No `adb sideload`. Not a big loss — updates come through Settings, and the
  rescue system can write any partition directly.
* No `fastboot` / `fastbootd` yet (see above).
* No factory reset from Settings (see above).

If you want to debug it: a recovery ramdisk you built yourself
(`recovery-ramdisk.img` in the release directory) is accepted by the
command-line installer. It shares the kernel and DTB with the system, so only
the ramdisk is needed, and it lands on the ESP for both slots.
`ENABLE_RECOVERY_ENTRY=1` makes the installer create the boot menu entry, and
`persist.vendor.gaokun3.recovery_entry=1` makes the OTA hook create it
(renamed from `persist.gaokun3.*` on 2026-09-18 — the old name is unwritable once
SELinux goes enforcing, see `docs/stage4-findings.md` #117).
⚠️ Be at the machine when you do: recovering from the loop needs the power
button.

## If it will not boot

| Symptom | Cause |
|---|---|
| Reboots a few seconds in, nothing in any log | First-stage mount failed. `/sys/fs/pstore` will be **empty** — Android init calls `reboot()` rather than panicking, so pstore never sees it. Add `androidboot.init_fatal_panic=true` to the entry to turn that into a real panic that efi_pstore does capture |
| Picked the other slot's entry, it restarted | Expected after an update — see [Updating](#updating) |
| Black screen, no menu | Secure Boot is still on, or the ESP was not written |
| Boots but no GPU / no Wi-Fi / no sound | Firmware missing from `/vendor/firmware/` |
| adb disappears after unplugging USB | Known ([#27](stage4-findings.md)). Use *Wireless debugging* in Developer options instead (see [adb](#adb)) |

The rescue system can reflash everything — at the machine, or over SSH on the
LAN if you gave it your key (see [About the rescue system](#about-the-rescue-system)).
That is what it is for.

## Reporting problems

Open an issue with your **BIOS version**, **SKU**, the installer version if you
used it, what you did and what happened. Logs are worth more than a
description: if Android boots, the first choice is

```sh
adb bugreport gaokun3-bugreport.zip
```

which collects the system log, the kernel log and the crash records in one go.
It also contains personal data — Wi-Fi network names, account names, the list
of installed apps — so read it before you attach it publicly. If Android does
not boot, take the logs from the rescue system. How to set up adb, how to get
individual logs, and what to collect when the machine does not boot are all in
the [FAQ](FAQ.md#collecting-logs-for-the-developers). Reports of what breaks are
as useful as patches.
