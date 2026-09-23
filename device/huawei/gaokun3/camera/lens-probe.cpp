/* SPDX-License-Identifier: Apache-2.0 */
/*
 * gaokun3-lens-probe —— 后摄 VCM（dw9714）独立探针。
 *
 * 为什么不塞进 HAL：HAL 只能"整包重编 + 重启 provider"才能改一行，
 * 而标定对焦需要反复试位置、复现"某个位置到底动没动"。这个工具单独编，
 * 秒级迭代，且不用动正在跑的相机服务。
 *
 * 用法（push 到 /data/local/tmp，用 su 跑）：
 *   gaokun3-lens-probe info           # 节点 + 控件范围 + 当前位置
 *   gaokun3-lens-probe sweep          # 全行程 9 点扫一遍，打印读写回值
 *   gaokun3-lens-probe hold 512 4000  # 停在某个位置 4 秒（配合预览肉眼看）
 *   gaokun3-lens-probe goto 0         # 移到某位置
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

	if (!strcmp(cmd, "info")) {
		const std::string node = Lens::findNode();
		if (node.empty()) {
			printf("没有找到 VCM 子设备（对焦不可用）\n");
			return 1;
		}
		Lens lens;
		if (!lens.open()) {
			printf("打开 %s 失败（权限或驱动问题）\n", node.c_str());
			return 1;
		}
		printf("节点   : %s\n", lens.node().c_str());
		printf("范围   : [%d, %d]\n", lens.minPos(), lens.maxPos());
		printf("当前位置: %d\n", lens.position());
		lens.close();
		return 0;
	}

	if (!strcmp(cmd, "sweep")) {
		Lens lens;
		if (!lens.open()) {
			printf("lens.open() 失败\n");
			return 1;
		}
		const int lo = lens.minPos(), hi = lens.maxPos();
		const int save = lens.position();
		printf("扫行程 [%d, %d]，每点读回值：\n", lo, hi);
		for (int i = 0; i <= 8; i++) {
			const int want = lo + (hi - lo) * i / 8;
			const bool ok = lens.setPosition(want);
			printf("  %4d -> 写%s 读回 %4d\n", want, ok ? "成功" : "失败",
			       lens.position());
			fflush(stdout);
			usleep(200 * 1000);
		}
		lens.setPosition(save);
		printf("已复位到 %d\n", save);
		lens.close();
		return 0;
	}

	if (!strcmp(cmd, "hold") || !strcmp(cmd, "goto")) {
		if (argc < 3)
			return usage();
		const int pos = atoi(argv[2]);
		int ms = 0;
		if (!strcmp(cmd, "hold"))
			ms = (argc > 3) ? atoi(argv[3]) : 3000;
		Lens lens;
		if (!lens.open()) {
			printf("lens.open() 失败\n");
			return 1;
		}
		const int save = lens.position();
		const bool ok = lens.setPosition(pos);
		printf("%s %d => %s，读回 %d\n", cmd, pos, ok ? "成功" : "失败",
		       lens.position());
		fflush(stdout);
		if (ms > 0)
			usleep(static_cast<useconds_t>(ms) * 1000);
		if (!strcmp(cmd, "hold")) {
			lens.setPosition(save);
			printf("已复位到 %d\n", save);
		}
		lens.close();
		return ok ? 0 : 1;
	}

	return usage();
}
