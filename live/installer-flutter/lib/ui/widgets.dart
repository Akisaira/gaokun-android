import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../model/model.dart';
import 'theme.dart';

/// 每一步的骨架：标题、副标题、内容、底栏（返回 / 下一步）
class StepPage extends StatelessWidget {
  const StepPage({
    super.key,
    required this.title,
    this.subtitle,
    required this.child,
    this.onBack,
    this.onNext,
    this.nextLabel,
    this.nextDanger = false,
    this.bottomLeft,
    this.bottom,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final VoidCallback? onBack, onNext;
  final String? nextLabel;
  final bool nextDanger;
  final Widget? bottomLeft;

  /// 替换整条底栏（确认页的"按住 2 秒"、进度页的空底栏）
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.fromLTRB(64, 48, 64, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: tt.headlineMedium),
            if (subtitle != null) ...[const SizedBox(height: 8), Text(subtitle!, style: tt.bodyMedium)],
            const SizedBox(height: 28),
            Expanded(child: child),
            const SizedBox(height: 20),
            bottom ??
                Row(children: [
                  if (onBack != null) Btn(l.btnBack, onPressed: onBack, kind: BtnKind.secondary, icon: Icons.arrow_back),
                  if (bottomLeft != null) ...[const SizedBox(width: 16), bottomLeft!],
                  const Spacer(),
                  if (nextLabel != null || onNext != null)
                    Btn(nextLabel ?? l.btnNext, onPressed: onNext, kind: nextDanger ? BtnKind.danger : BtnKind.primary),
                ]),
          ],
        ),
      ),
    );
  }
}

enum BtnKind { primary, secondary, danger }

class Btn extends StatelessWidget {
  const Btn(this.label, {super.key, this.onPressed, this.kind = BtnKind.primary, this.icon, this.autofocus = false});
  final String label;
  final VoidCallback? onPressed;
  final BtnKind kind;
  final IconData? icon;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (kind) {
      BtnKind.primary => (C.accent, C.bg),
      BtnKind.secondary => (C.surf2, C.text),
      BtnKind.danger => (C.danger, C.bg),
    };
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(200, kTouch)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 36)),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
      backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? C.surf : bg),
      foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? C.dim : fg),
      textStyle: WidgetStatePropertyAll(Theme.of(context).textTheme.labelLarge),
      side: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.focused) ? const BorderSide(color: C.text, width: 3) : BorderSide.none),
    );
    return icon == null
        ? FilledButton(onPressed: onPressed, style: style, autofocus: autofocus, child: Text(label))
        : FilledButton.icon(onPressed: onPressed, style: style, autofocus: autofocus, icon: Icon(icon, size: 24), label: Text(label));
  }
}

/// 可选的卡片。做不到时【禁用 + 写明原因】（C 版 README：
/// "'为什么没有这个选项'本身就是用户需要的信息"），不藏起来。
class ChoiceCard extends StatelessWidget {
  const ChoiceCard({
    super.key,
    required this.title,
    this.body,
    this.warn,
    this.good,
    this.reason,
    this.note,
    this.icon,
    this.trailing,
    this.extra,
    this.selected = false,
    this.onTap,
    this.danger = false,
  });

  final String title;
  final String? body, warn, good;

  /// 不为空 ⇒ 禁用，并把原因写在卡片上
  final String? reason;

  /// 与 reason 同样的样式，但【不】禁用：可以选，只是有件事要先知道
  /// （例如安装器正从这块盘上运行 —— 能装双系统，不能整盘清空）
  final String? note;
  final IconData? icon;
  final Widget? trailing, extra;
  final bool selected, danger;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final enabled = reason == null && onTap != null;
    final edge = selected ? (danger ? C.danger : C.accent) : C.line;
    return Opacity(
      opacity: reason == null ? 1 : 0.62,
      child: Material(
        color: selected ? C.surf2 : C.surf,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: edge, width: selected ? 3 : 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: kTouch),
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (icon != null) ...[
                  Icon(icon, size: 34, color: reason != null ? C.dim : (danger ? C.danger : C.accent)),
                  const SizedBox(width: 18),
                ],
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(title, style: tt.titleLarge),
                    if (warn != null) ...[const SizedBox(height: 6), Text(warn!, style: tt.bodyLarge!.copyWith(color: C.danger))],
                    if (good != null) ...[const SizedBox(height: 6), Text(good!, style: tt.bodyLarge!.copyWith(color: C.ok))],
                    if (body != null) ...[const SizedBox(height: 6), Text(body!, style: tt.bodyMedium)],
                    if (extra != null) ...[const SizedBox(height: 12), extra!],
                    for (final t in [reason, note].whereType<String>()) ...[
                      const SizedBox(height: 10),
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Icon(Icons.info_outline, size: 20, color: C.warn),
                        const SizedBox(width: 8),
                        Expanded(child: Text(t, style: tt.bodyMedium!.copyWith(color: C.warn))),
                      ]),
                    ],
                  ]),
                ),
                if (trailing != null) ...[const SizedBox(width: 16), trailing!],
                if (selected && trailing == null) Icon(Icons.check_circle, color: danger ? C.danger : C.accent, size: 30),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// 一块盘的布局条：分区按大小占宽度，颜色按系统
class DiskBar extends StatelessWidget {
  const DiskBar({super.key, required this.disk, this.height = 22, this.highlightFree});
  final Disk disk;
  final double height;

  /// 强调某块空闲区（双系统时要用的那块）
  final FreeRegion? highlightFree;

  static Color colorOf(String os) => switch (os) {
        'windows' => const Color(0xFF3B78D8),
        'winre' || 'msr' => const Color(0xFF2B4F86),
        'esp' || 'fat' => C.warn,
        'android' => C.ok,
        'linux' || 'luks' => const Color(0xFFA77BF3),
        _ => C.muted,
      };

  @override
  Widget build(BuildContext context) {
    final segs = <(int, int, Color)>[]; // start, size, color
    for (final p in disk.parts) {
      segs.add((p.start, p.sizeMib, colorOf(p.os)));
    }
    for (final f in disk.free) {
      segs.add((f.start, f.sizeMib, identical(f, highlightFree) ? C.accent.withValues(alpha: 0.55) : C.surf2));
    }
    segs.sort((a, b) => a.$1.compareTo(b.$1));
    final total = segs.fold<int>(0, (a, s) => a + s.$2);
    if (total == 0) {
      return Container(height: height, decoration: BoxDecoration(color: C.surf2, borderRadius: BorderRadius.circular(6)));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: height,
        child: Row(children: [
          for (final s in segs)
            Expanded(
              // 小分区至少占一点点宽度，不然 300 MiB 的 ESP 在 476 GiB 的盘上看不见
              flex: (s.$2 * 1000 ~/ total).clamp(4, 1000),
              child: Container(margin: const EdgeInsets.only(right: 2), color: s.$3),
            ),
        ]),
      ),
    );
  }
}

/// 最后一步：按住 2 秒（C 版 README："触摸屏误触太容易，而那一步不可撤销"）。
/// 键盘上按住回车 / 空格也行 —— 触摸坏了不能变砖（stage7-live-installer.md §3）。
class HoldToConfirm extends StatefulWidget {
  const HoldToConfirm({super.key, required this.idle, required this.busy, required this.onConfirmed, this.enabled = true});
  final String idle;
  final String Function(int pct) busy;
  final VoidCallback onConfirmed;
  final bool enabled;

  @override
  State<HoldToConfirm> createState() => _HoldToConfirmState();
}

class _HoldToConfirmState extends State<HoldToConfirm> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 2))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        HapticFeedback.heavyImpact();
        widget.onConfirmed();
      }
    });
  final _focus = FocusNode();

  void _down() {
    if (widget.enabled) _c.forward(from: _c.value);
  }

  void _up() {
    if (_c.status != AnimationStatus.completed) _c.animateBack(0, duration: const Duration(milliseconds: 250));
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (_, e) {
        if (e.logicalKey != LogicalKeyboardKey.enter && e.logicalKey != LogicalKeyboardKey.space) return KeyEventResult.ignored;
        if (e is KeyDownEvent) _down();
        if (e is KeyUpEvent) _up();
        return KeyEventResult.handled;
      },
      child: GestureDetector(
        onTapDown: (_) => _down(),
        onTapUp: (_) => _up(),
        onTapCancel: _up,
        child: AnimatedBuilder(
          animation: Listenable.merge([_c, _focus]),
          builder: (context, _) => Container(
            height: kTouch,
            decoration: BoxDecoration(
              color: widget.enabled ? C.danger.withValues(alpha: 0.22) : C.surf,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: _focus.hasFocus ? C.text : (widget.enabled ? C.danger : C.line), width: _focus.hasFocus ? 3 : 2),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(children: [
              FractionallySizedBox(widthFactor: _c.value, child: Container(color: C.danger)),
              Center(
                child: Text(
                  _c.value == 0 ? widget.idle : widget.busy((_c.value * 100).round()),
                  style: tt.labelLarge!.copyWith(color: _c.value > 0.5 ? C.bg : C.text, fontSize: 20),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// 可折叠的日志（进度页 / 失败页）
class LogView extends StatelessWidget {
  const LogView(this.lines, {super.key, this.controller});
  final List<String> lines;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF0B0E11), borderRadius: BorderRadius.circular(14), border: Border.all(color: C.line)),
      padding: const EdgeInsets.all(14),
      child: ListView.builder(
        controller: controller,
        itemCount: lines.length,
        itemBuilder: (_, i) => Text(
          lines[i],
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
            height: 1.45,
            color: lines[i].startsWith('!! ') ? C.danger : (lines[i].startsWith('+ ') ? C.muted : C.text),
          ),
        ),
      ),
    );
  }
}

class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color = C.muted});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(99)),
        child: Text(text, style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w600)),
      );
}

/// 信号格数：dBm 数字对用户没有意义（roadmap 欠账第 1 条）
class SignalBars extends StatelessWidget {
  const SignalBars(this.bars, {super.key});
  final int bars;
  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < 4; i++)
            Container(
              width: 7,
              height: 8.0 + i * 6,
              margin: const EdgeInsets.only(left: 3),
              decoration: BoxDecoration(color: i < bars ? C.text : C.dim, borderRadius: BorderRadius.circular(2)),
            ),
        ],
      );
}
