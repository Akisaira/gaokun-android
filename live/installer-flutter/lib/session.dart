// 一次安装的全部状态：用户的选择 + 从后端问来的事实。
//
// ★ 每一个"能不能 / 够不够 / 多大"都来自后端的一次调用，这里只是记下来、组合起来。
//   例如"双系统要多少空间"：C 版写死了"不足 20.2 GiB"（strings.zh.txt 的 MODE.WHY.NOROOM），
//   这里用一个空区间去问 gk3_plan，让它在 PLANERR need_mib= 里自己报出来 ——
//   installer-lib.sh 里的常量一改，界面上的数字跟着变。
import 'dart:async';

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
  const AlongNoRoom(this.haveMib, this.needMib, [this.fixedMib]);
  final int haveMib;
  final int? needMib;

  /// 除 /data 之外要的固定开销（PLANERR fixed_mib；旧后端没有这个字段 → null）。
  /// 缩分区页拿它把默认值算成"/data 约 64 GiB"（v1.0 计划 GUI-20）
  final int? fixedMib;
}

class AlongMbr extends Along {
  const AlongMbr();
}

class AlongError extends Along {
  const AlongError(this.msg);
  final String msg;
}

/// 下载被取消时 install() 最后报的退出码（130 = 被信号打断的惯例）
const kCancelledExit = 130;

/// /run 是 tmpfs：1.2 GiB 的 super.img.zst 放得下，展开是流式写盘的（gk3_net_release 的注释）
const netPayloadDir = '/run/gaokun3/payload';

/// 安装走到哪一段了。失败页据此分两种（v1.0 计划 GUI-3）：下载阶段失败时盘一个字节都没动，
/// 可以重试（/run 里下好的部分留着、接着续传）或返回；写盘阶段失败才是"盘可能写了一半"
enum InstallStage { download, write }

/// 语言从哪来、选了存到哪（v1.0 计划 GUI-19）。真机上是 backend/platform_io.dart 的实现
/// （内核参数 gk3.lang= 与介质上的一个小文件）；测试与 Web 预览用 [LangPrefs.none]
abstract class LangPrefs {
  const LangPrefs();

  /// 用户上次在安装器里选的（记住的），没有 → null
  String? saved();

  /// 启动项给的默认（内核参数 gk3.lang=），没有 → null
  String? fromBoot();
  void save(String lang);

  static const LangPrefs none = _NoPrefs();
}

class _NoPrefs extends LangPrefs {
  const _NoPrefs();
  @override
  String? saved() => null;
  @override
  String? fromBoot() => null;
  @override
  void save(String lang) {}
}

/// 'en'、'en_US'、'zh-CN' → 'en' / 'zh'；不认识 → null
String? normalizeLang(String? v) {
  final t = v?.trim().toLowerCase() ?? '';
  if (t.startsWith('zh')) return 'zh';
  if (t.startsWith('en')) return 'en';
  return null;
}

class Session extends ChangeNotifier {
  /// 语言：记住的 > 启动项的 gk3.lang= > 中文。记住的排在前面：用户在这台机器上明确选过一次，
  /// 安装器重启（cage 拉起来）、回 Windows 关快速启动再回来，都该沿用；gk3.lang= 是第一次进来时的默认
  Session(this.backend, {LangPrefs prefs = LangPrefs.none})
      : _prefs = prefs,
        language = normalizeLang(prefs.saved()) ?? normalizeLang(prefs.fromBoot()) ?? 'zh';
  final Gk3Backend backend;
  final LangPrefs _prefs;

  void _changed() => notifyListeners();

  // ── 正在写盘 ────────────────────────────────────────────────────────────
  /// 安装、缩分区、手动调整磁盘在跑的时候为 true：侧栏的重启 / 关机据此禁用（v1.0 计划 GUI-3）
  bool get writing => _writing > 0;
  int _writing = 0;

  Future<T> _whileWriting<T>(Future<T> Function() f) async {
    _writing++;
    _changed();
    try {
      return await f();
    } finally {
      _writing--;
      _changed();
    }
  }

  // ── 语言 ────────────────────────────────────────────────────────────────
  String language;
  void toggleLanguage() {
    language = language == 'zh' ? 'en' : 'zh';
    _prefs.save(language);
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
    // 安装器就在这块盘上（免 U 盘安装）：它自己就留在开机菜单里，默认不再另建 gk3rescue（v1.0 计划 GUI-17）。
    // 用户在选项页仍可打开
    if (!identical(disk, d)) rescue = !d.medium;
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
      'not-enough-space' => AlongNoRoom(e!.intOf('avail_mib'), e.intOf('need_mib'), e.fields.containsKey('fixed_mib') ? e.intOf('fixed_mib') : null),
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
    final r = await _whileWriting(() => backend.run(fn, args, onEvent));
    await probe();
    final again = disks?.where((x) => x.path == disk?.path).firstOrNull;
    if (again != null) disk = again;
    await scanShrink();
    return r;
  }

  // ── 缩分区 ──────────────────────────────────────────────────────────────
  Future<CallResult> shrink(Shrinkable s, int targetMib, void Function(Gk3Event) onEvent) async {
    final r = await _whileWriting(() => backend.run('gk3_shrink', [s.part, '$targetMib'], onEvent));
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
    // 纯 WPA3 要 key_mgmt SAE + ieee80211w 2（后端按 sae 设；v1.0 计划 GUI-9）
    final r = await backend.run('gk3_wifi_connect', ['hex:${ap.ssidHex}', password, if (ap.hidden) 'hidden', if (ap.auth == 'sae') 'sae'], onEvent);
    if (r.ok) net = r.first('NET');
    _changed();
    return r;
  }

  List<Variant>? variants;
  /// 取版本列表失败的那次调用（界面按它的 ERR 说原因）
  CallResult? variantsFail;
  Variant? variant;

  Future<void> fetchVariants() async {
    variants = null;
    variantsFail = null;
    _changed();
    final r = await backend.run('gk3_net_manifest');
    if (r.ok) {
      variants = r.ofType('VARIANT').map(Variant.new).toList();
    } else {
      variantsFail = r;
    }
    _changed();
  }

  void setVariant(Variant v) {
    variant = v;
    _changed();
  }

  // ── 安装 ────────────────────────────────────────────────────────────────
  /// 现在（或失败时）在哪一段
  InstallStage? stage;

  /// 下载被用户取消了（失败页据此说"已取消"）
  bool cancelled = false;
  StreamSubscription<Gk3Event>? _dl;
  StreamController<Gk3Event>? _dlOut;

  /// 下载阶段可以取消（GUI-5）：盘还没动。进了写盘就不行了 —— 那时返回 false，什么都不做
  bool cancelDownload() {
    if (stage != InstallStage.download || _dl == null) return false;
    cancelled = true;
    // 不 await：取消要等后端那边的流收尾，而 ShellBackend 收尾 = 杀进程组、等它退出
    unawaited(_dl!.cancel());
    _dl = null;
    _dlOut?.close();
    return true;
  }

  /// 网络安装先下载（占总进度 0–40%），再走和 U 盘安装完全相同的 gk3_apply
  Stream<Gk3Event> install() async* {
    var rel = usbRelease?.dir ?? '';
    final net = source == Source.net;
    if (net) {
      // 下载阶段不算"写盘"：盘没动，侧栏的重启 / 关机照常可用 —— 下载卡住时它们就是取消（GUI 审查 2026-10-05）
      stage = InstallStage.download;
      cancelled = false;
      var ok = false;
      // 中间隔一个 controller：取消时（cancelDownload）直接关掉它，这边的循环立刻结束，
      // 不必等后端的流先吐完最后一个事件
      final out = _dlOut = StreamController<Gk3Event>();
      _dl = backend.call('gk3_net_release', [variant!.base, netPayloadDir]).listen(out.add, onDone: out.close);
      await for (final e in out.stream) {
        if (e is Gk3Progress) {
          yield e.at(e.percent * 40 ~/ 100);
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
      _dl = null;
      _dlOut = null;
      if (cancelled) {
        yield const Gk3Exit(kCancelledExit);
        return;
      }
      if (!ok) return;
      rel = netPayloadDir;
    }
    stage = InstallStage.write;
    _writing++;
    _changed();
    try {
      final args = ['--release', rel, ..._planArgs()];
      await for (final e in backend.call('gk3_apply', args)) {
        yield (net && e is Gk3Progress) ? e.at(40 + e.percent * 60 ~/ 100) : e;
      }
    } finally {
      _writing--;
      _changed();
    }
  }
}
