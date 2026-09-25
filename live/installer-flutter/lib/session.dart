// 一次安装的全部状态：用户的选择 + 从后端问来的事实。
//
// ★ 每一个"能不能 / 够不够 / 多大"都来自后端的一次调用，这里只是记下来、组合起来。
//   例如"双系统要多少空间"：C 版写死了"不足 20.2 GiB"（strings.zh.txt 的 MODE.WHY.NOROOM），
//   这里用一个空区间去问 gk3_plan，让它在 PLANERR need_mib= 里自己报出来 ——
//   installer-lib.sh 里的常量一改，界面上的数字跟着变。
import 'package:flutter/foundation.dart';

import 'backend/backend.dart';
import 'backend/protocol.dart';
import 'model/model.dart';

/// reinstall：盘上已经有我们的 Android 时，复用现有分区重新安装（用户 2026-09-25）
enum Mode { wipe, alongside, reinstall }

enum Source { usb, net }

/// 双系统可不可行、不可行的原因（方式页据此"禁用 + 写明原因"，而不是藏起来）
sealed class Along {
  const Along();
}

class AlongOk extends Along {
  const AlongOk(this.region, this.esp, this.windows);
  final FreeRegion region;
  final Part esp;
  final bool windows;
}

class AlongNoEsp extends Along {
  const AlongNoEsp();
}

class AlongEspSmall extends Along {
  const AlongEspSmall(this.freeMib, this.needMib);
  final int freeMib, needMib;
}

class AlongInstalled extends Along {
  const AlongInstalled(this.names);

  /// 冲突的分区名（gk3_plan 的 PLANERR partlabel-conflict names=）；
  /// 空串 = 分区名不冲突、但这个 ESP 上已经有 gaokun3 的启动项
  final String names;
}

class AlongNoRoom extends Along {
  const AlongNoRoom(this.haveMib, this.needMib);
  final int haveMib;
  final int? needMib;
}

class AlongMbr extends Along {
  const AlongMbr();
}

class AlongError extends Along {
  const AlongError(this.msg);
  final String msg;
}

/// /run 是 tmpfs：1.2 GiB 的 super.img.zst 放得下，展开是流式写盘的（gk3_net_release 的注释）
const netPayloadDir = '/run/gaokun3/payload';

class Session extends ChangeNotifier {
  Session(this.backend);
  final Gk3Backend backend;

  void _changed() => notifyListeners();

  // ── 语言 ────────────────────────────────────────────────────────────────
  String language = 'zh';
  void toggleLanguage() {
    language = language == 'zh' ? 'en' : 'zh';
    _changed();
  }

  // ── 预检与安装介质 ─────────────────────────────────────────────────────
  List<Check>? checks;
  Release? usbRelease;
  bool get blocked => checks?.any((c) => c.state == CheckState.fail) ?? false;

  Future<void> start() async {
    checks = (await backend.run('gk3_preflight')).ofType('CHECK').map(Check.new).toList();
    final r = (await backend.run('gk3_release_info')).first('RELEASE');
    usbRelease = r == null ? null : Release(r);
    _changed();
  }

  // ── 盘 ──────────────────────────────────────────────────────────────────
  List<Disk>? disks;
  String? probeError;

  Future<void> probe() async {
    disks = null;
    probeError = null;
    _changed();
    final r = await backend.run('gk3_probe');
    disks = Disk.fromProbe(r);
    if (!r.ok) probeError = r.error ?? 'exit ${r.exitCode}';
    _changed();
  }

  Disk? disk;
  Along? along;

  /// 重新安装的可行性：盘上有我们的分区时才问（null = 这块盘上没有我们的 Android，不出这一项）。
  /// 用 gk3_plan --mode reinstall 问，不在界面里自己判 —— 缺哪个分区、哪个太小都是它报的
  Plan? reinstall;
  EspInfo? espInfo;
  List<Shrinkable>? shrinkables;
  bool assessing = false;

  /// 选定一块盘：把两种方式能不能走都问清楚
  Future<void> assess(Disk d) async {
    disk = d;
    mode = null;
    plan = null;
    userdataMib = null;
    along = null;
    reinstall = null;
    espInfo = null;
    shrinkables = null;
    assessing = true;
    _changed();
    along = await _assessAlong(d);
    if (d.parts.any((p) => const {'super', 'userdata', 'boot_a', 'boot_b'}.contains(p.name))) {
      reinstall = Plan(await backend.run('gk3_plan', _reinstallArgs(d, keep: false)));
    }
    // 双系统因为空间不够走不通时，才需要知道能不能缩
    if (along is AlongNoRoom) {
      shrinkables = (await backend.run('gk3_shrink_scan', [d.path])).ofType('SHRINK').map(Shrinkable.new).toList();
    }
    assessing = false;
    _changed();
  }

  Future<Along> _assessAlong(Disk d) async {
    final esp = d.esp;
    if (esp == null) return const AlongNoEsp();
    final er = (await backend.run('gk3_esp_info', [esp.path])).first('ESP');
    if (er != null) espInfo = EspInfo(er);
    final info = espInfo;
    if (info != null && !info.roomy && !info.ours) return AlongEspSmall(info.freeMib, info.needMib);
    final f = d.largestFree;
    // 没有空闲区也问一次（空区间）：让 gk3_plan 自己报"至少要多少"
    final p = Plan(await backend.run('gk3_plan', [
      '--disk', d.path, '--mode', 'alongside', '--rescue', rescue ? 'yes' : 'no',
      '--region-start', '${f?.start ?? 0}', '--region-end', '${f?.end ?? 0}', '--esp', esp.path,
    ]));
    if (p.ok && f != null) return AlongOk(f, esp, info?.windows ?? false);
    final e = p.error;
    // ESP 上已经有我们的启动项、而分区名又不冲突（Android 装在另一块盘上、共用这个 ESP）：
    // 再装一份会覆盖那边的启动项 —— 同样拦住
    if (e?['msg'] != 'partlabel-conflict' && info != null && info.ours) return const AlongInstalled('');
    return switch (e?['msg']) {
      'partlabel-conflict' => AlongInstalled(e!['names']),
      'mbr-disk' => const AlongMbr(),
      'not-enough-space' => AlongNoRoom(e!.intOf('avail_mib'), e.intOf('need_mib')),
      _ when f == null => AlongNoRoom(0, null),
      _ => AlongError(e?['msg'] ?? 'unknown'),
    };
  }

  bool get canShrink => shrinkables?.any((s) => s.can) ?? false;

  // ── 手动调整磁盘 ────────────────────────────────────────────────────────
  /// 调整大小要知道每个分区最小能缩到多少：问 gk3_shrink_scan（文件系统自己报，不猜）
  Future<void> scanShrink() async {
    final d = disk;
    if (d == null) return;
    shrinkables = (await backend.run('gk3_shrink_scan', [d.path])).ofType('SHRINK').map(Shrinkable.new).toList();
    _changed();
  }

  /// 执行一个调整操作（gk3_part_delete / format / create / resize）。成功与否都重新探测这块盘 ——
  /// 分区号、空闲区都可能变了，界面上显示的必须是盘上【现在】的样子
  Future<CallResult> editDisk(String fn, List<String> args, void Function(Gk3Event) onEvent) async {
    final r = await backend.run(fn, args, onEvent);
    await probe();
    final again = disks?.where((x) => x.path == disk?.path).firstOrNull;
    if (again != null) disk = again;
    await scanShrink();
    return r;
  }

  // ── 缩分区 ──────────────────────────────────────────────────────────────
  Future<CallResult> shrink(Shrinkable s, int targetMib, void Function(Gk3Event) onEvent) async {
    final r = await backend.run('gk3_shrink', [s.part, '$targetMib'], onEvent);
    if (r.ok) {
      await probe();
      final again = disks?.where((d) => d.path == disk?.path).firstOrNull;
      if (again != null) await assess(again);
    }
    return r;
  }

  // ── 方式与选项 ──────────────────────────────────────────────────────────
  Mode? mode;
  bool rescue = true;
  int? userdataMib; // null = 剩下的全给 /data
  Plan? plan;
  bool planning = false;

  bool get rescueAvailable => usbRelease?.rescue ?? false;

  /// 重新安装时 /data 留不留。默认清除（用户 2026-09-25 定的）：换到更旧的版本时，留下的数据可能起不来
  bool keepData = false;

  /// 重新安装只重写【已有的】救援分区；没有这个分区就不装（不改分区表）
  bool get _diskHasRescue => disk?.parts.any((p) => p.name == 'gk3rescue') ?? false;
  bool get rescueUsable => rescueAvailable && (mode != Mode.reinstall || _diskHasRescue);

  List<String> _reinstallArgs(Disk d, {required bool keep}) => [
        '--disk', d.path, '--mode', 'reinstall',
        '--rescue', rescue && rescueAvailable && d.parts.any((p) => p.name == 'gk3rescue') ? 'yes' : 'no',
        '--esp', d.esp?.path ?? '', '--keep-data', keep ? 'yes' : 'no',
      ];

  Future<void> setKeepData(bool v) async {
    keepData = v;
    await computePlan();
  }

  void setMode(Mode m) {
    mode = m;
    plan = null;
    _changed();
  }

  List<String> _planArgs() {
    final d = disk!;
    if (mode == Mode.reinstall) return _reinstallArgs(d, keep: keepData);
    final a = ['--disk', d.path, '--mode', mode == Mode.wipe ? 'wipe' : 'alongside', '--rescue', rescue && rescueAvailable ? 'yes' : 'no'];
    final al = along;
    if (mode == Mode.alongside && al is AlongOk) {
      a.addAll(['--region-start', '${al.region.start}', '--region-end', '${al.region.end}', '--esp', al.esp.path]);
    }
    if (userdataMib != null) a.addAll(['--userdata-mib', '$userdataMib']);
    return a;
  }

  Future<void> computePlan() async {
    if (disk == null || mode == null) return;
    planning = true;
    _changed();
    plan = Plan(await backend.run('gk3_plan', _planArgs()));
    planning = false;
    _changed();
  }

  /// 专业分区页：/data 的最大值 = 默认方案里给它的全部
  int? maxUserdataMib;

  Future<void> setRescue(bool v) async {
    rescue = v;
    userdataMib = null;
    await computePlan();
    maxUserdataMib = plan?.ok == true ? plan!.userdataMib : null;
  }

  Future<void> setUserdata(int? mib) async {
    userdataMib = mib;
    await computePlan();
  }

  // ── 来源 ────────────────────────────────────────────────────────────────
  Source source = Source.usb;
  void setSource(Source s) {
    source = s;
    _changed();
  }

  Gk3Record? net;
  List<Ap>? aps;
  bool scanning = false;

  Future<void> scanWifi() async {
    scanning = true;
    _changed();
    final st = await backend.run('gk3_net_status');
    net = st.first('NET');
    aps = (await backend.run('gk3_wifi_scan')).ofType('WIFI').map(Ap.new).toList();
    scanning = false;
    _changed();
  }

  bool get online => net?.yes('online') ?? false;

  Future<CallResult> connect(Ap ap, String password, void Function(Gk3Event) onEvent) async {
    final r = await backend.run('gk3_wifi_connect', ['hex:${ap.ssidHex}', password], onEvent);
    if (r.ok) net = r.first('NET');
    _changed();
    return r;
  }

  List<Variant>? variants;
  String? variantsError;
  Variant? variant;

  Future<void> fetchVariants() async {
    variants = null;
    variantsError = null;
    _changed();
    final r = await backend.run('gk3_net_manifest');
    if (r.ok) {
      variants = r.ofType('VARIANT').map(Variant.new).toList();
    } else {
      variantsError = r.error ?? 'exit ${r.exitCode}';
    }
    _changed();
  }

  void setVariant(Variant v) {
    variant = v;
    _changed();
  }

  // ── 安装 ────────────────────────────────────────────────────────────────
  /// 网络安装先下载（占总进度 0–40%），再走和 U 盘安装完全相同的 gk3_apply
  Stream<Gk3Event> install() async* {
    var rel = usbRelease?.dir ?? '';
    final net = source == Source.net;
    if (net) {
      var ok = false;
      await for (final e in backend.call('gk3_net_release', [variant!.base, netPayloadDir])) {
        if (e is Gk3Progress) {
          yield Gk3Progress(e.percent * 40 ~/ 100, e.text);
        } else if (e is Gk3Exit) {
          ok = e.code == 0;
          if (!ok) {
            yield e;
            return;
          }
        } else {
          yield e;
        }
      }
      if (!ok) return;
      rel = netPayloadDir;
    }
    final args = ['--release', rel, ..._planArgs()];
    await for (final e in backend.call('gk3_apply', args)) {
      yield (net && e is Gk3Progress) ? Gk3Progress(40 + e.percent * 60 ~/ 100, e.text) : e;
    }
  }
}
