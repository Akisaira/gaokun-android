// ShellBackend：参数走位置参数、事件分流、以及照抄到日志（2026-09-26 M4b：装完在介质上找不到 gk3_apply 的输出）。
// 要 bash —— Mac 与 Linux 都有。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gk3_installer/backend/protocol.dart';
import 'package:gk3_installer/backend/shell_backend.dart';

void main() {
  late Directory tmp;
  late File lib, logf;
  late IOSink log;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gk3-shell-');
    lib = File('${tmp.path}/lib.sh')
      ..writeAsStringSync(r'''
gk3_demo() { echo "REC n=${#1}"; echo "PROGRESS 50 一半" >&2; echo "arg:$1" >&2; return 3; }
gk3_wifi_connect() { echo "NET ssid=$1 online=yes"; }
''');
    logf = File('${tmp.path}/installer.log');
    log = logf.openWrite();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test(r'事件分流 + 退出码；参数里的 $(…) 与引号不被 shell 解释', () async {
    final b = ShellBackend(lib.path, log: log);
    final ev = await b.call('gk3_demo', [r"a'$(touch pwned)"]).toList();
    expect(ev.whereType<Gk3Record>().single['n'], '${r"a'$(touch pwned)".length}');
    expect(ev.whereType<Gk3Progress>().single.percent, 50);
    expect(ev.whereType<Gk3Log>().single.line, r"arg:a'$(touch pwned)");
    expect((ev.last as Gk3Exit).code, 3);
    expect(File('${tmp.path}/pwned').existsSync() || File('pwned').existsSync(), isFalse);
  });

  test('照抄到日志：调用、stdout 记录、stderr、退出码都在；WiFi 密码遮住', () async {
    final b = ShellBackend(lib.path, log: log);
    await b.call('gk3_demo', ['x']).toList();
    await b.call('gk3_wifi_connect', ['hex:6c6162', 'hunter42secret', 'hidden']).toList();
    await log.flush();
    await log.close();
    final t = logf.readAsStringSync();
    expect(t, contains('>> gk3_demo x'));
    expect(t, contains('   | REC n=1'));
    expect(t, contains('   PROGRESS 50 一半'));
    expect(t, contains('   arg:x'));
    expect(t, contains('<< gk3_demo exit 3'));
    expect(t, contains('>> gk3_wifi_connect hex:6c6162 <密码 14 个字符> hidden'));
    expect(t, isNot(contains('hunter42secret')));
  });
}
