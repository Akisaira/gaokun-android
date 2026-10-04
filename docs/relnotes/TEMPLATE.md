<!--
  发版说明模板（照 v0.7.1-alpha.md 的结构抽出来的）。复制成 docs/relnotes/v<版本>.md 再填；这个文件本身不发。

  ── 头注释（发版后保留在新文件里，记状态）──────────────────────────────
  v<X.Y.Z>（用户 YYYY-MM-DD 定名）。<这一版收了哪些 issue / 案卷 #NN>。
  ⬜ 用户定稿 → ✅ 用户 YYYY-MM-DD 定稿。发的是候选版 <构建戳>（incremental <YYYYMMDDhhmmss>），release.sh --no-build。
  ⬜ 装机验收 → ✅ 装机验收：<docs/TODO.md 的哪一节 / 案卷>（槽 _a/_b，日期）
  ⬜ 发布 → ✅ YYYY-MM-DD hh:mm 发布：release.sh --no-build 传 R2、清单最后传（设备端抓取 200、timestamp = 戳）；
     GitHub release <N> 个附件服务端字节数逐一核对、标 Latest，tag v<X.Y.Z> = <提交>

  ── 填写规矩（填完把这一段删掉）────────────────────────────────────────
  * 写给用户看：先写"你会看到什么变了"，再写原因，数字放在原因后面。每一条修复都写清"在这台机器上测过什么、没测过什么"。
  * 感谢报告者：issue 链接 + @用户名。
  * "Known issues"只写【这一版】特有、或这一版有变化的问题。长期存在的限制和取舍不要在这里重新写一遍，
    改 docs/known-limitations.md（中英两份）。下面"Known limitations"那一节只留一行摘要，并链接过去。
  * 发版前把 docs/known-limitations.md 逐条对一遍：这一版修好的就删掉，取舍变了的就改写（SELinux、root 管理器是否预装、
    恢复出厂、MTP、U 盘……），然后照着改下面的摘要。
  * 降级：只要这一版改了 /data 里的东西（数据库升级、新的 persist 属性等），就在 Alpha 框里写一句"不保证能降级回去"。
  * Files 表：每个文件同时给 GitHub 和 R2 两个链接（国内打不开 GitHub）。R2 的路径规则见 scripts/release.sh:141、:166-169
    （OTA 包 = builds/<zip 名>；安装文件 = install/<zip 名去掉 .zip>/<文件名>）。
  * GPL 对应源码：REL-7 落地后，在 Source 一行填 kernel-source 清单的链接；落地之前删掉那一行，别留空链接。
  * 用户在中国的多：中文版另出一份（REL-4），结构相同。
-->
Android 16 (crDroid) for the **Huawei MateBook E Go** (Snapdragon 8cx Gen 3 /
SC8280XP) on a **mainline Linux kernel**, with hardware Vulkan on the Adreno 690.

<One paragraph: what kind of release this is, and the two or three changes a user will notice, in bold.>

**Talk to us:** [Telegram](https://t.me/gaokunAndroid) · QQ group **920133252**

> ### ⚠️ <Alpha / Beta — for 1.0, replace this heading and the first paragraph, keep the rest>
> A fresh install **erases the internal disk** (unless you use the graphical
> installer's dual-boot mode), and no image of the factory state exists anywhere.
> You should be comfortable recovering a machine that will not boot. No warranty.
>
> Any BIOS version works. Secure Boot must be off.
> Instructions: **[docs/INSTALL.md](https://github.com/vahiru/gaokun-android/blob/main/docs/INSTALL.md)** ·
> **Before installing, read [what does not work](https://github.com/vahiru/gaokun-android/blob/main/docs/known-limitations.md)** ·
> [FAQ](https://github.com/vahiru/gaokun-android/blob/main/docs/FAQ.md)
>
> Coming from **v<first> – v<previous>**: update in Settings, nothing else to do.
> <If this release changes data: "Going back to an older version afterwards is not supported with your data kept.">

## <Area, e.g. Standby / Wi-Fi / Audio / USB>

**<What the user sees now>** ([#NN](https://github.com/vahiru/gaokun-android/issues/NN),
thanks to **@reporter**). <Why it was broken, in plain words. What changed. What was measured on this build.>

<Repeat one section per area.>

## Smaller things

* **<Change>**: <one or two sentences>. (<What was / was not tested.>)

## Known issues

<Only problems specific to this release, or that changed in it. Long-standing ones live in known-limitations.md.>

* <Problem>. <Workaround, if any. What log to send: e.g. `adb logcat -b crash` right after it happens.>

## Known limitations

<!-- 一行一条，和 docs/known-limitations.md 逐条对应；那边删了这边也删。下面是 v0.7.1 / 1.0 计划时的状态。 -->
The full list, with workarounds, is in
**[docs/known-limitations.md](https://github.com/vahiru/gaokun-android/blob/main/docs/known-limitations.md)**
([中文](https://github.com/vahiru/gaokun-android/blob/main/docs/known-limitations.zh-CN.md)). In short:

* **Security**: signed with Android's public test keys; `/data` is **not encrypted**; root (KernelSU / ReSukiSU) is
  built in; SELinux is `permissive`; the boot chain is unlocked.
* **Proprietary components** ship in the images: Huawei firmware and sensor configuration, the Huawei Histen audio
  engine, and Google apps (MindTheGapps).
* **Not supported**: *Erase all data* in Settings (use the graphical installer's *Reinstall Android*); file transfer
  over USB (MTP); USB sticks; fingerprint (in progress); stylus; automatic brightness; GPS / location; DRM video
  (no Widevine); Bluetooth headset microphone in calls; push notifications while in standby; Google certification
  (register once; Play Integrity never passes).

## Files

The in-system updater will offer this build; nothing here is needed for a normal
update. For a **fresh install** you want `super.img.zst` and `boot.img`.

| File | Download | What |
|---|---|---|
| `crDroidAndroid-16.0-<YYYYMMDD>-gaokun3-v12.11.zip` (<size>) | GitHub · [R2](https://ota.072172.xyz/builds/crDroidAndroid-16.0-<YYYYMMDD>-gaokun3-v12.11.zip) | OTA package, also what the in-system updater downloads |
| `super.img.zst` (<size>) | GitHub · [R2](https://ota.072172.xyz/install/crDroidAndroid-16.0-<YYYYMMDD>-gaokun3-v12.11/super.img.zst) | system / system_ext / product / vendor, for a fresh install |
| `boot.img` (<size>) | GitHub · [R2](https://ota.072172.xyz/install/crDroidAndroid-16.0-<YYYYMMDD>-gaokun3-v12.11/boot.img) | kernel + device tree + first-stage ramdisk |
| `install-artifacts.sha256` | GitHub · [R2](https://ota.072172.xyz/install/crDroidAndroid-16.0-<YYYYMMDD>-gaokun3-v12.11/install-artifacts.sha256) | checksums of the three files above |
| `gaokun3.json` | GitHub | the updater manifest for this build |

Build stamp `<ro.build.date.utc>`, incremental `<YYYYMMDDhhmmss>`. The checks above were run
on a machine running exactly this build. Not run on it: <list what was not tested>.

Source: tag [`v<X.Y.Z>`](https://github.com/vahiru/gaokun-android/tree/v<X.Y.Z>) · kernel source manifest: <link, once REL-7 lands>

The graphical installer is <unchanged — use `<installer version>` from [v<…>](https://github.com/vahiru/gaokun-android/releases/tag/v<…>) / attached: `gaokun3-installer-<version>-…`>.
