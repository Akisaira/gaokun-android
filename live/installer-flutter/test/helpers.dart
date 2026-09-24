// 流程测试与出图共用的辅助。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gk3_installer/app.dart';
import 'package:gk3_installer/backend/backend.dart';
import 'package:gk3_installer/backend/fixture_backend.dart';
import 'package:gk3_installer/backend/protocol.dart';
import 'package:gk3_installer/l10n/app_localizations.dart';
import 'package:gk3_installer/session.dart';

/// 包一层 FixtureBackend：记下每一次调用；可以让某个函数失败
class Rec extends Gk3Backend {
  Rec(this.inner, {this.failApply = false});
  final FixtureBackend inner;
  final bool failApply;
  final calls = <List<String>>[];

  @override
  String? get demoLabel => inner.demoLabel;

  @override
  Stream<Gk3Event> call(String fn, [List<String> args = const []]) async* {
    calls.add([fn, ...args]);
    if (fn == 'gk3_apply' && failApply) {
      yield const Gk3Progress(5, '写分区表');
      yield const Gk3Log('分区表已备份到 /media/gk3/gaokun3/gpt-backup-nvme0n1-1.bin（还原：sgdisk --load-backup=/media/gk3/gaokun3/gpt-backup-nvme0n1-1.bin /dev/nvme0n1）');
      yield const Gk3Log('!! 分区 super 没解析出来（/dev/nvme0n1 上找不到这个 PARTLABEL）');
      yield const Gk3Exit(1);
      return;
    }
    yield* inner.call(fn, args);
  }

  List<String>? last(String fn) => calls.lastWhere((c) => c.first == fn, orElse: () => const []).isEmpty
      ? null
      : calls.lastWhere((c) => c.first == fn);

  @override
  Future<void> reboot() async {}
  @override
  Future<void> openShell() async {}
}

final l = lookupL10n(const Locale('zh'));

/// 直接同步读磁盘的资源包。
/// ★ 不用 rootBundle：它缓存 loadString 的 Future，而资源读取在测试里是真实异步 I/O ——
///   上一个测试结束时还在飞的那次读取挂在它的 FakeAsync 区里、永远完成不了，被缓存下来，
///   下一个测试 await 它就永远等下去（第一版：单独跑全过、一起跑 7 条挂 6 条）。
class DiskBundle extends AssetBundle {
  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(File(key).readAsBytesSync());
  @override
  Future<String> loadString(String key, {bool cache = true}) async => File(key).readAsStringSync();
  @override
  Future<T> loadStructuredData<T>(String key, Future<T> Function(String value) parser) async => parser(await loadString(key));
}

Future<Rec> pumpApp(WidgetTester t, String scenario,
    {Map<String, String> overrides = const {}, bool failApply = false, double speed = 0, String language = 'zh'}) async {
  t.view.physicalSize = const Size(1280, 800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final rec = Rec(FixtureBackend(scenario, bundle: DiskBundle(), speed: speed, overrides: overrides), failApply: failApply);
  final session = Session(rec)..language = language;
  await t.pumpWidget(InstallerApp(session: session));
  await settle(t);
  return rec;
}

/// 页面上常有转圈（永不停的动画），pumpAndSettle 等不到头；而 fixture 是从资源里读文件，
/// 那是真实的异步 I/O —— 所以【等到目标出现】，不按固定步数赌时序
/// （按固定步数写的第一版：单独跑全过、一起跑一半失败）。
Future<void> waitFor(WidgetTester t, Finder f, {int tries = 150, Duration step = const Duration(milliseconds: 20)}) async {
  for (var i = 0; i < tries && f.evaluate().isEmpty; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pump(step);
  }
}

Future<void> settle(WidgetTester t, [int n = 20]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await t.pump(const Duration(milliseconds: 40));
  }
}

/// 断言某个东西出现（先等它）
Future<void> see(WidgetTester t, Finder f, [Matcher m = findsOneWidget]) async {
  await waitFor(t, f);
  expect(f, m);
}

Future<void> tap(WidgetTester t, Finder f) async {
  await waitFor(t, f);
  await t.ensureVisible(f.first);
  await t.tap(f.first, warnIfMissed: false);
  await settle(t);
}

Future<void> next(WidgetTester t) async {
  // "下一步"要等到它可点（方案还在算的时候是禁用的）
  final f = find.ancestor(of: find.text(l.btnNext), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton && w.onPressed != null));
  await tap(t, f);
}

/// 按住 2 秒（确认页 / 缩分区）
Future<void> hold(WidgetTester t, String idleText) async {
  final g = await t.startGesture(t.getCenter(find.textContaining(idleText).first));
  for (var i = 0; i < 25; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  await g.up();
  await settle(t, 60);
}

