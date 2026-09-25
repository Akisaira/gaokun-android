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

  testWidgets('windows-live（免 U 盘装双系统）：安装器跑在内置盘上 → 盘可选、整盘清空禁用、双系统一路装完', (t) async {
    final rec = await pumpApp(t, 'windows-live');
    await tap(t, find.text(l.btnStart));
    await see(t, find.text(l.diskTitle));
    // 没有 U 盘；内置盘就是介质 —— 不禁用，只提示"只能装在空闲空间里"
    expect(find.text(l.diskMedium), findsNothing);
    await see(t, find.text(l.diskMediumInternal));
    await tap(t, find.textContaining('/dev/nvme0n1'));
    await next(t);
    await see(t, find.text(l.modeTitle));
    await see(t, find.text(l.modeWhyMedium));
    // 点"清除整个磁盘"没反应：下一步仍是灰的
    await tap(t, find.text(l.modeWipeTitle));
    expect(find.ancestor(of: find.text(l.btnNext), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton && w.onPressed != null)), findsNothing);
    await see(t, find.text(l.modeAlongOk));
    await tap(t, find.text(l.modeAlongTitle));
    await next(t);
    await next(t); // 来源
    await next(t); // 选项
    await see(t, find.text(l.confirmAlongHead));
    await see(t, find.text(l.confirmWindowsKept));
    await hold(t, l.confirmHoldIdle);
    await see(t, find.text(l.doneTitle));
    final a = rec.last('gk3_apply')!.join(' ');
    expect(a, contains('--mode alongside'));
    expect(a, contains('--region-start 798885888 --region-end 958269439'));   // GK3LIVE 之后那段空闲
    expect(a, contains('--esp /dev/nvme0n1p1'));
  });

  testWidgets('退出到终端切不过去：SnackBar 说出原因与替代办法（M0 实测：镜像里没有 chvt，按钮点了没反应）', (t) async {
    await pumpApp(t, 'windows-free', shellError: 'busybox: No such file or directory');
    await tap(t, find.text(l.btnQuit));
    await see(t, find.textContaining('Ctrl+Alt+F2'));
    await see(t, find.textContaining('busybox: No such file or directory'));
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

  testWidgets('android（已经装过）→ 重新安装：默认清除数据，确认页逐个列出，apply 走 reinstall', (t) async {
    final rec = await pumpApp(t, 'android');
    await tap(t, find.text(l.btnStart));
    await tap(t, find.textContaining('/dev/nvme0n1'));
    await next(t);
    await see(t, find.text(l.modeReinstallTitle));
    await tap(t, find.text(l.modeReinstallTitle));
    await next(t); // 来源
    await next(t); // → 选项
    await see(t, find.text(l.optsKeepTitle));
    expect(find.text(l.optsAdvanced), findsNothing);   // 不改分区表：没有分区大小可调
    await see(t, find.textContaining('/data 将被清空'));
    await next(t);
    await see(t, find.text(l.confirmReinstallHead));
    await see(t, find.text(l.actFormat), findsNWidgets(2));   // userdata、metadata
    await see(t, find.text(l.actWrite), findsNWidgets(5));    // misc、boot_a、boot_b、super、gk3rescue
    await hold(t, l.confirmHoldIdle);
    await see(t, find.text(l.doneTitle));
    final a = rec.last('gk3_apply')!.join(' ');
    expect(a, contains('--mode reinstall'));
    expect(a, contains('--keep-data no'));
    expect(a, contains('--esp /dev/nvme0n1p1'));
    expect(a, isNot(contains('--region-start')));
  });

  testWidgets('重新安装 + 保留数据：确认页写"保留"，apply 带 --keep-data yes', (t) async {
    final rec = await pumpApp(t, 'android');
    await tap(t, find.text(l.btnStart));
    await tap(t, find.textContaining('/dev/nvme0n1'));
    await next(t);
    await tap(t, find.text(l.modeReinstallTitle));
    await next(t);
    await next(t);
    await tap(t, find.text(l.optsKeepTitle));
    await see(t, find.textContaining('/data 保留'));
    await next(t);
    await see(t, find.text(l.actKeep), findsNWidgets(2));
    await hold(t, l.confirmHoldIdle);
    await see(t, find.text(l.doneTitle));
    expect(rec.last('gk3_apply')!.join(' '), contains('--keep-data yes'));
  });

  Future<Rec> openEdit(WidgetTester t, String scenario, {Map<String, String> overrides = const {}}) async {
    final rec = await pumpApp(t, scenario, overrides: overrides);
    await tap(t, find.text(l.btnStart));
    await tap(t, find.textContaining('/dev/nvme0n1'));
    await next(t);
    await tap(t, find.text(l.editEntryTitle));
    await next(t);
    await see(t, find.text(l.editTitle));
    return rec;
  }

  testWidgets('调整磁盘：删除一个分区 —— 按住确认，调用对，完成后回到安装方式页重新评估', (t) async {
    final rec = await openEdit(t, 'factory');
    await tap(t, find.textContaining('Onekey'));
    await tap(t, find.text(l.editDelete));
    await see(t, find.text(l.editDeleteWarn));
    await hold(t, '${l.editDelete} · ${l.holdIdle}');
    expect(rec.last('gk3_part_delete'), ['gk3_part_delete', '/dev/nvme0n1p6']);
    await see(t, find.textContaining('已完成'));
    final probes = rec.calls.where((c) => c.first == 'gk3_probe').length;
    await tap(t, find.text(l.editDone)); // 右下角"完成" → 回到方式页
    await see(t, find.text(l.modeTitle));
    expect(rec.calls.where((c) => c.first == 'gk3_plan').isNotEmpty, isTrue);
    expect(rec.calls.where((c) => c.first == 'gk3_probe').length, greaterThanOrEqualTo(probes));
  });

  testWidgets('调整磁盘：ESP 只说原因、不给操作', (t) async {
    await openEdit(t, 'factory');
    await tap(t, find.textContaining('SYSTEM'));
    await see(t, find.text(l.editWhyEsp));
    expect(find.text(l.editDelete), findsNothing);
    expect(find.text(l.editFormat), findsNothing);
  });

  testWidgets('调整磁盘：在空闲空间新建 —— 默认占满整段、ext4', (t) async {
    final rec = await openEdit(t, 'windows-free');
    await tap(t, find.text(l.editFree));
    await tap(t, find.text(l.editCreate));
    await hold(t, '${l.editCreate} · ${l.holdIdle}');
    final a = rec.last('gk3_part_create')!;
    expect(a.join(' '), contains('--disk /dev/nvme0n1 --start 790497280'));
    expect(a.join(' '), contains('--size-mib 81920'));   // 空闲区 [790497280, 958269439] 起点本来就对齐 1 MiB：整段正好 81920 MiB
    expect(a.join(' '), contains('--fs ext4'));
  });

  testWidgets('调整磁盘：拖滑块缩小 Data，发出去的目标比现在小', (t) async {
    final rec = await openEdit(t, 'factory');
    await tap(t, find.textContaining('Data'));
    await tap(t, find.text(l.editResize));
    await t.drag(find.byType(Slider), const Offset(-120, 0));
    await settle(t);
    await hold(t, '${l.editResize} · ${l.holdIdle}');
    final a = rec.last('gk3_part_resize')!;
    expect(a[1], '/dev/nvme0n1p4');
    expect(int.parse(a[2]), lessThan(262788 + 1));   // Data 在 factory 里是 262788 MiB
  });

  testWidgets('调整磁盘：后端拒绝时把原因显示出来', (t) async {
    await openEdit(t, 'factory', overrides: {'gk3_part_delete': 'part_delete-esp.txt'});
    await tap(t, find.textContaining('Onekey'));
    await tap(t, find.text(l.editDelete));
    await hold(t, '${l.editDelete} · ${l.holdIdle}');
    await see(t, find.textContaining('EFI 系统分区'));
  });

  testWidgets('预检：BIOS 2.17 不再拦（2026-09-25）；安全启动开着 → 拦住', (t) async {
    await pumpApp(t, 'blank', overrides: {'gk3_preflight': 'preflight-secureboot.txt'});
    await see(t, find.text(l.checkBlocked));
    await see(t, find.text('2.17'));   // 版本号照样显示（bug 报告要它），但不是失败项
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
