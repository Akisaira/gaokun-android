<!--
  Maintenance (not rendered):
  * Organised as "what happened → what to do". Every answer needs a source (script / case file / on-device check);
    the sources are in the comments of FAQ.zh-CN.md and apply to both files. Anything without a source says
    "to be added" instead of being written from memory, firmware keys and Windows menu paths especially.
  * Keep this file and FAQ.zh-CN.md in sync.
  * Everything said about "from 1.0" depends on D1 (release builds without insecure adb, ro.debuggable=0). Check that it
    actually landed before the release that ships it.
-->
# Frequently asked questions

[**中文 → FAQ.zh-CN.md**](FAQ.zh-CN.md) · [Known limitations](known-limitations.md) · [Installing](INSTALL.md)

* [Booting and the boot menu](#booting-and-the-boot-menu)
* [Updates and rolling back](#updates-and-rolling-back)
* [Collecting logs for the developers](#collecting-logs-for-the-developers)
* [Rescue system and SSH](#rescue-system-and-ssh)
* [Factory reset / wiping before you sell](#factory-reset--wiping-before-you-sell)
* [Removing Android, going back to Windows](#removing-android-going-back-to-windows)
* [Developer options, USB debugging and wireless debugging](#developer-options-usb-debugging-and-wireless-debugging)

---

## Booting and the boot menu

### How do I get into the UEFI firmware setup, turn off Secure Boot, or boot from USB?
<!-- INST-4 / REL-9: no record of the keys anywhere in the repository. To be filled in after the user tries it on the
     machine: firmware setup key, boot menu key, how to do it without the keyboard cover, where the Secure Boot option is. -->
**The keys are still to be added: we want to check them on the machine rather than guess.** If you know them, please
tell us in the group or in an issue.

What we can say for sure:

* **Secure Boot has to be off**, because the kernel is unsigned. The installer checks this before it starts and refuses
  to continue if it is on; the USB-free Windows setup script checks it first too.
* To boot from USB: plug in the installer USB stick and pick it in the firmware's boot menu.

### What are the entries in the boot menu?
Every boot stops at the systemd-boot menu for 15 seconds, then starts the default entry.

| Entry | What it is |
|---|---|
| `crDroid 16.0 (gaokun3) — slot _a`<br>`crDroid 16.0 (gaokun3) — slot _b` | Android's two slots. **The entry highlighted by default is the one you are running.** Whether the other one still works: see [rolling back](#something-broke-after-an-update-can-i-go-back) |
| `gaokun3 rescue (runs from RAM)` | The rescue system. Only present if you installed with the graphical installer and kept the rescue system option. It is the graphical installer itself, running in RAM: it can reinstall Android, and you can SSH into it |
| `Windows Boot Manager` | Only on dual boot; the menu finds it automatically |
| `gaokun3 installer` | Left behind when the installer was started from Windows without a USB stick |

### How do I use the menu? Does it work without the keyboard cover?
With the keyboard cover attached: arrow keys to choose, Enter to boot.

**Whether the volume and power buttons can drive this menu without the keyboard cover has not been checked yet (to be
added).** Attach the keyboard cover when you need to pick an entry.

---

## Updates and rolling back

### Something broke after an update. Can I go back?
**In most cases, no.** System updates use Android's "Virtual A/B": once the new version has booted successfully, it is
merged in the background into the only copy of the system, and the previous version is gone. The other slot is still
listed in the menu after that, but picking it only costs you one failed boot before the machine returns to the default
entry.

There is one case where you can go back: **the new version does not boot at all** (it keeps restarting, say), so it never
got merged. Then:

1. Hold the power button to switch off, then switch on.
2. In the menu pick the **other** slot (not the highlighted one).
3. On later boots the default may still point at the broken slot (not verified). If so, pick the slot by hand on every
   boot until the next update.

On a fresh install with no update yet, only the current slot holds a system; the other one is empty.

If the new version boots but something in it is broken, you cannot go back. Wait for a fix, or reinstall the older version
with the graphical installer (next question).

### Can I install an older version (downgrade)?
The graphical installer's **Reinstall Android** installs any version. But **keeping your data across a downgrade is not
guaranteed to work**: the newer version may have converted your data into a format the older one does not understand.
When downgrading, let it wipe the data (the default; leave *Keep user data* unticked) and back up first.

### It keeps restarting or hangs at boot. What now?
1. Try the other slot from the menu, as above.
2. If that does not help, pick `gaokun3 rescue (runs from RAM)` or boot the installer USB stick, then use
   **Reinstall Android**. Ticking *Keep user data* keeps your data (a same-version reinstall has been verified on
   hardware).
3. The rescue system can collect logs: see [when the machine won't boot Android](#collecting-logs-when-the-machine-wont-boot-android).

---

## Collecting logs for the developers

When you report a problem, include the model (GK-W7X), your BIOS version, the ROM version (see below), what you did and
what happened, plus the logs below. Report on [GitHub issues](https://github.com/vahiru/gaokun-android/issues), or in
[Telegram](https://t.me/gaokunAndroid) / QQ group **920133252**.

### Setting up adb
1. Install Google's **SDK Platform-Tools** on your computer (`adb` is in there).
2. On the tablet, turn on **Developer options** and **USB debugging**: see [below](#developer-options-usb-debugging-and-wireless-debugging).
3. Connect a USB cable and **keep the screen on** (USB debugging disconnects while the screen is off). Run
   `adb devices` on the computer. If the tablet is not listed, try the other USB-C port: only one port works for
   debugging (which one is still to be added).
4. To go without a cable, use [wireless debugging](#wireless-debugging).

### With a computer, when the machine boots
The quickest and most complete option:

```sh
adb bugreport gaokun3-bugreport.zip
```

It contains the system log, the kernel log, crash records and more — including the crash dumps under
`/data/tombstones`, which you cannot read without root otherwise.

⚠️ **A bug report contains personal data**: Wi-Fi network names, account names, the list of installed apps. Read it
before you attach it publicly.

If you only want parts of it:

```sh
adb logcat -b all -d > logcat.txt          # the whole system log (-d: dump and exit)
adb logcat -b crash -d > crash.txt         # crash records only
adb shell dmesg > dmesg.txt                # kernel log; if it says permission denied, use the su line below
```

These need root (first grant it to **Shell** in the ReSukiSU manager):

```sh
adb shell su -c dmesg > dmesg.txt
# what the kernel saved during the last crash or spontaneous reboot (efi_pstore); empty is normal, many failures never go through the kernel
adb exec-out "su -c 'tar -C /sys/fs -cf - pstore'" > pstore.tar
# evidence collected automatically when audio / Bluetooth deadlocks
adb exec-out "su -c 'cd /data/vendor/gaokun3 && tar -cf - hangdump-*'" > hangdump.tar
```

**After a crash or an unexpected reboot, grab `pstore` first, before doing anything else.**

ROM version:

```sh
adb shell getprop ro.build.version.incremental    # e.g. 20261003184648
adb shell getprop ro.build.date.utc               # the build stamp, e.g. 1791053208
```

### Without a computer
Whether *Take bug report* in Developer options works on this machine has not been checked yet (to be added). For now,
please use a computer as above.

### Collecting logs when the machine won't boot Android
Pick `gaokun3 rescue (runs from RAM)` in the menu (or boot the installer USB stick).

* 45 seconds after it boots, it writes diagnostics to `/media/gk3/gaokun3/diag/`. That directory is on disk and survives
  a reboot.
* Kernel log: `journalctl -k`.
* Crash records: look in `/sys/fs/pstore/` and `/var/lib/systemd/pstore/`. **Copy them to `/media/gk3/gaokun3/diag/`
  before you reboot**: the second one lives in RAM and is lost on reboot.
* To fetch it all over SSH: `scp -r root@<IP>:/media/gk3/gaokun3/diag .` (SSH needs a key first; see the next section).
* Booted from the installer USB stick? Then `/media/gk3` is the stick itself: its FAT partition, volume label
  **`GK3LIVE`**. Plug the stick into any computer and the files are in `gaokun3/diag/`.

---

## Rescue system and SSH

### How do I SSH into the rescue system?
The rescue system **accepts SSH logins with a public key only**. The published image contains nobody's key, so you have
to add your own first; until then you can only use it at the machine.

**Before installing** (recommended):

1. Generate a key pair on your computer (skip if you have one): `ssh-keygen -t ed25519`.
2. Save the public key (the contents of `~/.ssh/id_ed25519.pub`) as `gaokun3/authorized_keys` on the installer USB
   stick. That partition of the stick is FAT, so Windows and Mac can write to it directly.
3. For the rescue system to join Wi-Fi when it boots: connect to Wi-Fi once in the installer, and the installer carries
   that configuration over. Or put a `gaokun3/wpa_supplicant.conf` on the stick.
4. Keep the rescue system option when installing. The installer copies both files into the rescue partition.

**Already installed**:

1. Pick `gaokun3 rescue (runs from RAM)` in the boot menu; the installer screen comes up.
2. Choose *Quit to terminal* (or press Ctrl+Alt+F2) and log in as `root`. At the machine itself no password is needed.
3. Append your key and restart SSH:

   ```sh
   cat >> /media/gk3/gaokun3/authorized_keys     # paste the key, Enter, then Ctrl+D
   systemctl restart ssh
   ```

   The file is on the rescue partition, so it keeps working every time you boot the rescue system.

**Connecting**: run `ip addr` in the rescue system's terminal for its IP, then `ssh root@<IP>` from your computer. If your
network supports mDNS, `ssh root@gaokun3-live.local` may work as well (not yet tried on anyone else's network).

---

## Factory reset / wiping before you sell

**_Erase all data_ in Settings does nothing on this machine**: it reboots and all your data is still there. Why: see
[known limitations](known-limitations.md#erase-all-data-factory-reset-in-settings-does-nothing). A fastboot-based
factory reset is being designed.

For now, do this:

1. Pick `gaokun3 rescue (runs from RAM)` in the boot menu; if that entry is not there, boot the installer USB stick.
2. Choose **Reinstall Android**. **Do not** tick *Keep user data* (unticked is the default, which wipes the data).
3. The system image is read from the USB stick, or downloaded over Wi-Fi (about 1.3 GB) if the stick does not carry one.

⚠️ The data partition is not encrypted (see [known limitations](known-limitations.md)). Always wipe it before you sell
the machine or send it for repair.

---

## Removing Android, going back to Windows

### Dual boot: I just want to use Windows for a while
Pick `Windows Boot Manager` in the boot menu.

### Dual boot: removing Android completely
**A complete removal has not been carried out on real hardware yet, so we are not giving step-by-step commands (to be
added).** Please ask in the group before you start.

For reference, this is what the installer changed:

* **Booting**: `EFI/BOOT/BOOTAA64.EFI` on the ESP was replaced by systemd-boot; the original was kept as
  `EFI/BOOT/BOOTAA64.EFI.before-gaokun3`. Restore it and the machine boots straight into Windows.
* **Files on the ESP**: a directory named after a machine-id (with `android/` inside), plus the configuration and the boot
  entries under `loader/`.
* **Partitions**: `misc`, `metadata`, `super`, `boot_a`, `boot_b`, `userdata`, and possibly `gk3rescue`. After deleting
  them, give the space back to Windows from within Windows.
* `gaokun3-setup.cmd -Uninstall` on Windows, run **after** Android has been installed, only removes the installer's own
  boot entry and files. It does **not** remove Android.

### Installed with "Erase the whole disk", now I want Windows back
Windows was erased at that point; the only way back is a reinstall from Huawei's recovery media. We have not done that
on this machine (to be added). If you want to keep Windows, choose **Keep the current system** (dual boot) when
installing.

---

## Developer options, USB debugging and wireless debugging

The menu names below are the standard Android / crDroid ones; go by what your device shows.

### Turning on Developer options
1. **Settings → About tablet**, tap *Build number* 7 times, and enter your screen lock when asked.
2. From then on it is under **Settings → System → Developer options**.

### USB debugging
Turn on **USB debugging** in Developer options and connect the cable. From 1.0, the tablet asks "Allow USB debugging?":
check the computer's key fingerprint, tick *Always allow from this computer*, and allow. A computer that has not been
allowed cannot connect.

From 1.0, **USB debugging switches itself back off at every reboot**: turn it on again after each restart. This is a
known limitation of this port (see [known limitations](known-limitations.md)), not a setting that failed to save. Not
yet confirmed on hardware.

### Wireless debugging
1. Put the tablet and the computer on the same Wi-Fi.
2. Developer options → **Wireless debugging** → on → **Pair device with pairing code**, and note the IP, port and code.
3. On the computer run `adb pair <IP>:<pairing port>` and enter the code. Each computer only needs pairing once.
4. Then run `adb connect <IP>:<port>`. Use the port shown on the main *Wireless debugging* screen here, not the pairing
   port.

Turn wireless debugging off when you are not using it.

> **v0.7.1 and earlier**: the image opens network adb on port 5555 by default, **with no authorization**. Anyone on the
> same network can connect and get root. 1.0 closes this. If you are still on an older version, update soon and stay
> off Wi-Fi networks you don't trust.

### `adb root` does not work?
From 1.0, release builds no longer support `adb root`. For a root shell, first grant root to **Shell** in the ReSukiSU
manager, then use `adb shell su`.
