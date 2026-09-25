// 把后端的行记录解读成界面用的类型。
//
// ⚠️ 这里只做【解读】，不做任何分区计算：空间够不够、/data 能给多大、放不放得下，
//    一律问 gk3_plan（backend.dart 顶上那条规矩）。
import '../backend/backend.dart';
import '../backend/protocol.dart';

const espTypeGuid = 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B';

class Part {
  Part(Gk3Record r)
      : path = r['path'],
        num = r.intOf('num'),
        start = r.intOf('start'),
        end = r.intOf('end'),
        sizeMib = r.intOf('size_mib'),
        sizeKib = r.intOf('size_kib'),
        type = r['type'].toUpperCase(),
        name = r['name'],
        fs = r['fs'],
        fslabel = r['fslabel'],
        os = r['os'];
  final String path, type, name, fs, fslabel, os;
  final int num, start, end, sizeMib, sizeKib;

  bool get isEsp => type == espTypeGuid || name == 'esp';

  /// 给人看的名字：卷标比 PARTLABEL 有用（Windows 的 PARTLABEL 全是 "Basic data partition"）
  String get label => fslabel.isNotEmpty ? fslabel : (name.isNotEmpty ? name : path.split('/').last);
}

class FreeRegion {
  FreeRegion(Gk3Record r)
      : disk = r['disk'],
        start = r.intOf('start'),
        end = r.intOf('end'),
        sizeMib = r.intOf('size_mib');
  final String disk;
  final int start, end, sizeMib;
}

class Disk {
  Disk(Gk3Record r)
      : path = r['path'],
        sizeMib = r.intOf('size_mib'),
        model = r['model'] == '?' ? '' : r['model'],
        removable = r['removable'] == '1',
        tran = r['tran'],
        medium = r.yes('medium');
  final String path, model, tran;
  final int sizeMib;
  final bool removable, medium;
  final parts = <Part>[];
  final free = <FreeRegion>[];

  bool get external => removable || tran == 'usb';
  Part? get esp {
    for (final p in parts) {
      if (p.isEsp) return p;
    }
    return null;
  }

  FreeRegion? get largestFree {
    FreeRegion? best;
    for (final f in free) {
      if (best == null || f.sizeMib > best.sizeMib) best = f;
    }
    return best;
  }

  /// gk3_probe 的输出：DISK 行后面跟着它的 PART / FREE 行（FREE 带 disk= 可以直接认）
  static List<Disk> fromProbe(CallResult r) {
    final disks = <Disk>[];
    for (final rec in r.records) {
      switch (rec.type) {
        case 'DISK':
          disks.add(Disk(rec));
        case 'PART':
          if (disks.isNotEmpty) disks.last.parts.add(Part(rec));
        case 'FREE':
          for (final d in disks) {
            if (d.path == rec['disk']) d.free.add(FreeRegion(rec));
          }
      }
    }
    for (final d in disks) {
      d.parts.sort((a, b) => a.start.compareTo(b.start));
    }
    return disks;
  }
}

enum CheckState { ok, fail, unknown }

class Check {
  Check(Gk3Record r)
      : id = r['id'],
        state = switch (r['ok']) { 'yes' => CheckState.ok, 'no' => CheckState.fail, _ => CheckState.unknown },
        value = r['value'],
        why = r['why'],
        missing = r['missing'];
  final String id, value, why, missing;
  final CheckState state;
}

class EspInfo {
  EspInfo(Gk3Record r)
      : part = r['part'],
        sizeMib = r.intOf('size_mib'),
        freeMib = r.intOf('free_mib'),
        needMib = r.intOf('need_mib', 150),
        windows = r.yes('windows'),
        ours = r.yes('gaokun3'),
        mountable = r.yes('mountable');
  final String part;
  final int sizeMib, freeMib, needMib;
  final bool windows, ours, mountable;
  bool get roomy => mountable && freeMib >= needMib;
}

class Shrinkable {
  Shrinkable(Gk3Record r)
      : part = r['part'],
        fs = r['fs'],
        curMib = r.intOf('cur_mib'),
        minMib = r.intOf('min_mib'),
        can = r.yes('can'),
        why = r['why'];
  final String part, fs, why;
  final int curMib, minMib;
  final bool can;

  /// gk3_shrink 自己再加的余量（installer-lib.sh：floor = min + 512）。
  /// ⚠️ 这是界面上滑块的下限，【不是】判据 —— 判据在 gk3_shrink 里，它会自己再验一遍。
  int get floorMib => minMib + 512;
}

class PlanPart {
  PlanPart(Gk3Record r)
      : name = r['name'],
        start = r.intOf('start'),
        end = r.intOf('end'),
        sizeMib = r.intOf('size_mib');
  final String name;
  final int start, end, sizeMib;
}

/// 重新安装时复用的一个现有分区（gk3_plan --mode reinstall 的 PLAN op=reuse）
class PlanReuse {
  PlanReuse(Gk3Record r)
      : name = r['name'],
        path = r['path'],
        sizeMib = r.intOf('size_mib'),
        action = r['action'];
  final String name, path;
  final int sizeMib;

  /// write = 写入新系统，format = 格式化（数据清掉），keep = 原样保留
  final String action;
}

/// gk3_plan 的结果：要么 parts + summary，要么 error
class Plan {
  Plan(CallResult r)
      : parts = [for (final p in r.ofType('PLAN').where((p) => p['op'] == 'mkpart')) PlanPart(p)],
        reuse = [for (final p in r.ofType('PLAN').where((p) => p['op'] == 'reuse')) PlanReuse(p)],
        wipe = r.ofType('PLAN').any((p) => p['op'] == 'wipe'),
        summary = r.first('PLANSUM'),
        error = r.first('PLANERR') ?? (r.ok ? null : Gk3Record('PLANERR', {'msg': r.error ?? 'exit-${r.exitCode}'}));
  final List<PlanPart> parts;
  final List<PlanReuse> reuse;
  final bool wipe;
  final Gk3Record? summary, error;

  bool get ok => error == null && summary != null;
  int get userdataMib => summary?.intOf('userdata_mib') ?? 0;
  int get availMib => summary?.intOf('avail_mib') ?? 0;
  int get fixedMib => summary?.intOf('fixed_mib') ?? 0;
  int get totalNewMib => parts.fold(0, (a, p) => a + p.sizeMib);
  bool get keepData => summary?.yes('keep_data') ?? false;
}

class Ap {
  Ap(Gk3Record r)
      : signal = r.intOf('signal', -100),
        secure = r.yes('secure'),
        auth = r['auth'],
        ssidHex = r['ssid_hex'],
        ssid = r['ssid'];
  final int signal;
  final bool secure;
  final String auth, ssidHex, ssid;

  bool get supported => auth != 'eap';

  /// 信号格数 0–4（dBm 数字对用户没有意义 —— roadmap 欠账第 1 条）
  int get bars => signal >= -55 ? 4 : signal >= -65 ? 3 : signal >= -75 ? 2 : signal >= -85 ? 1 : 0;
}

/// 变体清单的一行。base= 指向 R2 上的一个发布目录（installer-lib.sh 的 gk3_net_manifest）
class Variant {
  Variant(Gk3Record r)
      : id = r['id'],
        name = r['name'],
        desc = r['desc'],
        base = r['base'],
        sizeMib = r.intOf('size_mib');
  final String id, name, desc, base;
  final int sizeMib;
}

/// MiB → 给人看的大小：100 GiB 以下保留一位小数（"21.2 GiB"），整数不显示 ".0"
String fmtMib(int mib) {
  if (mib < 1024) return '$mib MiB';
  final g = mib / 1024;
  if (g >= 1024) return '${(g / 1024).toStringAsFixed(1)} TiB';
  final s = g >= 100 ? g.toStringAsFixed(0) : g.toStringAsFixed(1);
  return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s} GiB';
}

/// gk3_release_info / gk3_net_release 的 RELEASE 记录
class Release {
  Release(Gk3Record r)
      : dir = r['dir'],
        hasBoot = r.yes('boot'),
        superKind = r['super'],
        hasSha = r.yes('sha256'),
        rescue = r.yes('rescue'),
        version = r['version'] == '?' ? '' : r['version'],
        superMib = r.intOf('super_mib');
  final String dir, superKind, version;
  final bool hasBoot, hasSha, rescue;
  final int superMib;

  /// 能不能拿它装：boot.img 与 super 都在
  bool get installable => hasBoot && superKind != 'no' && superKind.isNotEmpty;
}
