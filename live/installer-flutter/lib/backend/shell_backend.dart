import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'backend.dart';
import 'protocol.dart';

/// 真后端：`bash -c '. "$0" && "$@"' <installer-lib.sh> <函数> <参数…>`
///
/// ⚠️★ 参数【不拼进 shell 字符串】，走位置参数。否则一个含单引号或 `$(…)` 的
///    WiFi 密码 / SSID 就是一次命令注入 —— 而这个进程是 root。
class ShellBackend extends Gk3Backend {
  ShellBackend(this.libPath);

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
    () async {
      final Process p;
      try {
        p = await Process.start('bash', ['-c', r'. "$0" && "$@"', libPath, fn, ...args]);
      } on ProcessException catch (e) {
        ctl.add(Gk3Log('!! 起不来 bash：${e.message}'));
        ctl.add(const Gk3Exit(127));
        await ctl.close();
        return;
      }
      const dec = Utf8Decoder(allowMalformed: true);
      final out = p.stdout.transform(dec).transform(const LineSplitter())
          .listen((l) => ctl.add(parseStdoutLine(l))).asFuture<void>();
      final err = p.stderr.transform(dec).transform(const LineSplitter())
          .listen((l) => ctl.add(parseStderrLine(l))).asFuture<void>();
      await Future.wait([out, err]);
      ctl.add(Gk3Exit(await p.exitCode));
      await ctl.close();
    }();
    return ctl.stream;
  }

  @override
  Future<void> reboot() async {
    await Process.run('sync', const []);
    await Process.run('reboot', const []);
  }

  /// 命令行逃生口：切到 tty2（那里有 getty）。C 版是 system("chvt 2")（gk3-installer.c:1288）。
  /// ⚠️ 在 cage（wlroots）下还成不成立要真机验 —— 见 docs/stage7-flutter-debian.md M0。
  @override
  Future<void> openShell() async {
    await Process.run('chvt', const ['2']);
  }
}
