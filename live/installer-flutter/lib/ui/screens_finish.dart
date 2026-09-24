// 选项 →（分区大小）→ 确认 → 进度 → 完成 / 失败
import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../backend/protocol.dart';
import '../model/model.dart';
import '../session.dart';
import 'theme.dart';
import 'widgets.dart';

class OptsPage extends StatefulWidget {
  const OptsPage({super.key});
  @override
  State<OptsPage> createState() => _OptsPageState();
}

class _OptsPageState extends State<OptsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final s = context.session;
      if (!s.rescueAvailable) s.rescue = false;
      s.setRescue(s.rescue);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.session, l = context.l, tt = Theme.of(context).textTheme;
    final p = s.plan;
    final dataLine = p == null || s.planning
        ? '…'
        : !p.ok
            ? planErrorText(context, p)
            : (s.userdataMib == null ? l.optsData(fmtMib(p.userdataMib)) : l.optsDataFixed(fmtMib(p.userdataMib)));
    return StepPage(
      title: l.optsTitle,
      subtitle: l.optsSub,
      onBack: () => Navigator.pop(context),
      bottomLeft: Btn(l.optsAdvanced, kind: BtnKind.secondary, icon: Icons.tune, onPressed: p?.ok == true ? () => go(context, const AdvPage()) : null),
      onNext: p?.ok == true && !s.planning ? () => go(context, const ConfirmPage()) : null,
      child: ListView(children: [
        ChoiceCard(
          icon: Icons.health_and_safety,
          title: l.optsRescueTitle,
          body: l.optsRescueBody,
          reason: s.rescueAvailable ? null : l.optsRescueMissing,
          trailing: Switch(value: s.rescue && s.rescueAvailable, onChanged: s.rescueAvailable ? s.setRescue : null),
          onTap: s.rescueAvailable ? () => s.setRescue(!s.rescue) : null,
        ),
        const SizedBox(height: 20),
        Text(dataLine, style: tt.titleMedium!.copyWith(color: p != null && !p.ok ? C.danger : C.text)),
      ]),
    );
  }
}

/// PLANERR → 人话。msg 的取值在 installer-lib.sh 的 gk3_plan 里。
String planErrorText(BuildContext context, Plan p) {
  final l = context.l;
  final e = p.error;
  if (e == null) return l.errPlan('?');
  return switch (e['msg']) {
    'not-enough-space' => l.errNoSpace(fmtMib(e.intOf('avail_mib')), fmtMib(e.intOf('need_mib'))),
    'userdata-too-small' => l.errUserdataSmall(fmtMib(e.intOf('min_mib'))),
    'userdata-too-big' => l.errUserdataBig(fmtMib(e.intOf('max_mib'))),
    'mbr-disk' => l.errMbr,
    'partlabel-conflict' => l.modeWhyInstalled(e['names'].replaceAll(',', ', ')),
    'alongside-needs-existing-esp' => l.modeWhyNoEsp,
    final m => l.errPlan(m),
  };
}

// ── 专业分区（只有 /data 能改；其余由系统决定，改了也装不上）────────────────

class AdvPage extends StatefulWidget {
  const AdvPage({super.key});
  @override
  State<AdvPage> createState() => _AdvPageState();
}

class _AdvPageState extends State<AdvPage> {
  double? _v;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.session, l = context.l, tt = Theme.of(context).textTheme;
    final p = s.plan;
    final max = s.maxUserdataMib ?? p?.userdataMib ?? 0;
    const min = 8192; // 滑块下限的显示值；真正的下限由 gk3_plan 判（PLANERR userdata-too-small）
    final cur = _v ?? (p?.userdataMib ?? max).toDouble();
    return StepPage(
      title: l.advTitle,
      subtitle: l.advSub,
      onBack: () => Navigator.pop(context),
      bottomLeft: Btn(l.advReset, kind: BtnKind.secondary, icon: Icons.restart_alt, onPressed: () {
        setState(() => _v = null);
        s.setUserdata(null);
      }),
      onNext: p?.ok == true ? () => Navigator.pop(context) : null,
      nextLabel: l.btnNext,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: ListView(children: [
            for (final part in p?.parts ?? <PlanPart>[])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  SizedBox(width: 180, child: Text(part.name == 'userdata' ? l.advUserdata : part.name, style: tt.bodyLarge)),
                  Text(fmtMib(part.sizeMib), style: tt.bodyLarge!.copyWith(color: part.name == 'userdata' ? C.accent : C.muted)),
                  if (part.name != 'userdata') ...[const SizedBox(width: 12), Text(l.advFixed, style: tt.bodySmall)],
                ]),
              ),
          ]),
        ),
        const SizedBox(width: 32),
        SizedBox(
          width: 460,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.advUserdata, style: tt.titleMedium),
            Text(fmtMib(cur.round()), style: tt.headlineMedium),
            if (max > min)
              Slider(
                value: cur.clamp(min.toDouble(), max.toDouble()),
                min: min.toDouble(),
                max: max.toDouble(),
                onChanged: (v) {
                  setState(() => _v = (v / 1024).round() * 1024.0);
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 300), () => s.setUserdata(_v!.round() >= max ? null : _v!.round()));
                },
              ),
            if (p != null && p.ok)
              // ★ "已分配 / 共"读 PLANSUM 的 fixed_mib 与 avail_mib —— C 版这里是
              //   plan_userdata_mib + 13776 的硬编码（roadmap 欠账第 4 条）
              Text(l.advTotal(fmtMib(p.fixedMib + p.userdataMib), fmtMib(p.availMib)), style: tt.bodyLarge),
            if (p != null && !p.ok) Text(planErrorText(context, p), style: tt.bodyLarge!.copyWith(color: C.danger)),
          ]),
        ),
      ]),
    );
  }
}

// ── 确认 ─────────────────────────────────────────────────────────────────────

class ConfirmPage extends StatelessWidget {
  const ConfirmPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.session, l = context.l, tt = Theme.of(context).textTheme;
    final d = s.disk!, p = s.plan!;
    final wipe = s.mode == Mode.wipe;
    final a = s.along;
    // 将被删除的东西要全列出来；9 行以内不折叠（第一版折叠到 6 行，藏掉的正好是 WinRE）
    const show = 9;
    return StepPage(
      title: l.confirmTitle,
      subtitle: l.confirmSub,
      bottom: Row(children: [
        Btn(l.btnBack, kind: BtnKind.secondary, icon: Icons.arrow_back, onPressed: () => Navigator.pop(context)),
        const SizedBox(width: 24),
        Expanded(
          child: HoldToConfirm(
            idle: l.confirmHoldIdle,
            busy: (x) => l.confirmHoldBusy('$x'),
            onConfirmed: () => go(context, const RunPage(), replace: true),
          ),
        ),
      ]),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: ListView(children: [
            Text('${d.model.isNotEmpty ? d.model : (d.external ? l.diskExternal : l.diskInternal)} · ${d.path} · ${fmtMib(d.sizeMib)}', style: tt.titleMedium),
            const SizedBox(height: 10),
            DiskBar(disk: d, highlightFree: a is AlongOk && !wipe ? a.region : null),
            const SizedBox(height: 18),
            if (wipe) ...[
              Text(l.confirmWipeHead, style: tt.titleMedium!.copyWith(color: C.danger)),
              const SizedBox(height: 8),
              if (d.parts.isEmpty) Text(l.confirmNoParts, style: tt.bodyMedium),
              // ★ 必须把将被销毁的东西逐条列出来（stage7-live-installer.md §3 的界面流程）
              for (final part in d.parts.take(show))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    Container(width: 12, height: 12, decoration: BoxDecoration(color: DiskBar.colorOf(part.os), shape: BoxShape.circle)),
                    const SizedBox(width: 10),
                    SizedBox(width: 90, child: Text(part.path.split('/').last, style: tt.bodyMedium)),
                    Expanded(child: Text('${part.label}${part.fs.isNotEmpty ? '  (${part.fs})' : ''}', style: tt.bodyLarge)),
                    Text(fmtMib(part.sizeMib), style: tt.bodyMedium),
                  ]),
                ),
              if (d.parts.length > show) Text(l.confirmMore('${d.parts.length - show}'), style: tt.bodyMedium),
            ] else ...[
              Text(l.confirmAlongHead, style: tt.titleMedium!.copyWith(color: C.ok)),
              const SizedBox(height: 8),
              Text(l.confirmAlongBody(fmtMib(p.totalNewMib), a is AlongOk ? a.esp.path : '?'), style: tt.bodyLarge),
              if (a is AlongOk && a.windows) ...[const SizedBox(height: 6), Text(l.confirmWindowsKept, style: tt.bodyLarge)],
            ],
          ]),
        ),
        const SizedBox(width: 36),
        SizedBox(
          width: 380,
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: C.surf, borderRadius: BorderRadius.circular(18)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.confirmNewLayout, style: tt.titleMedium),
              const SizedBox(height: 8),
              for (final part in p.parts)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [Expanded(child: Text(part.name, style: tt.bodyLarge)), Text(fmtMib(part.sizeMib), style: tt.bodyMedium)]),
                ),
              const Divider(color: C.line, height: 24),
              Text(l.confirmRescue(s.rescue && s.rescueAvailable ? l.wordInstall : l.wordNoInstall), style: tt.bodyLarge),
              if (s.source == Source.net && s.variant != null) Text(s.variant!.name, style: tt.bodyLarge),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ── 进度 ─────────────────────────────────────────────────────────────────────

class RunPage extends StatefulWidget {
  const RunPage({super.key});
  @override
  State<RunPage> createState() => _RunPageState();
}

class _RunPageState extends State<RunPage> {
  final _log = <String>[];
  final _scroll = ScrollController();
  int _pct = 0;
  String _step = '';
  bool _showLog = false;
  StreamSubscription<Gk3Event>? _sub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  void _start() {
    _step = context.l.stepPrep;
    _sub = context.session.install().listen((e) {
      if (!mounted) return;
      setState(() {
        switch (e) {
          case Gk3Progress():
            _pct = e.percent;
            _step = e.text;
            _log.add('[${e.percent}%] ${e.text}');
          case Gk3Log():
            _log.add(e.line);
          case Gk3Record():
            _log.add('${e.type} ${e.fields}');
          case Gk3Exit():
            if (e.code == 0) {
              go(context, const DonePage(), replace: true);
            } else {
              go(context, FailPage(log: List.of(_log), code: e.code), replace: true);
            }
        }
      });
      if (_showLog && _scroll.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l, tt = Theme.of(context).textTheme;
    return PopScope(
      canPop: false, // 装到一半不许返回
      child: StepPage(
        title: l.runTitle,
        subtitle: l.runSub,
        bottom: Row(children: [
          Btn(_showLog ? l.runHideLog : l.runShowLog, kind: BtnKind.secondary, icon: Icons.subject, onPressed: () => setState(() => _showLog = !_showLog)),
        ]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 20),
          Row(children: [
            Expanded(child: Text(_step, style: tt.titleMedium)),
            Text('$_pct%', style: tt.headlineMedium),
          ]),
          const SizedBox(height: 16),
          LinearProgressIndicator(value: _pct / 100, minHeight: 18, borderRadius: BorderRadius.circular(9)),
          const SizedBox(height: 24),
          if (_showLog) Expanded(child: LogView(_log, controller: _scroll)),
        ]),
      ),
    );
  }
}

class DonePage extends StatelessWidget {
  const DonePage({super.key});
  @override
  Widget build(BuildContext context) {
    final s = context.session, l = context.l, tt = Theme.of(context).textTheme;
    return PopScope(
      canPop: false,
      child: StepPage(
        title: l.doneTitle,
        bottom: Row(children: [const Spacer(), Btn(l.btnReboot, icon: Icons.restart_alt, autofocus: true, onPressed: s.backend.reboot)]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.check_circle, size: 88, color: C.ok),
          const SizedBox(height: 24),
          Text(l.doneBody, style: tt.bodyLarge),
          if (s.rescue && s.rescueAvailable) ...[const SizedBox(height: 16), Text(l.doneRescue, style: tt.bodyLarge)],
        ]),
      ),
    );
  }
}

class FailPage extends StatelessWidget {
  const FailPage({super.key, required this.log, required this.code});
  final List<String> log;
  final int code;
  @override
  Widget build(BuildContext context) {
    final s = context.session, l = context.l, tt = Theme.of(context).textTheme;
    final err = log.lastWhere((x) => x.startsWith('!! '), orElse: () => l.errExit('$code'));
    final backedUp = log.any((x) => x.contains('sgdisk --load-backup='));
    return PopScope(
      canPop: false,
      child: StepPage(
        title: l.failTitle,
        subtitle: l.failSub,
        bottom: Row(children: [
          Btn(l.shellOpen, kind: BtnKind.secondary, icon: Icons.terminal, onPressed: s.backend.openShell),
          const SizedBox(width: 16),
          Expanded(child: Text(l.shellHint, style: tt.bodySmall)),
        ]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(err.startsWith('!! ') ? err.substring(3) : err, style: tt.titleMedium!.copyWith(color: C.danger)),
          if (backedUp) ...[const SizedBox(height: 8), Text(l.failBackup, style: tt.bodyMedium)],
          const SizedBox(height: 14),
          Expanded(child: LogView(log)),
        ]),
      ),
    );
  }
}
