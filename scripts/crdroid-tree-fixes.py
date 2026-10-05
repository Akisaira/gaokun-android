#!/usr/bin/env python3
"""对 crDroid 源码树的本地修补（幂等，可反复跑）。

在构建机上执行：
    python3 <repo>/scripts/crdroid-tree-fixes.py ~/crdroid

—— 修补 1：关掉 SPOOF_SAFETYNET ——

crDroid 在 system/core/init/property_service.cpp 里加了 SetSafetyNetProps()，
在【解析 kernel cmdline 之前】硬写一整张属性表来伪装"已锁定、已验证、user 版"，
好让 Play Integrity 通过。源码注释原话：

    // Report a valid verified boot chain to make Google SafetyNet integrity
    // checks pass. This needs to be done before parsing the kernel cmdline as
    // these properties are read-only and will be set to invalid values with
    // androidboot cmdline arguments.

被它强制的值（2026-08-19 实机 getprop 逐条确认）：
    ro.boot.verifiedbootstate = green      （cmdline 写的是 orange）
    ro.boot.flash.locked      = 1          （cmdline 写的是 0）
    ro.boot.veritymode        = enforcing  （cmdline 写的是 disabled）
    ro.debuggable = 0    ro.adb.secure = 1    ro.secure = 1
    ro.build.type = user   ro.build.tags = release-keys
    ro.crypto.state = encrypted            ro.secureboot.lockstate = locked

对本项目这是致命的：
  * ro.debuggable=0            → adb root / adb remount 全部不可用，
                                 而 M3 部署 turnip 完全依赖 overlayfs remount
  * verifiedbootstate != orange → adb remount 的前提不成立（Stage 5 的运维基础）
  * ro.adb.secure=1            → adb 要授权（可用 PRODUCT_ADB_KEYS 绕开，但治标）
  * 这些值把 WITH_ADB_INSECURE、PRODUCT_SYSTEM_EXT_PROPERTIES、cmdline
    统统盖掉 —— 排查时极具迷惑性，因为产物里的 build.prop 明明是对的。

上游只在 eng 变体里关它（Android.bp 的 product_variables.eng），
但 eng 会关掉 dexpreopt，首次开机全靠 JIT —— 本机跑 swangle 软渲染，
慢到不可接受。所以直接把默认值改成 0。

我们本来就不追求 Play Integrity（这是台开发机），关掉没有副作用。
"""
import io, re, sys, pathlib, shutil, subprocess, tempfile

def patch_spoof_safetynet(tree: pathlib.Path) -> str:
    p = tree / "system/core/init/Android.bp"
    if not p.exists():
        return f"跳过（找不到 {p}）"
    s = io.open(p, encoding="utf-8").read()
    n = s.count('"-DSPOOF_SAFETYNET=1"')
    if n == 0:
        return "已是 0（幂等，无需改动）" if '"-DSPOOF_SAFETYNET=0"' in s else "⚠️ 找不到 SPOOF_SAFETYNET，上游可能改了写法"
    s = s.replace('"-DSPOOF_SAFETYNET=1"', '"-DSPOOF_SAFETYNET=0"')
    io.open(p, "w", encoding="utf-8", newline="").write(s)
    return f"已把 {n} 处 -DSPOOF_SAFETYNET=1 改为 =0"

def patch_hexagonfs_cr(tree: pathlib.Path) -> str:
    """—— 修补 2：给 hexagonfs 的路径解析加 CR 截断 ——

    SLPI 的 DSP 固件是在 Windows 上编译的，它通过 FastRPC 请求文件时，
    路径的【每一段都带一个尾随 CR】。hexagonrpcd 上游没有处理这件事，
    于是 DSP 读不到传感器注册表 —— 症状是传感器一个都出不来。

    ★ 补丁位置很关键：打在 copy_segment_and_advance() 里，那是【通用】分段
      解析函数，清理后的 segment 才分派给各后端（hexagonfs.c 的 openat 循环）。
      所以物理目录后端同样受益 —— 这就是为什么【不需要】贡献者指南里那 6 个
      带 CR 的 socinfo symlink（本仓移走它们后加速度计照样正常，实测确认）。
      而这一条正是 Android 侧能用普通 PRODUCT_COPY_FILES 的前提：
      构建系统造不出带控制字符的文件名。

    完整背景见 docs/stage4-findings.md #37。
    """
    p = tree / "external/hexagonrpc/hexagonrpcd/hexagonfs.c"
    if not p.exists():
        return f"跳过（找不到 {p} —— local manifest 同步过了吗）"
    s = io.open(p, encoding="utf-8").read()
    if "segment[--segment_len] = 0;" in s:
        return "已打过（幂等，无需改动）"
    anchor = "segment[segment_len] = 0;"
    if anchor not in s:
        return "⚠️ 找不到锚点，上游可能改了 copy_segment_and_advance()"
    # ⚠️ 生成 C 代码时【一律用 chr()】，不写反斜杠转义：这段代码本身经过多层
    #    引号传递，\n / \r 之类会被中间层 collapse 掉（本仓踩过两次）。
    NL, TAB, BS = chr(10), chr(9), chr(92)
    patch = (NL + TAB + "/* DSP 固件在 Windows 上编译，请求的路径每段都带尾随 CR。" + NL
             + TAB + " * 这里是通用分段解析，清理后才分派给各后端，物理目录后端同样受益。 */" + NL
             + TAB + "if (segment_len > 0 && segment[segment_len - 1] == " + chr(39) + BS + "r" + chr(39) + ")" + NL
             + TAB + TAB + "segment[--segment_len] = 0;")
    s = s.replace(anchor, anchor + patch, 1)
    io.open(p, "w", encoding="utf-8", newline="").write(s)
    return "已加上 CR 截断"


def patch_v4l2_input_size(tree: pathlib.Path) -> str:
    """—— 修补 3：v4l2_codec2 给压缩输入队列传了非法分辨率 ——

    症状：任何视频用 c2.v4l2.*.decoder 都 "start 失败"，内核打
    `qcom-venus: HW can't support this load`。

    ★ 根因链（内核插桩实测，见 docs/stage4-findings.md）：
      1. V4L2Decoder::setupInputFormat() 对【压缩输入队列】做 S_FMT 时传
         `ui::Size()`，而 ui::Size 的默认值是 **-1 x -1**
         （frameworks/native/libs/ui/include/ui/Size.h:32-33），
         不是想当然的 0 x 0。
      2. buildV4L2Format() 把它赋给 __u32 -> 0xFFFFFFFF。
      3. venus 的 vdec_try_fmt_common() clamp 到 [128, 8192] -> **8192**，
         而 vdec_s_fmt() 就用这个值填 inst->width/height。
      4. 同一个函数末尾立刻 streamon -> decide_core() 按 8192x8192@30fps
         算出 1.573 GHz 负载 > max_freq 1.332 GHz -> -EINVAL。
      实测插桩输出：`8192x8192 fps=30 ... inst=1572864000 max_freq=1332000000`，
      而视频其实只有 640x360。

    ★ 这是 v4l2_codec2 的**可移植性 bug**：ChromeOS 的驱动不看压缩队列的
      分辨率，所以上游一直没暴露；venus 看，于是一撞就死。

    修法：传设备自报的最小分辨率 —— 与同文件 setupMinimalOutputFormat()
    对输出队列的做法完全一致。真实分辨率随后由 source-change 事件带来。
    """
    p = tree / "external/v4l2_codec2/v4l2/V4L2Decoder.cpp"
    if not p.exists():
        return f"跳过（找不到 {p}）"
    s = io.open(p, encoding="utf-8").read()
    if "inputMinRes" in s:
        return "已打过（幂等，无需改动）"
    anchor = ("    auto format = mInputQueue->setFormat(inputPixelFormat, ui::Size(), "
              "inputBufferSize, 0);")
    if anchor not in s:
        return "⚠️ 找不到锚点，上游可能改了 setupInputFormat()"
    NL = chr(10)
    new = (
        "    // venus 会拿【压缩输入队列】S_FMT 的分辨率去算硬件负载，而 ui::Size()" + NL
        + "    // 默认是 -1 x -1，转成 __u32 就是 0xFFFFFFFF，被 clamp 到 8192x8192，" + NL
        + "    // decide_core() 于是一律判 HW overload。传设备自报的最小分辨率。" + NL
        + "    ui::Size inputMinRes, inputMaxRes;" + NL
        + "    mDevice->getSupportedResolution(inputPixelFormat, &inputMinRes, &inputMaxRes);" + NL
        + "    if (inputMinRes.isEmpty()) inputMinRes.set(128, 128);" + NL
        + "    auto format = mInputQueue->setFormat(inputPixelFormat, inputMinRes, "
          "inputBufferSize, 0);"
    )
    s = s.replace(anchor, new, 1)
    io.open(p, "w", encoding="utf-8", newline="").write(s)
    return "已改为传最小分辨率（原来传的是 ui::Size() = -1 x -1）"


def patch_v4l2_device_scan_range(tree: pathlib.Path) -> str:
    """—— 修补 7：v4l2_codec2 只扫 /dev/video0..9，开了 camss 之后就找不到 Venus 了 ——

    症状：硬件视频编解码**静默消失**（组件名还在 MediaCodecList 里，因为那是
    media_codecs_c2.xml 驱动的，但底下一个设备都没匹配上），一切回落软解。

    ★ 根因：`V4L2Device::getDeviceInfosForType()` 里写死
        for (int i = 0; i < 10; ++i)        // v4l2/V4L2Device.cpp:2565
      只探 /dev/video0..video9。而 Stage 6 M22 把 camss 编进内核之后，
      **camss 一家就占了 32 个 video 节点**（msm_vfeN_videoM，实测 video0-31），
      Venus 被挤到 **video32 / video33**（实测 `cat /sys/class/video4linux/*/name`）。
      于是扫描范围内全是 camss 的 capture 节点，而解码器要的是
      V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE —— camss 不提供 ⇒ deviceInfos 为空。

    ⚠️★ 编号还**不是稳定的**：谁先 probe 谁拿低号。所以"把 Venus 钉在 video0/1"
      这种做法靠不住，正解就是把扫描范围放宽。

    修法：上界 10 -> 64。多出来的 open() 全部立即失败、只在首次调用时发生一次
    （结果有 sDeviceInfosCache 缓存），代价可以忽略。
    """
    p = tree / "external/v4l2_codec2/v4l2/V4L2Device.cpp"
    if not p.exists():
        return f"跳过（找不到 {p}）"
    s = io.open(p, encoding="utf-8").read()
    if "kMaxVideoDeviceIndex" in s:
        return "已打过（幂等，无需改动）"
    anchor = "    for (int i = 0; i < 10; ++i) {"
    if s.count(anchor) != 1:
        return "⚠️ 锚点不唯一或找不到，上游可能改了 getDeviceInfosForType()"
    NL = chr(10)
    new = (
        "    // 只扫 video0..9 在本机是不够的：camss 一家就占 32 个节点" + NL
        + "    // （实测 video0-31 = msm_vfeN_videoM），Venus 被挤到 video32/33。" + NL
        + "    // 编号取决于 probe 先后，不稳定，所以放宽范围而不是钉死编号。" + NL
        + "    static constexpr int kMaxVideoDeviceIndex = 64;" + NL
        + "    for (int i = 0; i < kMaxVideoDeviceIndex; ++i) {"
    )
    s = s.replace(anchor, new, 1)
    io.open(p, "w", encoding="utf-8", newline="").write(s)
    return "扫描上界 10 -> 64（camss 占了 video0-31，Venus 在 video32/33）"


def patch_gapps_conflicts(tree: pathlib.Path) -> str:
    """—— 修补 4：MindTheGapps 与 crDroid 树的三处冲突 ——

    (a) **Google 的开机向导必须去掉**（`SetupWizard`，arm64-vendor.mk）。
        它在初始化阶段强制连 Google 服务器，**中国大陆网络下会卡在欢迎页
        过不去，设备无法完成初始化**。crDroid 自带的 LineageSetupWizard
        不依赖 Google 服务，保留它。
        ★ 安全性判据：MindTheGapps 的 `GmsSetupWizardOverlay` 目标包是
          **org.lineageos.setupwizard**（不是 Google 那个），内容只有
          dynamic_color / partner_experiment 这类外观 bool ——
          **不会把流程交给 Google 向导**，删掉不会断链。

    (b) **`libjni_latinimegoogle` 与树内 LatinIME 模块名撞车**
        （arm64-vendor.mk + arm64/Android.bp）。两边都是
        `cc_prebuilt_library_shared` 且都写了 `prefer: true`，而 soong 的
        prefer 只解决「prebuilt 覆盖源码」，两个 prebuilt 它管不了。
        MindTheGapps 用了 soong namespace，所以 soong 阶段不报错，到 kati 才炸：
            base_rules.mk:320: error: vendor/gapps/arm64:
            MODULE.TARGET.SHARED_LIBRARIES.libjni_latinimegoogle
            already defined by packages/inputmethods/LatinIME/java
        ⚠️ 这个错误发生在【生成模块定义】时，不是安装时 ——
        **光从 PRODUCT_PACKAGES 里拿掉不够，必须删掉模块本身。**

    (c) **`google.xml` 与 crDroid 的 addons 装到同一路径**
        （common-vendor.mk）。`vendor/addons/config.mk:32` 无条件把自己那份
        拷到 `product/etc/sysconfig/google.xml`，于是：
            Makefile:148: error: overriding commands for target
            `.../product/etc/sysconfig/google.xml'
        ★ 留 crDroid 那份 —— **实测它是超集**：60 条声明 vs GApps 的 39 条，
          GApps 独有的只有 3 行，其中唯一的实条目是
          `<allow-in-power-save package="com.google.ambient.streaming" />`，
          而 MindTheGapps 压根不带那个应用。（是按内容比对定的，不是按文件大小。）
        这个是【安装路径】冲突而非模块名冲突，所以从 PRODUCT_PACKAGES
        里拿掉就够了。

    ⚠️★ **为什么不在设备树里用 `$(filter-out ...)`：那是无效的。**
      实测 `get_build_var PRODUCT_PACKAGES` —— 写了 filter-out 之后
      SetupWizard 仍在 1005 个条目里。现代 AOSP 从**继承图**重新推导
      PRODUCT_PACKAGES，产品 makefile 里的直接赋值会被丢弃。

    ★ 冲突是**一次性全找出来的**，不是一个个撞：36 个 gapps 模块名与全树
      逐个比对（只有 b），13 个 gapps etc 文件名与全树 PRODUCT_COPY_FILES
      逐个比对（只有 c）。

    ⚠️ repo sync 会还原 vendor/gapps，所以每次构建前都要跑本脚本（幂等）。
    """
    NL = chr(10)
    BS = chr(92)
    root = tree / "vendor/gapps"
    if not (root / "arm64/arm64-vendor.mk").exists():
        return "跳过（没同步 vendor/gapps —— 不装 GApps 就不需要这一步）"

    msgs = []

    def drop_from_mk(mk: pathlib.Path, names):
        """从 PRODUCT_PACKAGES 列表里删掉这些名字，并修好续行反斜杠。"""
        if not mk.exists():
            return []
        lines = io.open(mk, encoding="utf-8").read().split(NL)
        gone = []
        for name in names:
            for i, ln in enumerate(lines):
                if ln.strip().rstrip(BS).strip() == name:
                    had_cont = ln.rstrip().endswith(BS)
                    del lines[i]
                    # 删的是列表最后一项时，上一行的续行反斜杠要去掉
                    if not had_cont and i > 0 and lines[i - 1].rstrip().endswith(BS):
                        lines[i - 1] = lines[i - 1].rstrip().rstrip(BS).rstrip()
                    gone.append(name)
                    break
        if gone:
            io.open(mk, "w", encoding="utf-8", newline="").write(NL.join(lines))
        return gone

    g1 = drop_from_mk(root / "arm64/arm64-vendor.mk",
                      ["SetupWizard", "libjni_latinimegoogle"])
    g2 = drop_from_mk(root / "common/common-vendor.mk", ["google.xml"])
    gone = g1 + g2
    msgs.append("从包列表删掉 " + "/".join(gone) if gone else "包列表已是干净的")

    # ★★ 删掉模块定义【本身】——只从 PRODUCT_PACKAGES 里拿掉是不够的。
    #   实测：把 google.xml 从 common-vendor.mk 的包列表里删掉之后，
    #   构建仍然报同一个 "overriding commands for target ... google.xml"，
    #   因为 soong 会为它 namespace 里的模块照样生成安装规则
    #   （错误出自 out/soong/installs-lineage_gaokun3.mk）。
    #   ⇒ 凡是【模块名撞车】或【安装路径撞车】，都必须删模块块。
    def drop_module(bp: pathlib.Path, name: str):
        if not bp.exists():
            return False
        lines = io.open(bp, encoding="utf-8").read().split(NL)
        target = None
        needle = 'name: "%s",' % name
        for i, ln in enumerate(lines):
            if ln.strip() == needle:
                target = i
                break
        if target is None:
            return False
        start = target
        while start > 0 and not lines[start].rstrip().endswith("{"):
            start -= 1
        end = target
        while end < len(lines) and lines[end].rstrip() != "}":
            end += 1
        while end + 1 < len(lines) and lines[end + 1].strip() == "":
            end += 1
        del lines[start:end + 1]
        io.open(bp, "w", encoding="utf-8", newline="").write(NL.join(lines))
        return True

    dropped = []
    for rel, name in (("arm64/Android.bp", "libjni_latinimegoogle"),
                      ("common/Android.bp", "google.xml")):
        if drop_module(root / rel, name):
            dropped.append(name)
    msgs.append("从 Android.bp 删掉模块 " + "/".join(dropped)
                if dropped else "Android.bp 已是干净的")

    return " · ".join(msgs)


def patch_v4l2_initial_output(tree: pathlib.Path) -> str:
    """—— 修补 5：v4l2_codec2 在拿到 SOURCE_CHANGE 之前就想建输出队列 ——

    症状（修补 3 之后暴露出来的下一层）：
        V4L2Decoder: ioctl() failed: VIDIOC_G_FMT
        V4L2Decoder: Failed to start initialy output queue
        V4L2DecodeComponent: Failed to create V4L2Decoder for H264

    ★ **venus 这边是对的。** `vdec_check_src_change()`（vdec.c）明写着：

        if (inst->subscriptions & V4L2_EVENT_SOURCE_CHANGE &&
            inst->codec_state == VENUS_DEC_STATE_INIT &&
            !inst->reconfig)
                return -EINVAL;

    客户端订阅了 SOURCE_CHANGE，就必须**等事件到了再问 CAPTURE 的格式** ——
    这正是 V4L2 stateful 解码器规范要求的顺序。而 v4l2_codec2 的
    `setupInitialOutput()` 在**喂任何码流之前**就 G_FMT，那是 ChromeOS/ARCVM
    的一个优化（预先备一个 EOS 缓冲区），在守规范的驱动上必然失败。

    ⇒ 改成**失败不致命**：真正的输出队列本来就在分辨率变更事件里建
      （changeResolution() -> startOutputQueue()，同文件第 753 行附近）。

    ★ 安全性判据（逐个查过，不是猜的）：`mInitialEosBuffer` 的**每一处使用
      都已经有空指针判断**（V4L2Decoder.cpp 的 112 / 375 / 454 / 749 行），
      也就是说"它是空"本来就是被支持的状态。那三处分别是：
        · 375 提前判 DRC —— 跳过后 mPendingDRC 保持 false，只是少一个优化；
        · 454 "没有码流就直接结束 drain" —— 是 ARCVM 特有的捷径，
          不走它就落到 `sendV4L2DecoderCmd(false)`，那才是**标准**的 V4L2 drain；
        · 112 / 749 是清理。
      并且 `startOutputQueue()` 是在**第一步** getFormatInfo() 就返回 false 的，
      此时还没碰过队列，所以不会留下半配置状态。
    """
    p = tree / "external/v4l2_codec2/v4l2/V4L2Decoder.cpp"
    if not p.exists():
        return f"跳过（找不到 {p}）"
    s = io.open(p, encoding="utf-8").read()
    if "venus 在收到 SOURCE_CHANGE 之前" in s:
        return "已打过（幂等，无需改动）"
    anchor = ('    if (!setupInitialOutput()) {' + chr(10)
              + '        ALOGE("Unable to setup initial output");' + chr(10)
              + '        return false;' + chr(10)
              + '    }')
    if anchor not in s:
        return "⚠️ 找不到锚点，上游可能改了 start()"
    NL = chr(10)
    new = (
        "    // venus 在收到 SOURCE_CHANGE 之前会拒绝 CAPTURE 队列的 G_FMT" + NL
        + "    // （vdec_check_src_change() 返回 -EINVAL），这是 V4L2 stateful 规范" + NL
        + "    // 要求的顺序，不是驱动缺陷。所以这个「预先建最小输出队列」的" + NL
        + "    // ChromeOS 优化在本平台必然失败 —— 失败不致命：真正的输出队列" + NL
        + "    // 会在分辨率变更事件里建起来，且 mInitialEosBuffer 的每一处使用" + NL
        + "    // 都已有空指针判断。" + NL
        + "    if (!setupInitialOutput()) {" + NL
        + '        ALOGW("Unable to setup initial output up front; the driver wants a '
          'SOURCE_CHANGE event first. Continuing without the initial EOS buffer.");' + NL
        + "    }"
    )
    s = s.replace(anchor, new, 1)
    io.open(p, "w", encoding="utf-8", newline="").write(s)
    return "已改为失败不致命"


def patch_disable_desktop_mode(tree: pathlib.Path) -> str:
    """—— 修补 6：关掉 crDroid 给所有设备开的桌面窗口模式 ——

    用户要求关掉：这台平板上它会把每个应用都放进 freeform 窗口，日用很干扰。

    ⚠️★ **不能只在设备树的 overlay 里写 false —— 实测那样【无效】。**
      两次构建断言都顶回来 `config_isDesktopModeSupported 还是 true`：

        device/huawei/gaokun3/overlay/...        false   (DEVICE_PACKAGE_OVERLAYS)
        vendor/lineage/overlay/common/...        true    (PRODUCT_PACKAGE_OVERLAYS)

      **胜出的是 vendor/lineage 那份。** 也就是说在这棵树里
      `PRODUCT_PACKAGE_OVERLAYS` 的优先级【高于】`DEVICE_PACKAGE_OVERLAYS`
      —— 与"设备树优先"的常见说法相反。我们别的 overlay 值之所以一直好用，
      只是因为 vendor/lineage 没碰它们（逐个比对过，只有这一个资源冲突）。

    ⇒ 所以直接改胜出的那份。repo sync 会还原它，故本脚本每次构建前都要跑。

    ★ 顺带记一条被推翻的判断：上游参考（dragon-lineage 的 Radxa Dragon
      提交 d480d02）**只**设 config_canInternalDisplayHostDesktops，那对
      Lineage 系的树是**正确且充分**的 —— 因为 Lineage 自己已经把
      config_isDesktopModeSupported 设成 true 了。只查 AOSP 默认值（false）
      而不查 ROM 自己的 overlay，就会得出"他们漏了一个"的错误结论。
    """
    p = tree / "vendor/lineage/overlay/common/frameworks/base/core/res/res/values/config.xml"
    if not p.exists():
        return f"跳过（找不到 {p}）"
    s = io.open(p, encoding="utf-8").read()
    old = '<bool name="config_isDesktopModeSupported">true</bool>'
    new = '<bool name="config_isDesktopModeSupported">false</bool>'
    if new in s:
        return "已是 false（幂等，无需改动）"
    if old not in s:
        return "⚠️ 找不到锚点，crDroid 可能改了写法"
    s = s.replace(old, new, 1)
    io.open(p, "w", encoding="utf-8", newline="").write(s)
    return "已把 crDroid 的 config_isDesktopModeSupported 改成 false"


def apply_patch_file(tree: pathlib.Path, project: str, patch_name: str,
                     covered_by: tuple = ()) -> str:
    """把 <repo>/patches/<patch_name> 用 git apply 打进 AOSP 树的 <project>（幂等）。

    ★ 为什么要有这个助手：本仓 `patches/` 里的 **AOSP 侧**补丁（0003 glslang、
    0010 audio HAL、0019 v4l2_codec2；后来又有 0008 tinyalsa、0051 / 0052 / 0063 audio HAL）**一直没有任何消费者** —— 全靠人手动
    `git apply`。而本仓已经为"没有消费者的配置一定会漂"付过三次账
    （M13 的 BOARD_KERNEL_CMDLINE、M17 的上游 Venus 补丁集、以及 2026-09-12
    抢救回来的那一整批 08-24 工作）。内核那边有 kernel-apply-patches.sh，
    AOSP 这边的消费者就是本脚本。

    幂等判据用 `git apply --check -R`（反向能打上 = 已经在树里了）。
    ⚠️ 与 kernel-apply-patches.sh 不同，这里**不接受 fuzz** —— AOSP 树是
    repo sync 出来的干净树，打不上就是上游动了，应当大声报错而不是模糊匹配。

    covered_by：排在后面、改到同一段上下文的补丁（例如 0069 改了 0063 加的那几行附近）。
    它们打上之后，本补丁正反两个方向都对不上 —— 2026-10-04 重跑时 [15] 就这样报了"打不上"，
    而 0063 的 42 行其实一行不缺（#130）。这时把涉及的文件拷到临时目录、先撤掉这些后续补丁，
    再对本补丁做反向检查：过了才算"已打过"。不是放宽判据，判的仍是"本补丁确实在树里"。
    """
    repo = pathlib.Path(__file__).resolve().parent.parent
    patch = repo / "patches" / patch_name
    if not patch.exists():
        return f"⚠️ 找不到补丁 {patch}"
    proj = tree / project
    if not (proj / ".git").exists():
        return f"跳过（{project} 不是 git 仓库或不存在）"

    def git(*args):
        return subprocess.run(["git", "-C", str(proj), *args],
                              capture_output=True, text=True)

    if git("apply", "--check", "-R", str(patch)).returncode == 0:
        return "已打过（幂等，无需改动）"
    later = [repo / "patches" / n for n in covered_by]
    if later and all(git("apply", "--check", "-R", str(l)).returncode == 0 for l in later):
        if _applied_under(proj, patch, later):
            return "已打过（上下文被 " + "、".join(covered_by) + " 改过，撤掉它们后反向检查通过）"
    chk = git("apply", "--check", str(patch))
    if chk.returncode != 0:
        return "✗ 打不上（既不是已应用、也不干净）：" + chk.stderr.strip().splitlines()[0] if chk.stderr.strip() else "✗ 打不上"
    r = git("apply", str(patch))
    if r.returncode != 0:
        return "✗ 应用失败：" + (r.stderr.strip().splitlines()[0] if r.stderr.strip() else "?")
    return f"已应用 {patch_name}"


def _applied_under(proj: pathlib.Path, patch: pathlib.Path, later: list) -> bool:
    """在临时目录里：拷出涉及的文件 → 依次（倒序）撤掉 later → 对 patch 做反向检查。不碰 proj 本身。"""
    paths = set()
    for p in [patch, *later]:
        r = subprocess.run(["git", "-C", str(proj), "apply", "--numstat", str(p)],
                           capture_output=True, text=True)
        paths |= {line.split("\t")[2] for line in r.stdout.splitlines() if line.count("\t") >= 2}
    with tempfile.TemporaryDirectory() as tmp:
        for rel in paths:
            src = proj / rel
            if src.exists():
                (pathlib.Path(tmp) / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, pathlib.Path(tmp) / rel)

        def git_tmp(*args):
            # 临时目录不在任何仓库里，git apply 按普通补丁处理文件
            return subprocess.run(["git", "apply", *args], cwd=tmp, capture_output=True, text=True)

        for l in reversed(later):
            if git_tmp("-R", str(l)).returncode != 0:
                return False
        return git_tmp("--check", "-R", str(patch)).returncode == 0


def patch_connected_displays_flag(tree: pathlib.Path) -> str:
    """—— 修补 11：关掉 status_bar_connected_displays 这个 aconfig flag ——

    ⚠️★ **这条的立项理由从来没有被记录下来。** 它是 2026-09-12 从构建机上
    抢救回来的一处未提交改动（`build/release` 项目），当时那一轮（08-24）
    的案卷没写。本条注释是现存的全部说明。

    已知的事实（不是推测）：
      * flag 名 `com.android.systemui.shared/status_bar_connected_displays`，
        构建机把 `state: ENABLED` 改成了 `DISABLED`。
      * 本机的 USB-C 外接显示**一直不工作**（UCSI 有缺陷，`/sys/class/typec/`
        为空，见 TODO A6）。一个"连接外部显示器时改变状态栏行为"的功能，
        在没有可用外接显示的机器上打开，合理推测是有害无益的。
    ⚠️ 但**"合理推测"不是证据** —— 如果将来 A6 修好了外接显示，
    应当先把这条去掉再验一次，别让它变成又一条没人敢动的祖传配置。
    """
    p = (tree / "build/release/aconfig/bp4a/com.android.systemui.shared"
              / "status_bar_connected_displays_flag_values.textproto")
    if not p.exists():
        return f"跳过（找不到 {p.name}）"
    s = io.open(p, encoding="utf-8").read()
    if "state: DISABLED" in s:
        return "已是 DISABLED（幂等，无需改动）"
    if "state: ENABLED" not in s:
        return "⚠️ 既不是 ENABLED 也不是 DISABLED，上游可能改了格式"
    io.open(p, "w", encoding="utf-8").write(s.replace("state: ENABLED", "state: DISABLED", 1))
    return "ENABLED -> DISABLED"


def patch_wifi_sw_pno_gate(tree: pathlib.Path) -> str:
    """—— 修补 18：软件 PNO 只看 overlay 的 config_wifiSwPnoEnabled，不再看 DeviceConfig ——

    v1.0 NET-1（2026-10-05，TODO V3）。息屏且 Wi-Fi 断开时 Android 只靠 PNO 找回网络；ath11k 没有
    sched_scan（实机 iw phy 里没有 start_sched_scan），硬件 PNO 不可用 ⇒ 要软件 PNO。
    设备树 rro/Gaokun3WifiOverlay 已把 config_wifiSwPnoEnabled 设成 true（ff4a5a4），但 1.0.0-dev.1 上
    `dumpsys wifi` 里仍看不到软件 PNO：WifiScanningServiceImpl 的 StartedState 还要第二道门 ——

        } else if (mWifiGlobals.isSwPnoEnabled()
                && mDeviceConfigFacade.isSoftwarePnoEnabled()) {

    （LineageOS packages_modules_Wifi lineage-23.2：scanner/WifiScanningServiceImpl.java:2676-2677；
      isSoftwarePnoEnabled() = DeviceConfig wifi/software_pno_enabled，DeviceConfigFacade.java:420-421、:898-899，
      默认 false。）实机 `device_config get wifi software_pno_enabled` = false，而且是**显式下发**的值
    （list 里有这一项）—— 多半是 GMS Phenotype 推的，所以改默认值没用，只能去掉这道门。
    ⇒ 把条件改成只看 mWifiGlobals.isSwPnoEnabled()（= overlay 的 config_wifiSwPnoEnabled，WifiGlobals.java:573-576）。
      不碰 DeviceConfigFacade：别处没有用 isSoftwarePnoEnabled()（上游副本里只此一处），dumpsys 里那个值照旧如实显示。
      isPnoSupported()（WifiServiceImpl.java:8469）本来就只看 isSwPnoEnabled()，不用改。

    ⚠️ 锚点是按上游 lineage-23.2 的副本写的，本机没有构建机那棵 crDroid 树：
       构建机上核对 packages/modules/Wifi/service/java/com/android/server/wifi/scanner/WifiScanningServiceImpl.java
       里这两行还在（`grep -n isSoftwarePnoEnabled` 应当只有这一处调用），并确认 com.android.wifi APEX 是从源码编的
       （不是预编译的 Google 模块 —— 那样改源码不进镜像；Play 系统更新也换不掉它：包名 / 签名都不同）。
    上机判据（V9 / V13）：`dumpsys wifi` 里 PNO 失败不再是 "reason: -3 not supported"，mPnoScanMetrics 的
      numPnoScanAttempts 开始增长；息屏但醒着时让 AP 断开再恢复，2 分钟内自动回连。
    ⓘ 耗电（V13 问的"SwPnoScanState 用什么闹钟"，上游副本里查到了）：schedulePnoTimer 用
      setExactAndAllowWhileIdle(ELAPSED_REALTIME_WAKEUP, …)（WifiScanningServiceImpl.java:2979-2996）⇒ 会把机器从
      s2idle 叫醒去扫。次数有上限：默认 config_wifiSwPnoFastTimerMs=300000 × 3 次、SlowTimerMs=1200000 × 10 次
      （另有 MobilityStateTimerIterations=2；ServiceWifiResources config.xml:705-739），之后不再排程 ——
      只在"息屏 + 断网"时才有，批 4 量一次待机电流。
    ⚠️ 写法：正则只容忍空白差异；找不到锚点就报 ⚠️（step() 记为失败、整个脚本退 1），不会悄悄跳过。
    """
    p = (tree / "packages/modules/Wifi/service/java/com/android/server/wifi/scanner"
              / "WifiScanningServiceImpl.java")
    if not p.exists():
        # 与 [4] 那类"树里本来就可能没有"的项目不同：Wi-Fi 模块一定在，找不到只能是上游挪了文件 ⇒ 算失败
        return f"⚠️ 找不到 {p}，上游可能挪了文件"
    s = io.open(p, encoding="utf-8").read()
    marker = "gaokun3 tree-fix [18]"
    if marker in s:
        return "已改（幂等，无需改动）"
    pat = re.compile(r"\}(\s*)else if \(mWifiGlobals\.isSwPnoEnabled\(\)\s*"
                     r"&&\s*mDeviceConfigFacade\.isSoftwarePnoEnabled\(\)\)\s*\{")
    hits = pat.findall(s)
    if len(hits) != 1:
        return f"⚠️ 锚点（isSwPnoEnabled() && isSoftwarePnoEnabled()）出现 {len(hits)} 次（应为 1），上游可能改了写法"
    # 插进 Java 的注释只用 ASCII：不赌 javac 的源码编码设置
    s = pat.sub(lambda m: ("}" + m.group(1) + "else if (mWifiGlobals.isSwPnoEnabled()) {  // " + marker
                           + ": ignore DeviceConfig wifi/software_pno_enabled (GMS pushes false);"
                           + " see gaokun-android scripts/crdroid-tree-fixes.py"),
                s, count=1)
    io.open(p, "w", encoding="utf-8", newline="").write(s)
    return "已去掉软件 PNO 的 DeviceConfig 门（只看 config_wifiSwPnoEnabled）"


def patch_wifi_stable_factory_mac(tree: pathlib.Path) -> str:
    """—— 修补 19：Wi-Fi HAL 的"出厂 MAC"改成由 SoC 序列号派生的稳定本地管理地址 ——

    v1.0 NET-4（2026-10-05，构建机 crDroid 树核实）。本机 WCN6855 板子上没烧 MAC：固件每次开机给一个
    00:03:7f:12:xx:xx（只有后两字节随机，见 CLAUDE.md 的路由器静态租约），ath11k 拿它当 perm_addr。
    框架拿"出厂 MAC"的链路：ClientModeImpl.retrieveFactoryMacAddressAndStoreIfNecessary（:8065-8095）
      → WifiNative.getStaFactoryMacAddress（:2609-2610）→ WifiVendorHal.getStaFactoryMacAddress（:989-993）
      → HAL IWifiStaIface.getFactoryMacAddress → WifiIfaceUtil::getFactoryMacAddress
        （hardware/interfaces/wifi/aidl/default/wifi_iface_util.cpp:49-51）
      → InterfaceTool::GetFactoryMacAddress = ETHTOOL_GPERMADDR（frameworks/opt/net/wifi/libwifi_system_iface/
        interface_tool.cpp:144-165），读的是 netdev 的 perm_addr。
    ⇒ 开机脚本里 `ip link set wlan0 address …` 改不到这一层（只改 dev_addr，不改 perm_addr）：
       用户选"使用设备 MAC"时框架会在连接前把 MAC 设回 HAL 给的出厂值（ClientModeImpl.setCurrentMacToFactoryMac，
       :4420-4436）。所以改在 HAL 这一层：WifiIfaceUtil::getFactoryMacAddress 先读
       /sys/devices/soc0/serial_number（qcom socinfo），对 "gaokun3-wifi-mac:<接口名>:<序列号>" 做 FNV-1a 64，
       取低 6 字节、置本地管理位、清组播位；读不到序列号就照旧返回 perm_addr。
       接口名进哈希 ⇒ wlan0 / wlan1（热点）各有一个固定地址、互不相同。
    SELinux：hal_wifi 已能读所有 sysfs 类型（system/sepolicy/private/hal_wifi.te:11 r_dir_file(hal_wifi, sysfs_type)），不用加规则。
    配套：rro/Gaokun3WifiOverlay 把 config_wifiSaveFactoryMacToWifiConfigStore 设成 false —— 默认 true 时框架把
      【第一次】拿到的出厂 MAC 存进 WifiSettingsConfigStore 永久复用（ClientModeImpl.java:8068-8085），
      老机器存的是当年那个固件随机地址，派生地址就永远用不上。
    ⚠️ 序列号是 32 位的，派生地址能被穷举反推出序列号 —— 它不是秘密，只是别直接把序列号写进 MAC。
    上机判据：两次重启后 `cmd wifi status` / Settings「关于」里的 Wi-Fi MAC 相同、首字节第 2 位为 1；
      某个网络选"使用设备 MAC"后 `ip link show wlan0` 的地址等于它；`cat /sys/devices/soc0/serial_number` 非空。
    """
    p = tree / "hardware/interfaces/wifi/aidl/default/wifi_iface_util.cpp"
    if not p.exists():
        return f"⚠️ 找不到 {p}，上游可能挪了文件"
    s = io.open(p, encoding="utf-8").read()
    marker = "gaokun3 tree-fix [19]"
    if marker in s:
        return "已改（幂等，无需改动）"
    inc = "#include <android-base/macros.h>\n"
    ns_anchor = ("constexpr uint8_t kMacAddressLocallyAssignedMask = 0x02;\n")
    fn = re.compile(r"(std::array<uint8_t, 6> WifiIfaceUtil::getFactoryMacAddress\(const std::string& iface_name\) \{\n)"
                    r"(\s*return iface_tool_\.lock\(\)->GetFactoryMacAddress\(iface_name\.c_str\(\)\);\n\})")
    if s.count(inc) != 1 or s.count(ns_anchor) != 1 or len(fn.findall(s)) != 1:
        return "⚠️ wifi_iface_util.cpp 的锚点（include / 掩码常量 / getFactoryMacAddress）不唯一或不在，上游可能改了写法"
    s = s.replace(inc, inc + "#include <android-base/file.h>\n#include <android-base/strings.h>\n", 1)
    helper = (
        "\n// " + marker + ": stable locally-administered \"factory\" MAC derived from the SoC serial\n"
        "// (board has no programmed MAC; firmware hands out 00:03:7f:12:xx:xx, random every boot).\n"
        "// See gaokun-android scripts/crdroid-tree-fixes.py.\n"
        "bool gaokun3StableMac(const std::string& iface_name, std::array<uint8_t, 6>* mac) {\n"
        "    std::string serial;\n"
        "    if (!::android::base::ReadFileToString(\"/sys/devices/soc0/serial_number\", &serial)) {\n"
        "        return false;\n"
        "    }\n"
        "    serial = ::android::base::Trim(serial);\n"
        "    if (serial.empty() || serial == \"0\") return false;\n"
        "    const std::string key = \"gaokun3-wifi-mac:\" + iface_name + \":\" + serial;\n"
        "    uint64_t h = 0xcbf29ce484222325ULL;  // FNV-1a 64\n"
        "    for (unsigned char c : key) {\n"
        "        h ^= c;\n"
        "        h *= 0x100000001b3ULL;\n"
        "    }\n"
        "    for (size_t i = 0; i < mac->size(); i++) {\n"
        "        (*mac)[i] = static_cast<uint8_t>(h >> (8 * i));\n"
        "    }\n"
        "    (*mac)[0] &= ~kMacAddressMulticastMask;\n"
        "    (*mac)[0] |= kMacAddressLocallyAssignedMask;\n"
        "    return true;\n"
        "}\n")
    s = s.replace(ns_anchor, ns_anchor + helper, 1)
    s = fn.sub(lambda m: (m.group(1)
                          + "    std::array<uint8_t, 6> stable_mac;  // " + marker + "\n"
                          + "    if (gaokun3StableMac(iface_name, &stable_mac)) return stable_mac;\n"
                          + m.group(2)), s, count=1)
    io.open(p, "w", encoding="utf-8", newline="").write(s)
    return "HAL 出厂 MAC 改为由 soc0/serial_number 派生（读不到就退回 perm_addr）"


def patch_wifi_mac_randomization_default(tree: pathlib.Path) -> str:
    """—— 修补 20：新网络的 MAC 随机化默认值从"每次连接都换"（ALWAYS）改回 AOSP 的 AUTO（按网络固定）——

    v1.0 NET-4 / D14（用户 2026-10-04 定：持久模式 + 稳定的设备 MAC）。2026-10-05 构建机核实：
      * 这个默认值【没有资源可改】：crDroid 带的 GrapheneOS 补丁把字段默认写死成 RANDOMIZATION_ALWAYS（=100）——
        packages/modules/Wifi 提交 06bc263807：framework/java/android/net/wifi/WifiConfiguration.java:1964、
        service/java/com/android/server/wifi/WifiConfigurationUtil.java:284（比较基准随之改成 ALWAYS）；
        frameworks/opt/net/wifi 提交 3bf65d873：WifiTrackerLib StandardWifiEntry.getPrivacy() 无配置时返回
        PRIVACY_RANDOMIZATION_ALWAYS（:611）。
      * Settings 的连接对话框对新网络不设隐私下拉框的初值（WifiConfigController2.java:401-404 只给已保存的网络设），
        于是停在第 0 项 = PRIVACY_PREF_INDEX_PER_CONNECTION_RANDOMIZED_MAC（WifiConfigController.java:155），
        保存时写成 ALWAYS（WifiConfigController2.java:895-897 → WifiPrivacyPreferenceController2.java:132）。
    ⇒ 四处一起改回 AOSP 原值（字段默认与比较基准必须成对改，否则普通 App 的 addNetwork 会因"改了随机化设置"
       被 WifiConfigManager.java:1650-1665 拒掉）：字段默认 AUTO、比较基准 AUTO、无配置时 PRIVACY_RANDOMIZED_MAC、
       对话框对新网络预选"按网络随机"。用户仍可在网络详情里选"每次连接都换"（ALWAYS 的逻辑一行没删）。
    ⓘ AUTO 的实际行为 = 按网络固定的随机 MAC（WifiConfigManager.shouldUseNonPersistentRandomization:553-588：
       只有开放网络 + config_wifiAllowNonPersistentMacRandomizationOnOpenSsids（默认 false）或 SSID 在白名单里才换），
       地址由 keystore 里的 MacRandSecret 密钥对 SSID 做 HMAC（MacAddressUtil），与出厂 MAC 无关。
    ⚠️ 只管新加的网络。老用户已保存的网络存的是 ALWAYS（此前随机化总开关 config_wifi_connected_mac_randomization_supported
       是 false，隐私选项根本不显示 —— WifiConfigController2.java:341、WifiPrivacyPreferenceController2.java:60-62），
       这一版打开总开关后它们会【第一次真的每次连接都换 MAC】。没做自动迁移：存储里分不出"用户选的 ALWAYS"和
       "默认的 ALWAYS"（randomizedMacLastModifiedTimeMs 不落盘，XmlUtil 里没有这个标签）。要写进发版说明。
    上机判据：新连一个 WPA2 网络 → 详情里隐私显示"使用随机 MAC"（按网络）；断开重连 / 重启两次，
      `ip link show wlan0` 的地址不变且与出厂 MAC 不同；`cmd wifi list-networks` 后 dumpsys 里该网络
      macRandomizationSetting = 3（AUTO）。
    """
    edits = [
        ("packages/modules/Wifi/framework/java/android/net/wifi/WifiConfiguration.java",
         re.compile(r"public int macRandomizationSetting = RANDOMIZATION_ALWAYS;"),
         lambda m: ("public int macRandomizationSetting = RANDOMIZATION_AUTO;"
                    "  // MARK: AOSP default (was ALWAYS)")),
        ("packages/modules/Wifi/service/java/com/android/server/wifi/WifiConfigurationUtil.java",
         re.compile(r"return newConfig\.macRandomizationSetting != WifiConfiguration\.RANDOMIZATION_ALWAYS;"),
         lambda m: ("return newConfig.macRandomizationSetting != WifiConfiguration.RANDOMIZATION_AUTO;"
                    "  // MARK: must match the field default")),
        ("frameworks/opt/net/wifi/libs/WifiTrackerLib/src/com/android/wifitrackerlib/StandardWifiEntry.java",
         re.compile(r"(\}\s*else\s*\{\s*)return PRIVACY_RANDOMIZATION_ALWAYS;(\s*\})"),
         lambda m: (m.group(1) + "return PRIVACY_RANDOMIZED_MAC;  // MARK: AOSP default (was ALWAYS)"
                    + m.group(2))),
        ("packages/apps/Settings/src/com/android/settings/wifi/WifiConfigController2.java",
         re.compile(r"(\n(\s*)mPrivacySettingsSpinner\.setAdapter\(getSpinnerAdapter\(R\.array\.wifi_privacy_entries_ext\)\);\n)"),
         lambda m: (m.group(1) + m.group(2)
                    + "// MARK: new networks default to per-network randomized MAC; saved ones are set below\n"
                    + m.group(2) + "mPrivacySettingsSpinner.setSelection(WifiPrivacyPreferenceController2\n"
                    + m.group(2) + "        .translateWifiEntryPrivacyToPrefValue(WifiEntry.PRIVACY_RANDOMIZED_MAC));\n")),
    ]
    marker = "gaokun3 tree-fix [20]"
    todo = []
    for rel, pat, rep in edits:
        p = tree / rel
        if not p.exists():
            return f"⚠️ 找不到 {rel}，上游可能挪了文件"
        s = io.open(p, encoding="utf-8").read()
        if marker in s:
            continue
        if len(pat.findall(s)) != 1:
            return f"⚠️ {p.name} 的锚点出现 {len(pat.findall(s))} 次（应为 1），上游可能改了写法；四处都没动"
        todo.append((p, pat.sub(lambda m: rep(m).replace("MARK", marker), s, count=1)))
    if not todo:
        return "已改（幂等，无需改动）"
    # 先全部核对锚点、再统一写：避免只改了一半（字段默认与比较基准不成对会让 App 的 addNetwork 被拒）
    for p, s in todo:
        io.open(p, "w", encoding="utf-8", newline="").write(s)
    return f"MAC 随机化默认改回 AUTO（改了 {len(todo)} 个文件）"


def main():
    tree = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path.home() / "crdroid").expanduser()
    if not (tree / "build/envsetup.sh").exists():
        print(f"✗ {tree} 看起来不是 Android 源码树"); sys.exit(1)
    print(f"树: {tree}")
    failed = []

    def step(label: str, result: str) -> None:
        print(label + result)
        # 以 ✗ 或 ⚠️ 开头的结果都是"没做成"：补丁打不上 / 应用失败 / 仓库里缺补丁文件，以及直接改文本的那几条
        # 找不到锚点（上游改了写法）。都不能悄悄过去 —— 2026-09-28 PR #10 审查：以后 repo sync 让 [13]/[14] 打不上时，
        # 空录音 / 整块静音会悄悄回来；[2] 失效就是传感器全没，[3][5][7] 失效就是硬解悄悄回落软解。
        # 原先这里只打印、退出码照样是 0；现在与 kernel-apply-patches.sh 的"有失败就 exit 1"一致。
        # "跳过（找不到 …）"不算失败：那是树里没有这个项目或文件（例如不装 GApps 时的 [4]），照常打印
        if result.startswith(("✗", "⚠️")):
            failed.append(label.strip())
    step("  [1] SPOOF_SAFETYNET: ", patch_spoof_safetynet(tree))
    step("  [2] hexagonfs CR 截断: ", patch_hexagonfs_cr(tree))
    step("  [3] v4l2_codec2 输入分辨率: ", patch_v4l2_input_size(tree))
    step("  [4] GApps 冲突: ", patch_gapps_conflicts(tree))
    step("  [5] v4l2_codec2 初始输出队列: ", patch_v4l2_initial_output(tree))
    step("  [6] 关闭桌面窗口模式: ", patch_disable_desktop_mode(tree))
    step("  [7] v4l2_codec2 设备扫描范围: ", patch_v4l2_device_scan_range(tree))
    step("  [8] v4l2_codec2 HEVC CSD 合并: ", apply_patch_file(
        tree, "external/v4l2_codec2",
        "0019-v4l2-codec2-merge-hevc-csd-into-first-frame.patch"))
    step("  [9] glslang host 端 glslangValidator: ", apply_patch_file(
        tree, "external/deqp-deps/glslang",
        "0003-aosp-glslang-add-host-glslangValidator-binary.patch"))
    step(" [10] tinyalsa sw_params 取自 refined hw_params: ", apply_patch_file(
        tree, "external/tinyalsa_new",
        "0008-tinyalsa-derive-sw-params-from-refined-hw-params.patch"))
    step(" [11] 关掉 connected-displays flag: ", patch_connected_displays_flag(tree))
    step(" [12] audio AIDL primary 接受外部设备连接: ", apply_patch_file(
        tree, "hardware/interfaces",
        "0010-audio-aidl-primary-accept-external-device-connect.patch"))
    step(" [13] audio AIDL HAL 尊重策略给出的麦克风 address: ", apply_patch_file(
        tree, "hardware/interfaces",
        "0051-audio-aidl-honour-explicit-mic-address.patch"))
    step(" [14] audio AIDL HAL 采集方向 MonoPipe 容量翻倍（消除周期性插静音）: ", apply_patch_file(
        tree, "hardware/interfaces",
        "0052-audio-aidl-monopipe-capacity.patch"))
    # 依赖 [14]（采集管道要能放 2 块），所以排在它后面。#127 §6/§7：去掉开头 170 ms 静音与常驻 2 块延迟
    step(" [15] audio AIDL HAL 采集改成数据驱动交付（去掉开头静音与常驻延迟）: ", apply_patch_file(
        tree, "hardware/interfaces",
        "0063-audio-aidl-primary-capture-data-driven.patch",
        covered_by=("0069-audio-aidl-primary-playback-paced-by-alsa.patch",)))
    # 不依赖前面几条（只动 audio/aidl/default/apex/）。v0.7.0 验收 B2：effect HAL 在 vendor APEX 里，加载不了 /vendor/lib64/soundfx 的 Histen
    # ⚠️ 这是唯一一条会【新建】文件的 AOSP 补丁（linker.config.json，未跟踪）：把 hardware/interfaces 还原成上游时
    #    `git checkout -- .` / `reset --hard` 删不掉它，要再 `git clean -f audio/aidl/default/apex/`，否则这一条报"打不上"（2026-09-29 审查）
    step(" [16] audio APEX 链接器命名空间放行 /vendor/${LIB}/soundfx（Histen 效果库）: ", apply_patch_file(
        tree, "hardware/interfaces",
        "0068-audio-aidl-apex-permit-vendor-soundfx.patch"))
    # 上下文依赖 [14]/[15]（同一个 StreamAlsa / StreamPrimary），所以排在它们后面。#130：播放由硬件定拍、不再整块丢音乐
    step(" [17] audio AIDL HAL 播放由硬件定拍、位置按真实播出上报（卡顿不再整块丢音乐）: ", apply_patch_file(
        tree, "hardware/interfaces",
        "0069-audio-aidl-primary-playback-paced-by-alsa.patch"))
    # v1.0 NET-1 / TODO V3：软件 PNO 的第二道门（DeviceConfig wifi/software_pno_enabled，GMS 下发 false）
    step(" [18] Wi-Fi 软件 PNO 不受 DeviceConfig 覆盖（息屏断网后能自己回连）: ", patch_wifi_sw_pno_gate(tree))
    # v1.0 NET-4：稳定的设备 MAC（HAL 出厂 MAC 由 soc0 序列号派生）+ 新网络默认按网络固定的随机 MAC
    step(" [19] Wi-Fi HAL 出厂 MAC 由 SoC 序列号派生（稳定的设备 MAC）: ", patch_wifi_stable_factory_mac(tree))
    step(" [20] Wi-Fi 新网络 MAC 随机化默认改回 AUTO（按网络固定）: ", patch_wifi_mac_randomization_default(tree))
    # v1.0 AV-10：耳机麦。可插拔端口不能带 address ⇒ HAL 按设备类型读 ro.vendor.audio.primary.alsa.<type>（device.mk 设）。
    # 只动 StreamPrimary.cpp 的头文件区与 getCardAndDeviceId()，与 [12]–[17] 的上下文不重叠（构建机上对着打满的树核过：
    # 正向 --check 干净，打上之后 0010/0051/0052/0069 的反向检查仍过，撤 0069 后 0063 的反向检查仍过）。
    step(" [21] audio AIDL HAL 地址里没有 CARD_/DEV_ 时按设备类型回落（耳机麦）: ", apply_patch_file(
        tree, "hardware/interfaces",
        "0077-audio-aidl-primary-alsa-fallback-by-device-type.patch"))
    if failed:
        print(f"✗ {len(failed)} 条没做成：" + "；".join(failed))
        sys.exit(1)


if __name__ == "__main__":
    main()
