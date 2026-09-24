// 流程测试：用真后端录的 fixture 把每条路从头点到尾，并核对最后发给后端的调用。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gk3_installer/model/model.dart';
import 'package:gk3_installer/session.dart';

import 'helpers.dart';

void main() {
  testWidgets('windows-free：双系统一路装到完成，apply 的参数对', (t) async {
    final rec = await pumpApp(t, 'windows-free');
    await see(t, find.text(l.welcomeTitle));
    await tap(t, find.text(l.btnStart));
    await see(t, find.text(l.diskTitle));
    // 安装 U 盘列出来了、但禁用并写明原因（C 版是直接藏起来）
    await see(t, find.text(l.diskMedium));
    await tap(t, find.textContaining('/dev/nvme0n1'));
    await next(t);
    await see(t, find.text(l.modeTitle));
    await see(t, find.text(l.modeAlongOk));
    await tap(t, find.text(l.modeAlongTitle));
    await next(t);
    await see(t, find.text(l.sourceTitle));
    await next(t);
    await see(t, find.text(l.optsTitle));
    await see(t, find.textContaining('/data'), findsWidgets);
    await next(t);
    await see(t, find.text(l.confirmTitle));
    await see(t, find.text(l.confirmAlongHead));
    await see(t, find.text(l.confirmWindowsKept));
    // 值落在对的位置（占位符顺序那个 bug：曾渲染成"创建 /dev/nvme0n1p1 的分区…EFI 分区 80 GiB"）
    await see(t, find.textContaining('EFI 分区 /dev/nvme0n1p1'));
    await hold(t, l.confirmHoldIdle);
    await see(t, find.text(l.doneTitle));
    final a = rec.last('gk3_apply')!.join(' ');
    expect(a, contains('--mode alongside'));
    expect(a, contains('--rescue yes'));
    expect(a, contains('--region-start 790497280 --region-end 958269439'));
    expect(a, contains('--esp /dev/nvme0n1p1'));
    expect(a, contains('--release /media/gk3/gaokun3/payload'));
  });

  testWidgets('factory：没有空闲区 → 双系统禁用并报"至少要多少"（后端报的数）→ 缩分区 → 双系统可选', (t) async {
    await pumpApp(t, 'factory');
    await tap(t, find.text(l.btnStart));
    await tap(t, find.textContaining('/dev/nvme0n1'));
    await next(t);
    // 21668 MiB = 21.2 GiB —— 来自 gk3_plan 的 PLANERR need_mib，不是界面写死的
    await see(t, find.textContaining('至少需要 ${fmtMib(21668)}'));
    expect(find.text(l.modeAlongOk), findsNothing);
    await tap(t, find.text(l.modeShrinkTitle));
    await next(t);
    await see(t, find.text(l.shrinkTitle));
    await tap(t, find.textContaining('Data'));
    await hold(t, l.shrinkGo);
    // 缩完回到方式页：场景已经换成 windows-free，双系统可行、并且替用户选上了
    await see(t, find.text(l.modeTitle));
    await see(t, find.text(l.modeAlongOk));
  });

  testWidgets('blank：整盘安装；确认页如实说"没有任何分区"', (t) async {
    final rec = await pumpApp(t, 'blank');
    await tap(t, find.text(l.btnStart));
    await tap(t, find.textContaining('/dev/nvme0n1'));
    await next(t);
    // 空盘没有 ESP：双系统禁用并写明原因
    await see(t, find.text(l.modeWhyNoEsp));
    await tap(t, find.text(l.modeWipeTitle));
    await next(t);
    await next(t); // 来源：U 盘
    await next(t); // 选项
    await see(t, find.text(l.confirmWipeHead));
    await see(t, find.text(l.confirmNoParts));
    await hold(t, l.confirmHoldIdle);
    await see(t, find.text(l.doneTitle));
    expect(rec.last('gk3_apply')!.join(' '), contains('--mode wipe'));
  });

  testWidgets('android（已经装过）：双系统禁用，原因里列出冲突的分区名', (t) async {
    await pumpApp(t, 'android');
    await tap(t, find.text(l.btnStart));
    await tap(t, find.textContaining('/dev/nvme0n1'));
    await next(t);
    await see(t, find.textContaining('super'), findsWidgets);
    expect(find.text(l.modeAlongOk), findsNothing);
  });

  testWidgets('预检：BIOS 2.17 与安全启动 → 拦住；说"没有验证过"，不说"不兼容"', (t) async {
    await pumpApp(t, 'blank', overrides: {'gk3_preflight': 'preflight-bios217.txt'});
    await see(t, find.text(l.checkBlocked));
    await see(t, find.text(l.checkBiosBad('2.17')));
    await see(t, find.text(l.checkSecurebootBad));
    final btn = t.widget<ButtonStyleButton>(find.ancestor(of: find.text(l.btnStart), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)).first);
    expect(btn.onPressed, isNull);
  });

  testWidgets('返回走的是真正来的那一页（C 版 screen-- 会掉进没走过的缩分区页）', (t) async {
    await pumpApp(t, 'windows-free');
    await tap(t, find.text(l.btnStart));
    await tap(t, find.textContaining('/dev/nvme0n1'));
    await next(t);
    await tap(t, find.text(l.modeAlongTitle));
    await next(t);
    await see(t, find.text(l.sourceTitle));
    await tap(t, find.text(l.btnBack));
    await see(t, find.text(l.modeTitle));
    expect(find.text(l.shrinkTitle), findsNothing);
  });

  testWidgets('WiFi 两步式：软键盘输密码，短于 8 位不许连；连上后选版本；网络安装先下载再 apply', (t) async {
    final rec = await pumpApp(t, 'windows-free', overrides: {'gk3_release_info': 'release_info-none.txt'});
    await tap(t, find.text(l.btnStart));
    await tap(t, find.textContaining('/dev/nvme0n1'));
    await next(t);
    await tap(t, find.text(l.modeAlongTitle));
    await next(t);
    // U 盘里没有镜像：U 盘那张禁用并写明原因，自动选到网络
    await see(t, find.text(l.sourceUsbMissing));
    await next(t);
    await see(t, find.text(l.netTitle));
    await see(t, find.text('宿舍网-5G'));
    await see(t, find.text(l.netEnterprise)); // eduroam
    await tap(t, find.text('宿舍网-5G'));
    await see(t, find.text(l.netPasswordFor('宿舍网-5G')));
    for (final k in 'abc'.split('')) {
      await tap(t, find.text(k));
    }
    await see(t, find.text(l.netPasswordLength));
    for (final k in 'defgh'.split('')) {
      await tap(t, find.text(k));
    }
    expect(find.text(l.netPasswordLength), findsNothing);
    await tap(t, find.text(l.netConnect));
    expect(rec.last('gk3_wifi_connect'), ['gk3_wifi_connect', 'hex:e5aebfe8888de7bd912d3547', 'abcdefgh']);
    await see(t, find.textContaining('已连接到 宿舍网-5G（192.168.10.239）'));
    await next(t);
    await see(t, find.text(l.variantTitle));
    await tap(t, find.text('标准版'));
    await next(t);
    await next(t); // 选项
    await hold(t, l.confirmHoldIdle);
    await see(t, find.text(l.doneTitle));
    final dl = rec.last('gk3_net_release')!;
    expect(dl[1], startsWith('https://ota.072172.xyz/install/'));
    expect(dl[2], netPayloadDir);
    expect(rec.last('gk3_apply')!.join(' '), contains('--release $netPayloadDir'));
    // 下载在 apply 之前
    expect(rec.calls.indexWhere((c) => c.first == 'gk3_net_release'), lessThan(rec.calls.indexWhere((c) => c.first == 'gk3_apply')));
  });

  testWidgets('安装失败：失败页给出错误、说明分区表有备份、不许返回', (t) async {
    await pumpApp(t, 'blank', failApply: true);
    await tap(t, find.text(l.btnStart));
    await tap(t, find.textContaining('/dev/nvme0n1'));
    await next(t);
    await tap(t, find.text(l.modeWipeTitle));
    await next(t);
    await next(t);
    await next(t);
    await hold(t, l.confirmHoldIdle);
    await see(t, find.text(l.failTitle));
    await see(t, find.textContaining('分区 super 没解析出来'), findsWidgets);
    await see(t, find.text(l.failBackup));
    expect(find.text(l.btnBack), findsNothing);
  });
}
