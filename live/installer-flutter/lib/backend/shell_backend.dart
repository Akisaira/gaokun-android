import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'backend.dart';
import 'protocol.dart';

/// 真后端：`bash -c '. "$0" && "$@"' <installer-lib.sh> <函数> <参数…>`
///
/// ⚠️★ 参数【不拼进 shell 字符串】，走位置参数。否则一个含单引号或 `$(…)` 的
///    WiFi 密码 / SSID 就是一次命令注入 —— 而这个进程是 root。
///
/// ★ 每次调用的参数、stderr、stdout 记录与退出码都照抄一份到 [log]（默认是本进程的 stderr ——
///   gk3-installer-session 把它接到介质上的 diag/installer.log）。2026-09-26 M4b 第一次真装：
///   装成了，但事后在介质上找不到 gk3_apply 的任何一行输出（只在屏幕上的日志区里出现过）——
///   装坏的那一次要是也这样，就只剩"屏幕上好像报了个错"。
class ShellBackend extends Gk3Backend {
  ShellBackend(this.libPath, {IOSink? log}) : _log = log ?? stderr;
  final IOSink _log;

  /// 写进日志时要遮住的参数：WiFi 密码（gk3_wifi_connect 的第二个）
  static List<String> redact(String fn, List<String> args) => [
        for (var i = 0; i < args.length; i++) fn == 'gk3_wifi_connect' && i == 1 && args[i].isNotEmpty ? '<密码 ${args[i].length} 个字符>' : args[i],
      ];

  /// 找库：GK3_LIB 环境变量 → live 镜像里的位置 → 仓库里（在 Linux 开发机上直接跑）
  static ShellBackend? locate() {
    final candidates = [
      Platform.environment['GK3_LIB'],
      '/usr/share/gaokun3/installer-lib.sh',
      '${Directory.current.path}/../../scripts/live/installer-lib.sh',
    ];
    for (final c in candidates) {
      if (c != null && File(c).existsSync()) return ShellBackend(File(c).absolute.path);
    }
    return null;
  }

  final String libPath;

  @override
  Stream<Gk3Event> call(String fn, [List<String> args = const []]) {
    final ctl = StreamController<Gk3Event>();
    final t0 = DateTime.now();
    String ts() => DateTime.now().toIso8601String().substring(11, 19);
    _log.writeln('[${ts()}] >> $fn ${redact(fn, args).join(' ')}'.trimRight());
    () async {
      final Process p;
      try {
        p = await Process.start('bash', ['-c', r'. "$0" && "$@"', libPath, fn, ...args]);
      } on ProcessException catch (e) {
        _log.writeln('[${ts()}] << $fn 起不来 bash：${e.message}');
        ctl.add(Gk3Log('!! 起不来 bash：${e.message}'));
        ctl.add(const Gk3Exit(127));
        await ctl.close();
        return;
      }
      const dec = Utf8Decoder(allowMalformed: true);
      final out = p.stdout.transform(dec).transform(const LineSplitter()).listen((l) {
        _log.writeln('   | $l');
        ctl.add(parseStdoutLine(l));
      }).asFuture<void>();
      final err = p.stderr.transform(dec).transform(const LineSplitter()).listen((l) {
        _log.writeln('   $l');
        ctl.add(parseStderrLine(l));
      }).asFuture<void>();
      await Future.wait([out, err]);
      final code = await p.exitCode;
      _log.writeln('[${ts()}] << $fn exit $code（${DateTime.now().difference(t0).inMilliseconds / 1000} 秒）');
      ctl.add(Gk3Exit(code));
      await ctl.close();
    }();
    return ctl.stream;
  }

  @override
  Future<void> reboot() async {
    _log.writeln('[${DateTime.now().toIso8601String().substring(11, 19)}] 重启');
    await _log.flush();
    await Process.run('sync', const []);
    await Process.run('reboot', const []);
  }

  /// 命令行逃生口：切到 tty2（那里有 getty）。C 版是 system("chvt 2")（gk3-installer.c:1288；C 版已删，git show 445e978:live/installer/gk3-installer.c）。
  /// ⚠️★ 2026-09-25 M0 实测：Debian 镜像里【没有 chvt】（它在 kbd 包里，没装）—— 按钮点了什么都不发生，
  ///   日志里只有一条没人接的 ProcessException。现在：镜像里 chvt 链到 busybox（overlay-common），
  ///   这里再退一步直接调 busybox；都不行就把原因交给界面说出来。
  @override
  Future<String?> openShell() async {
    String? why;
    for (final (cmd, args) in const [('chvt', ['2']), ('busybox', ['chvt', '2'])]) {
      try {
        final r = await Process.run(cmd, args);
        if (r.exitCode == 0) return null;
        why = '$cmd: ${'${r.stderr}'.trim().isEmpty ? 'exit ${r.exitCode}' : '${r.stderr}'.trim()}';
      } on ProcessException catch (e) {
        why = '$cmd: ${e.message}';
      }
    }
    return why;
  }
}
