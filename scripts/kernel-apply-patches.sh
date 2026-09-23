#!/usr/bin/env bash
# 把本仓 patches/ 里【内核那一半】应用到一棵内核树。
#
# ★ 为什么需要这个脚本：patches/*.patch 长期以来【没有任何消费者】——
#   全靠人在构建机上手动 git apply。本会话已经为此付过一次代价：
#   两个 DTS 改动只活在构建机工作区里、从未入库（提交 ee5eca9 才补上）。
#   没有消费者的东西一定会漂。
#
# 用法：
#   bash scripts/kernel-apply-patches.sh /path/to/linux
#   bash scripts/kernel-apply-patches.sh /path/to/linux --check   # 只检查，不改动
#   bash scripts/kernel-apply-patches.sh /path/to/linux --verify  # ★ 精确核对：从 HEAD 起临时 worktree
#                                                                 #   按本表打满，逐文件与真实树比 md5
#
# 幂等：已经打上的补丁会被跳过（用反向 --check 判定），所以可以反复跑。
#
# ⚠️★ --check 在【已经打满】的树上有一个已知盲区（#110）：叠加补丁里靠前的那个
#    （如 0018 删掉后摄节点、0032 又在同一位置写回）反向 --check 对不上，会被报成"打不上"，
#    而树其实是对的。--verify 没有这个问题：它不逐个判定，而是把整条链在干净 worktree 上重放，
#    然后问"每个被补丁碰过的文件，真实树里的与重放出来的是否逐字节相同"。
#    这也是 TODO B0（构建机的树 ≠ 本仓配方）唯一可靠的探测器。
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TREE=${1:-}
MODE=${2:-apply}

[ -n "$TREE" ] || { echo "用法: $0 <内核树路径> [--check]" >&2; exit 2; }
[ -f "$TREE/Makefile" ] && [ -d "$TREE/kernel" ] || {
    echo "✗ $TREE 看着不像内核树（缺 Makefile 或 kernel/）" >&2; exit 2; }

# ★ 上游 Venus 补丁集先打 —— 本仓的 0011 依赖 0019 提供的 `venus` label。
#   2026-08-22 实测：少了它 DTB 直接编不过（"Label or path venus not found"），
#   而在此之前这一套【只活在构建机工作区里】。详见 patches/upstream-venus/README.md。
#   ⚠️ 0014 故意不列：纯格式清理、主线已分叉（M14 就决定跳过）。
UPATCHES=(
    upstream-venus/0013-media-dt-bindings-Document-SC8280XP-SM8350-Venus.patch
    upstream-venus/0015-media-venus-hfi_venus-Support-only-updating-certain-bits-with-presets.patch
    upstream-venus/0016-media-platform-venus-Add-optional-LLCC-path.patch
    upstream-venus/0017-media-venus-core-Add-SM8350-resource-struct.patch
    upstream-venus/0018-media-venus-core-Add-SC8280XP-resource-struct.patch
    upstream-venus/0019-arm64-dts-qcom-sc8280xp-Add-Venus.patch
    upstream-venus/0020-arm64-dts-qcom-sc8280xp-huawei-gaokun3-Enable-Venus.patch
)

# ⚠️ 只列内核补丁。其余的归属别处：0003 AOSP glslang、0004/0005/0006 mesa、
#    0008 tinyalsa、0010 AOSP audio HAL —— 别往内核树上打。
KPATCHES=(
    0001-efi-pstore-register-backend-when-efivars-ops-arrive-.patch
    0002-arm64-dts-gaokun3-drive-ts-mode-gpio174-low.patch
    0007-bpf-inode-label-bpffs-lazily-for-android-genfscon.patch
    0009-arm64-dts-sc8280xp-add-cpu-cooling-maps.patch
    # ❌ 0011（gaokun3.dts 里 &venus { firmware-name; status = "okay"; }）故意【不列】：
    #    upstream-venus/0020 加的是【逐字相同】的块、同一位置，而且两者的上下文在打了对方之后
    #    仍然匹配 ⇒ 依次打会得到【两份】&venus 块（dtc 会合并、DTB 不变，所以谁都没发现）。
    #    2026-09-14 --verify 第一次跑就抓到：构建机树只有一份、重放出来两份。文件留作案卷。
    0012-arm64-dts-gaokun3-usb0-otg-for-usb-adb.patch
    0013-drm-crtc-drop-racy-BUG_ON-in-fence_to_crtc.patch
    0014-remoteproc-qcom-ratelimit-repeat-handover-error.patch
    0015-asoc-sc8280xp-retune-wsa-speaker-gain-ceilings.patch
    # ★★ 0016/0017 是 Android 起不来的硬前提（ashmem / xt_quota2，ACK 专有）。
    #    它们此前只活在构建机的内核树里，2026-09-08 照本仓配方重建的内核
    #    因此黑屏起不来 —— 见 docs/stage4-findings.md #79。别删。
    0016-staging-android-port-ashmem-from-ack.patch
    0017-netfilter-port-xt-quota2-from-ack.patch
    # 0018：前摄要工作就得去掉后摄节点（A/B 实测，#81）。只动 camera.dtsi。
    0018-arm64-dts-gaokun3-camera-drop-rear-s5k3l6.patch
    # ⚠️ 0020 是上游 7.3 的 backport，用来验证 camss 电源域缺陷（#83）的一个
    #    【待验证假说】—— 它与相机一起用，单独打上无害（只是少注册一个没人用的时钟）。
    0020-clk-qcom-camcc-sc8280xp-unregister-gdsc-clk.patch
    # ❌ 0021（给 titan_top 加 NoC 投票）**已被实测否掉**（内核 #6，见 #102），
    #    故意【不列】在这里。文件仍留在 patches/ 下，头部有醒目的"已否"横幅。
    # 0022 与相机判据零交叉，只在驱动解绑时生效；修 #87 查到的 rebind 撞名。
    #    ⬜ 它本身**至今未验证** —— 要在干净开机、camss 健康时测（#102 第四节）。
    0022-clk-qcom-gdsc-tear-down-genpds-in-unregister.patch
    # ⚠️ 0023 是【诊断补丁，不要进发版内核】：每次 titan 域翻转打两行寄存器转储。
    #    它存在的意义是把"读 GDSCR"从 /dev/mem（本机会静默死内核）换成 regmap。
    # ❌ 0024 / 0025 / 0026 三条试验补丁**已被内核 #10 实测否掉**（#104：上电后重试、
    #    塌缩前复位 CAMNOC+CPAS、塌缩前复位全部 21 个 BCR，都救不回来），故意【不列】。
    #    文件留在 patches/ 下作案卷。它们都依赖 0023，若要复现顺序不能反。
    # ★ 0027 是候选根因修复（#105）：sc8280xp 的 camcc 一个 GDSC 都没给等待值，
    #    gdsc_init() 就用 MSM8974 的 2/8/2 覆盖硬件复位值；同代同偏移的 sm8150/sc8180x
    #    都写 2/2/0xf。它改的是 camcc-sc8280xp.c 的 gdsc 结构体，与 0020 的 hunk 不相交。
    0027-clk-qcom-camcc-sc8280xp-gdsc-wait-vals.patch
    # ⚠️ 0028 是【诊断补丁，不要进发版内核】，**依赖 0023**（用它的 gdsc_is_watched）。
    #    debugfs gdsc-dbg/init_raw 读硬件复位值（核实 0027 的依据）、wait_override 运行时改等待值。
    # ❌ 0027 已被内核 #11 实测否掉（#105）：硬件复位值确实是 2/2/0xf（0028 读出），
    #    但改回去之后脏塌缩签名与上电冻死一字不差。留在列表里是因为它**就是正确的硬件值**
    #    （上游同代驱动全这么写），只是不是这个缺陷的根因。
    # ⚠️ 0029 是【诊断补丁，不要进发版内核】，依赖 0023/0028：裸翻转 GDSC、屏蔽 RETAIN_FF、塌缩前延时。
    # ⚠️ 0030 是【诊断补丁，不要进发版内核】：camss 按块跳过 s_power/s_stream（module 参数 dbg_skip）。
    # ★ 0031 候选根因修复（#105）：camnoc_axi / slow_ahb / fast_ahb 三个 RCG 标成 shared，
    #    关闭时停靠 XO。实测一次出流后 camnoc_axi_clk_src 指着已熄灭的 pll0_out_even。
    #    改的是 camcc-sc8280xp.c 里三个 .ops 行，与 0020/0027 的 hunk 不相交。
    0031-clk-qcom-camcc-sc8280xp-mark-camnoc-ahb-rcgs-shared.patch
    # ★ 后摄 OV13B10（#106）：0032 叠在 0018 之后，把后摄节点按板级电源表接回（@0x36）；
    #    0034 给上游 ov13b10 加 OF 匹配表与板级上电序列。三关（probe / 出帧 / HAL 枚举）都过了才进来。
    #    ⚠️ 需要 .config 里 VIDEO_OV13B10=y 与 VIDEO_DW9714=y（kernel-config-android.sh 已断言）。
    #    0033（s5k3l6xx 驱动）故意【不列】：本机后摄不是 S5K3L6，文件留作案卷。
    0032-arm64-dts-gaokun3-camera-rear-ov13b10-with-board-rails.patch
    0034-media-i2c-ov13b10-of-match-and-gaokun3-power-sequence.patch
    # ★ 0035（#108）：camss 等不到某颗传感器时（同板另一种后摄模组），超时后只带绑上的传感器
    #    完成 notifier —— 于是"后摄模组不对"只丢后摄，前摄照常。内核 #19 两路实测：
    #    正常 47 个 subdev；ov13b10.fail_probe=1 时 20 s 后回落、45 个 subdev、前摄出帧。
    0035-media-camss-continue-without-never-bound-sensors.patch
    # ★ 0036（#110）：后摄闪光灯 = PMIC pmc8280c 闪光模块 1+4 路（内核 #19 逐路点亮实测），
    #    并删掉不亮的 GPIO93 gpio-led。只动 camera.dtsi，叠在 0032 之后。
    #    ⚠️ 需要 LEDS_CLASS_FLASH=y LEDS_QCOM_FLASH=y（kernel-config-android.sh 已断言）。
    0036-arm64-dts-gaokun3-pmic-flash-led-channels-1-4.patch
    # ★ 0037（#113）：himax 触摸的坐标 fuzz 做成 0644 模块参数，可运行时改。
    #    默认仍是 8 ⇒ 单独打上【不改变行为】，要的是"调参不用重启"这个能力。
    #    调定之后把值写进 DT 的 touchscreen-fuzz-x/y（标准属性，touchscreen.c:89 会覆盖驱动默认）。
    0037-Input-himax-spi-runtime-tunable-coordinate-fuzz.patch
    # ★★ 0038（#114）：跳点检测的判据从【原始位移】改成【与预测位置的偏差】。
    #    原判据等于一条 1.0 m/s 的限速线，越过之后 debounce 永远回不到 0 ⇒
    #    手指只要持续快过它，驱动【一个点都不上报】。实测：一次甩动被切成 87 条轨迹。
    #    本补丁不改默认值，只改判据含义。
    0038-Input-himax-spi-jump-detection-vs-predicted-position.patch
    # ★ 0039（#114）：Z8 孤立尖峰过滤与边缘单像素豁免做成可调（iso_nbr_ratio_q8 /
    #    edge_min_area），并标注掌压规则 3 是死代码。三项默认值不变 ⇒ 单独打上不改变行为。
    0039-Input-himax-spi-tunable-isolated-spike-and-edge-gates.patch
    # ★ 0040（#115）：修好 SPI 读重试（tx/rx 同一块缓冲，重试发的是上次收到的数据 ⇒
    #    三次机会实际只有一次），并让事件栈一次传完（原先每帧切成 5129+3 两次 spi_sync）。
    0040-Input-himax-spi-fix-SPI-read-retry-and-split-event-stack.patch
    # ★★ 0041（#115）：连通域表满时原先是 return 而不是 break ⇒ 放弃扫描网格【剩下的全部】。
    #    噪声多（充电器耦合）时屏幕下半部分的真实手指整个消失。改成按 signal_sum 顶替最弱的。
    0041-Input-himax-spi-do-not-abandon-the-grid-when-zones-fill.patch
    # ★ 0042（#115）：掌压剔除改成【标记】而不是删除 —— BFS 是 8 连通，指尖挨着手掌会进同一个
    #    zone，删掉就把手指一起删了。默认行为不变（标记的 zone 不出峰值），但决定变得可见可逆。
    0042-Input-himax-spi-mark-palm-zones-instead-of-deleting-them.patch
    # ★★★ 0043（#115）：逐级计数器（algo/stats）、最近 16 个触点出生记录（algo/contacts_log）、
    #    debugfs 两个整帧导出（frame_raw = 面板产出的，frame = 流水线判定的）。
    #    不改变任何触摸行为，只是让行为可观测 —— #114 那一晚的推理以后是一次 cat 的事。
    0043-Input-himax-spi-per-stage-counters-and-raw-grid-dumps.patch
    # ★ 0044（#115）：上报坐标轴分辨率（此前 resolution=0 = 告诉用户态"不知道"）。10 单位/毫米。
    0044-Input-himax-spi-report-axis-resolution.patch
    # ★ 0045（#115）：修好 W=1 报的两处 kerneldoc。纯注释，改完这个驱动 W=1 完全干净。
    0045-Input-himax-spi-fix-two-kerneldoc-blocks.patch
    # ★★ 0046（#116）：坐标 fuzz 定案为 0，写进 DT 的标准属性 touchscreen-fuzz-x/y。
    #    实机量的：空载噪声 RMS 29.6 ⇒ 质心抖动 σ 只有 0.16/0.10 输出单位（不到半个单位），
    #    而 fuzz=8 的死区是 ±4 单位（大 8 倍）。慢速拖动 A/B：位移为 0 的帧 13.7% → 1.8%。
    0046-arm64-dts-gaokun3-touchscreen-fuzz-0.patch
    # ★ 0047（#116）：pressure_enabled 默认跟着轴走（轴存在却报常数是逻辑缺陷）；
    #    contacts_log 加 zone_area 列 —— ct->area 分不开手掌碎块和指尖（实测 8-20 vs 5-21），能分的是它。
    0047-Input-himax-spi-pressure-follows-axes-and-log-zone-area.patch
    # ⚠️ 0048（#118 §7，待验证）：usb_0 用 UTMI 当 pipe 时钟 —— 角色切换后 xhci -110 / gadget -524。
    0048-arm64-dts-gaokun3-usb0-select-utmi-as-pipe-clk.patch
)

# ⚠️ 诊断补丁【不进发版内核】：只在带 --with-diag 时打。顺序有依赖：0028/0029 依赖 0023，
#   0029 依赖 0028；0030 独立。反向撤掉时要倒序（0030 0029 0028 0023）。
#   它们是 #103–#105 取证用的（regmap 转储 / debugfs 旋钮 / camss 按块跳过），
#   发版内核里留着只会在每次 titan 域翻转时刷两行 pr_err。
DIAG_PATCHES=(
    0023-clk-qcom-gdsc-dump-gdscr-on-toggle-and-timeout.patch
    0028-clk-qcom-gdsc-debugfs-init-raw-and-wait-override.patch
    0029-clk-qcom-gdsc-debugfs-raw-toggle-flags-mask-pre-off-delay.patch
    0030-media-camss-dbg-skip-per-block-stream-power.patch
)
WITH_DIAG=0
for a in "$@"; do [ "$a" = "--with-diag" ] && WITH_DIAG=1; done
if [ "$WITH_DIAG" = 1 ]; then
    KPATCHES+=("${DIAG_PATCHES[@]}")
    echo "⚠️ --with-diag：诊断补丁也会打（${#DIAG_PATCHES[@]} 个），这不是发版内核"
else
    # 发版路径：诊断补丁若还在树里，要大声说出来 —— 否则会把带 pr_err 转储的内核发出去
    for p in "${DIAG_PATCHES[@]}"; do
        f="$REPO/patches/$p"
        [ -f "$f" ] || continue
        if git -C "$TREE" apply --check -R "$f" 2>/dev/null; then
            echo "✗ 诊断补丁 $p 还在树里 —— 发版内核不能带它。撤掉：git apply -R patches/${p}（倒序）" >&2
            exit 1
        fi
    done
fi

# ★★ 指纹判据：补丁是否【已在树里】。
#
# ⚠️ 为什么不能只靠 `git apply -R --check`：**用 fuzz 打进去的补丁，反向检查
#    一定失败**（上下文已经和补丁里的不一致了）。于是脚本会认为"没打过"，
#    再用 fuzz 打一遍 —— 结果就是【同一段代码出现两份】。
#    本仓已经因此中招两次：venus 的 sc8280xp_freq_table / sc8280xp_res 被打成
#    两份，of_match 里 sc8280xp-venus 出现三条。**构建不一定报错**，
#    重复的 static 结构体只是浪费空间，重复的 of_match 条目只是第一条生效，
#    所以症状极其隐蔽。
#
# 判据：从补丁里挑【最长的几条】新增行，到它要改的文件里 grep，要求【全部命中】。
#
# ⚠️★★ 2026-09-11：这里原来是"挑第一条长度 > 25 的新增行"，**制造过一次真实事故**。
#    `patches/0009`（CPU cooling maps）的第一条合格新增行是
#        polling-delay-passive = <250>;
#    而这行在【未打补丁的】sc8280xp.dtsi 里本来就有一次（主线自带的 gpu-thermal 区）
#    ⇒ grep 命中 ⇒ 判成"已应用" ⇒ 静默跳过 ⇒ **重建的内核悄悄失去 CPU 温控降频**。
#    这正是 M17 写这个脚本要防的那件事，结果被脚本自己的判据复现了。
#    实测：新树里 cooling-maps 只有 1 处（主线的），旧树 9 处。
#
# ★ 两处加固，都便宜：
#    ① 探针改挑【最长】的新增行 —— 越长越不可能与既有代码撞车
#       （0009 的最长行是 `cooling-device = <&cpu0 THERMAL_NO_LIMIT ...>` 64 字符，
#        在未打补丁的文件里根本不存在）。
#    ② 取最多 3 条并要求【全部】命中 —— 单条撞车是偶然，三条同时撞车基本不可能。
#
# ⚠️ 为什么不怕假阴性：fuzz 影响的是【上下文】匹配，新增行本身一定是逐字写入的。
#    万一仍误判成"没打过"，后面 `git apply --check` 会失败并走 fuzz，
#    fuzz 再失败就【大声报错】—— 方向是对的：宁可吵，也不要静默跳过。
#    ③ ⚠️★ 2026-09-13 又补一条：**把"只是被搬家"的行从探针里剔掉。**
#       `patches/0022` 把 `gdsc_pm_subdomain_remove()` 与 `of_genpd_del_provider()`
#       两行调了个个儿，于是它们同时出现在 `-` 和 `+` 两侧 ——
#       而 `+` 侧的行**在未打补丁的文件里本来就在**，三条探针会全部命中，
#       整个补丁被静默跳过。这与 0009 那次是**同一类事故**（探针撞上既有代码），
#       只是来源从"巧合"变成了"必然"。判据：凡是也出现在删除行里的，不作数。
already_applied() {
    local f="$1" probes files ff hit n
    probes=$(grep -E '^\+[^+]' "$f" | sed 's/^+//' \
             | grep -vE '^[[:space:]]*$' \
             | grep -vxF -f <(grep -E '^-[^-]' "$f" | sed 's/^-//') \
             | awk 'length($0) > 25' | sort -u \
             | awk '{ print length($0), $0 }' | sort -rn | head -3 | cut -d' ' -f2-)
    [ -n "$probes" ] || return 1
    files=$(grep -E '^\+\+\+ b/' "$f" | sed 's|^+++ b/||')
    n=0
    while IFS= read -r probe; do
        [ -n "$probe" ] || continue
        n=$((n + 1))
        hit=0
        for ff in $files; do
            [ -f "$TREE/$ff" ] || continue
            if grep -qF "$probe" "$TREE/$ff"; then hit=1; break; fi
        done
        [ "$hit" = 1 ] || return 1
    done <<< "$probes"
    [ "$n" -gt 0 ] || return 1
    return 0
}

# ── --verify：干净 worktree 重放整条链，再与真实树逐文件比 ──
if [ "$MODE" = "--verify" ]; then
    WT=$(mktemp -d "${TMPDIR:-/tmp}/kap-verify.XXXXXX") && rmdir "$WT"
    git -C "$TREE" worktree add --detach -q "$WT" HEAD || { echo "✗ 建不了临时 worktree" >&2; exit 2; }
    trap 'git -C "$TREE" worktree remove --force "$WT" 2>/dev/null' EXIT
    echo "内核树: ${TREE}（HEAD $(git -C "$TREE" rev-parse --short HEAD)）"
    echo "重放到: $WT"
    fails=0; fuzzed=0
    for p in "${UPATCHES[@]}" "${KPATCHES[@]}"; do
        f="$REPO/patches/$p"
        [ -f "$f" ] || { echo "✗ 缺文件 $p"; fails=$((fails + 1)); continue; }
        if git -C "$WT" apply "$f" 2>/dev/null; then
            :
        elif patch -p1 -d "$WT" -s --fuzz=3 < "$f" >/dev/null 2>&1; then
            echo "  ⚠️ 用了 fuzz=3  $p"; fuzzed=$((fuzzed + 1))
        else
            echo "✗ 干净树上打不上  $p"; fails=$((fails + 1))
        fi
    done
    # 被任何补丁碰过的文件，逐个比
    files=$(for p in "${UPATCHES[@]}" "${KPATCHES[@]}"; do
                grep -hE '^\+\+\+ b/' "$REPO/patches/$p" 2>/dev/null; done | sed 's|^+++ b/||' | sort -u)
    diffs=0; same=0
    for ff in $files; do
        a=$(md5sum < "$WT/$ff" 2>/dev/null | cut -c1-32)
        b=$(md5sum < "$TREE/$ff" 2>/dev/null | cut -c1-32)
        if [ "$a" = "$b" ]; then same=$((same + 1)); else
            echo "✗ 与配方重放不一致  $ff"
            diff -u "$WT/$ff" "$TREE/$ff" 2>/dev/null | grep -E '^[-+][^-+]' | head -6 | sed 's/^/      /'
            diffs=$((diffs + 1))
        fi
    done
    echo
    echo "重放：打不上 $fails · 用了 fuzz ${fuzzed}；核对：一致 $same 个文件 · 不一致 $diffs 个"
    if [ "$fails" -eq 0 ] && [ "$diffs" -eq 0 ]; then
        echo "✓ 真实树里被补丁碰过的每个文件都与配方逐字节相同"
        exit 0
    fi
    exit 1
fi

cd "$TREE"
echo "内核树: $TREE"
echo "版本:   $(make kernelversion 2>/dev/null || echo 未知)"
echo

applied=0; skipped=0; failed=0; fuzzed=0
for p in "${UPATCHES[@]}" "${KPATCHES[@]}"; do
    f="$REPO/patches/$p"
    [ -f "$f" ] || { echo "✗ 缺文件 $p"; failed=$((failed + 1)); continue; }

    # 反向能打通 ⇒ 已经在树里了（精确应用过的走这条）
    if git apply --check -R "$f" 2>/dev/null; then
        echo "· 已应用，跳过  $p"
        skipped=$((skipped + 1)); continue
    fi
    # ★ 正向能干净打上 ⇒ 一定【还没打过】，直接打。
    #   ⚠️★★ 这一步必须排在指纹判据【前面】（2026-09-13 踩的坑）：patches/0031 的新增行是
    #   `.ops = &clk_rcg2_shared_ops,`，而文件里别处早有 21 行一模一样 ⇒ 指纹"命中"、
    #   静默跳过，于是那一轮构建出来的内核根本没带修复，而脚本输出看起来完全正常。
    #   ★ 指纹只能回答"这些行在不在文件里"，回答不了"是不是【这个补丁】放进去的"；
    #   正向 --check 成功则是确定性的"没打过"。指纹判据只留给"正向打不上"之后的分流。
    if git apply --check "$f" 2>/dev/null; then
        if [ "$MODE" = "--check" ]; then
            echo "→ 可应用（--check 模式，未改动）  $p"
        else
            git apply "$f" && echo "✓ 已应用  $p"
        fi
        applied=$((applied + 1)); continue
    fi
    # ★ 指纹判据 —— 专治"用 fuzz 打进去过"的情况，反向检查对它们无效。
    #   少了这一步会把同一个补丁重复打进去（详见 already_applied 的注释）。
    if already_applied "$f"; then
        echo "· 已应用（指纹命中，当初多半是 fuzz 打的），跳过  $p"
        skipped=$((skipped + 1)); continue
    fi
    if ! git apply --check "$f" 2>/dev/null; then
        # ★ 回落到模糊匹配。0019 就需要这个（上下文里的 #include 列表与
        #   v7.2-rc2 差一行 qcom,scm.h）。⚠️ 用了 fuzz 必须【明说】，
        #   静默的模糊匹配是灾难的开始。
        if patch -p1 -d "$TREE" --dry-run --fuzz=3 < "$f" >/dev/null 2>&1; then
            if [ "$MODE" = "--check" ]; then
                echo "→ 可应用【需 fuzz=3】（--check 模式，未改动）  $p"
            else
                patch -p1 -d "$TREE" --fuzz=3 < "$f" | sed 's/^/    /'
                echo "✓ 已应用 ⚠️【用了 fuzz=3，不是精确匹配】  $p"
            fi
            applied=$((applied + 1)); fuzzed=$((fuzzed + 1)); continue
        fi
        echo "✗ 打不上（既不是已应用、也不干净、fuzz 也救不了）  $p"
        git apply --check "$f" 2>&1 | sed 's/^/    /'
        failed=$((failed + 1)); continue
    fi
    if [ "$MODE" = "--check" ]; then
        echo "→ 可应用（--check 模式，未改动）  $p"
    else
        git apply "$f" && echo "✓ 已应用  $p"
    fi
    applied=$((applied + 1))
done

echo
echo "可应用/已应用 $applied · 跳过 $skipped · 失败 $failed · 其中用了 fuzz $fuzzed"
[ "$failed" -eq 0 ] || exit 1
