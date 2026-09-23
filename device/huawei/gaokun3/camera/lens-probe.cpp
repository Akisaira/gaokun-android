/* SPDX-License-Identifier: Apache-2.0 */
/*
 * gaokun3-lens-probe —— 后摄 VCM（dw9714）独立探针。
 *
 * 为什么不塞进 HAL：HAL 只能"整包重编 + 重启 provider"才能改一行，
 * 而标定对焦需要反复试位置、复现"某个位置到底动没动"。这个工具单独编，
 * 秒级迭代，且不用动正在跑的相机服务。
 *
 * 用法（push 到 /data/local/tmp，用 su 跑）：
 *   gaokun3-lens-probe info           # 节点 + 控件范围 + 控件当前值（不动马达）
 *   gaokun3-lens-probe sweep          # 全行程 9 点扫一遍，打印每次写入后的控件值
 *   gaokun3-lens-probe hold 512 4000  # 停在某个位置 4 秒（配合预览肉眼看），再恢复原值
 *   gaokun3-lens-probe goto 0         # 移到某位置（不恢复）
 *
 * ⚠️ 相机开着时 HAL 的自动对焦也在写同一个控件 —— 两边会互相覆盖。
 *    标定请用 HAL 的调试口 `setprop debug.gaokun3.camera.af.hold <pos>`，
 *    这个工具留给相机关着时验证马达本身。
 * ⚠️ "控件值"是驱动缓存的最后写入值（dw9714 没有 g_volatile_ctrl，VCM 也没有位置回读），
 *    它证明的是"写进了控件框架"，不是"马达真的到位"—— 要看到位与否只能看画面。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "Lens.h"

using gaokun3::Lens;

static int usage()
{
	fprintf(stderr,
		"用法：\n"
		"  gaokun3-lens-probe info\n"
		"  gaokun3-lens-probe sweep\n"
		"  gaokun3-lens-probe hold <pos> [ms]\n"
		"  gaokun3-lens-probe goto <pos>\n");
	return 2;
}

int main(int argc, char *argv[])
{
	const char *cmd = (argc > 1) ? argv[1] : "info";
	const bool isInfo = !strcmp(cmd, "info");
	const bool isSweep = !strcmp(cmd, "sweep");
	const bool isHold = !strcmp(cmd, "hold");
	const bool isGoto = !strcmp(cmd, "goto");
	if (!isInfo && !isSweep && !isHold && !isGoto)
		return usage();
	if ((isHold || isGoto) && argc < 3)
		return usage();

	Lens lens;
	/* center=false：探针绝不在打开时自己挪马达。 */
	if (!lens.open(/*center=*/false)) {
		printf("打开 VCM 失败（没有 dw9714 子设备，或权限不够 —— 用 su 跑）\n");
		return 1;
	}
	const int original = lens.readControl();

	if (isInfo) {
		printf("节点     : %s\n", lens.node().c_str());
		printf("范围     : [%d, %d]\n", lens.minPos(), lens.maxPos());
		printf("控件值   : %d（驱动缓存的最后写入值，不是马达回读）\n", original);
		lens.close();
		return 0;
	}

	if (isSweep) {
		const int lo = lens.minPos(), hi = lens.maxPos();
		printf("扫行程 [%d, %d]，每点写入后的控件值：\n", lo, hi);
		for (int i = 0; i <= 8; i++) {
			const int want = lo + (hi - lo) * i / 8;
			const bool ok = lens.setPosition(want);
			printf("  %4d -> 写%s，控件值 %4d\n", want, ok ? "成功" : "失败",
			       lens.readControl());
			fflush(stdout);
			usleep(200 * 1000);
		}
	} else {
		const int pos = atoi(argv[2]);
		const bool ok = lens.setPosition(pos);
		printf("%s %d => %s，控件值 %d\n", cmd, pos, ok ? "成功" : "失败",
		       lens.readControl());
		fflush(stdout);
		if (isHold) {
			const int ms = (argc > 3) ? atoi(argv[3]) : 3000;
			usleep(static_cast<useconds_t>(ms) * 1000);
		}
		if (isGoto) {
			lens.close();
			return ok ? 0 : 1;
		}
	}

	/* sweep / hold：恢复到打开前的控件值。 */
	if (original >= 0) {
		lens.setPosition(original);
		printf("已恢复到 %d\n", original);
	}
	lens.close();
	return 0;
}
