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
import io, re, sys, pathlib, subprocess

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


def apply_patch_file(tree: pathlib.Path, project: str, patch_name: str) -> str:
    """把 <repo>/patches/<patch_name> 用 git apply 打进 AOSP 树的 <project>（幂等）。

    ★ 为什么要有这个助手：本仓 `patches/` 里的 **AOSP 侧**补丁（0003 glslang、
    0010 audio HAL、0019 v4l2_codec2）**一直没有任何消费者** —— 全靠人手动
    `git apply`。而本仓已经为"没有消费者的配置一定会漂"付过三次账
    （M13 的 BOARD_KERNEL_CMDLINE、M17 的上游 Venus 补丁集、以及 2026-09-12
    抢救回来的那一整批 08-24 工作）。内核那边有 kernel-apply-patches.sh，
    AOSP 这边的消费者就是本脚本。

    幂等判据用 `git apply --check -R`（反向能打上 = 已经在树里了）。
    ⚠️ 与 kernel-apply-patches.sh 不同，这里**不接受 fuzz** —— AOSP 树是
    repo sync 出来的干净树，打不上就是上游动了，应当大声报错而不是模糊匹配。
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
    chk = git("apply", "--check", str(patch))
    if chk.returncode != 0:
        return "✗ 打不上（既不是已应用、也不干净）：" + chk.stderr.strip().splitlines()[0] if chk.stderr.strip() else "✗ 打不上"
    r = git("apply", str(patch))
    if r.returncode != 0:
        return "✗ 应用失败：" + (r.stderr.strip().splitlines()[0] if r.stderr.strip() else "?")
    return f"已应用 {patch_name}"


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


def main():
    tree = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path.home() / "crdroid").expanduser()
    if not (tree / "build/envsetup.sh").exists():
        print(f"✗ {tree} 看起来不是 Android 源码树"); sys.exit(1)
    print(f"树: {tree}")
    print("  [1] SPOOF_SAFETYNET: " + patch_spoof_safetynet(tree))
    print("  [2] hexagonfs CR 截断: " + patch_hexagonfs_cr(tree))
    print("  [3] v4l2_codec2 输入分辨率: " + patch_v4l2_input_size(tree))
    print("  [4] GApps 冲突: " + patch_gapps_conflicts(tree))
    print("  [5] v4l2_codec2 初始输出队列: " + patch_v4l2_initial_output(tree))
    print("  [6] 关闭桌面窗口模式: " + patch_disable_desktop_mode(tree))
    print("  [7] v4l2_codec2 设备扫描范围: " + patch_v4l2_device_scan_range(tree))
    print("  [8] v4l2_codec2 HEVC CSD 合并: " + apply_patch_file(
        tree, "external/v4l2_codec2",
        "0019-v4l2-codec2-merge-hevc-csd-into-first-frame.patch"))
    print("  [9] glslang host 端 glslangValidator: " + apply_patch_file(
        tree, "external/deqp-deps/glslang",
        "0003-aosp-glslang-add-host-glslangValidator-binary.patch"))
    print(" [10] tinyalsa sw_params 取自 refined hw_params: " + apply_patch_file(
        tree, "external/tinyalsa_new",
        "0008-tinyalsa-derive-sw-params-from-refined-hw-params.patch"))
    print(" [11] 关掉 connected-displays flag: " + patch_connected_displays_flag(tree))
    print(" [12] audio AIDL primary 接受外部设备连接: " + apply_patch_file(
        tree, "hardware/interfaces",
        "0010-audio-aidl-primary-accept-external-device-connect.patch"))
    print(" [13] audio AIDL HAL 尊重策略给出的麦克风 address: " + apply_patch_file(
        tree, "hardware/interfaces",
        "0051-audio-aidl-honour-explicit-mic-address.patch"))

if __name__ == "__main__":
    main()
