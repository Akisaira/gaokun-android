import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../model/model.dart';
import 'theme.dart';

/// 安装流程的七步。左侧导航按它标出"到哪了"（只是指示，不可点：导航只走 返回 / 下一步，
/// 那是 Navigator 的栈 —— C 版 screen++/screen-- 掉进没走过的页的教训，见 app.dart 的 go）。
enum Gk3Step { welcome, disk, mode, source, opts, confirm, install }

extension on Gk3Step {
  (IconData, IconData) get icons => switch (this) {
    Gk3Step.welcome => (Icons.waving_hand_outlined, Icons.waving_hand),
    Gk3Step.disk => (Icons.storage_outlined, Icons.storage),
    Gk3Step.mode => (Icons.call_split_outlined, Icons.call_split),
    Gk3Step.source => (Icons.download_outlined, Icons.download),
    Gk3Step.opts => (Icons.tune_outlined, Icons.tune),
    Gk3Step.confirm => (Icons.fact_check_outlined, Icons.fact_check),
    Gk3Step.install => (Icons.install_desktop_outlined, Icons.install_desktop),
  };
  String label(L10n l) => switch (this) {
    Gk3Step.welcome => l.railWelcome,
    Gk3Step.disk => l.railDisk,
    Gk3Step.mode => l.railMode,
    Gk3Step.source => l.railSource,
    Gk3Step.opts => l.railOpts,
    Gk3Step.confirm => l.railConfirm,
    Gk3Step.install => l.railInstall,
  };
}

/// 每一步的骨架（MD3 大屏布局）：左侧导航栏标出步骤；右侧标题、说明、内容、底栏（返回 / 下一步）
class StepPage extends StatelessWidget {
  const StepPage({
    super.key,
    required this.step,
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

  final Gk3Step step;
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
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StepRail(current: step),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(48, 40, 48, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(title, style: context.tt.headlineMedium),
                  if (subtitle != null) ...[
                    const SizedBox(height: 8),
                    Text(subtitle!, style: context.tt.bodyLarge!.copyWith(color: context.cs.onSurfaceVariant)),
                  ],
                  const SizedBox(height: 28),
                  Expanded(child: child),
                  const SizedBox(height: 20),
                  bottom ??
                      Row(
                        children: [
                          if (onBack != null) Btn(l.btnBack, onPressed: onBack, kind: BtnKind.text, icon: Icons.arrow_back),
                          if (bottomLeft != null) ...[const SizedBox(width: 12), bottomLeft!],
                          const Spacer(),
                          if (nextLabel != null || onNext != null)
                            Btn(nextLabel ?? l.btnNext, onPressed: onNext, kind: nextDanger ? BtnKind.danger : BtnKind.primary),
                        ],
                      ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 左侧的步骤栏：MD3 标准导航抽屉的样子（当前项是 secondary-container 的胶囊指示），但不可点
class _StepRail extends StatelessWidget {
  const _StepRail({required this.current});
  final Gk3Step current;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context), cs = context.cs, tt = context.tt;
    return Container(
      width: 272,
      color: cs.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(12, 32, 12, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: cs.primaryContainer, shape: BoxShape.circle),
                  child: Icon(Icons.android, color: cs.onPrimaryContainer),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('gaokun3', style: tt.titleMedium),
                      Text(l.railSub, style: tt.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          for (final s in Gk3Step.values) _RailItem(step: s, state: s.index.compareTo(current.index)),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('HUAWEI MateBook E Go', style: tt.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({required this.step, required this.state});
  final Gk3Step step;

  /// < 0 已完成，0 当前，> 0 还没到
  final int state;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs, tt = context.tt;
    final (outline, filled) = step.icons;
    final cur = state == 0, done = state < 0;
    final fg = cur ? cs.onSecondaryContainer : (done ? cs.onSurface : cs.onSurfaceVariant);
    return Container(
      height: 56,
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: ShapeDecoration(shape: const StadiumBorder(), color: cur ? cs.secondaryContainer : Colors.transparent),
      child: Row(
        children: [
          Icon(done ? Icons.check_circle : (cur ? filled : outline), size: 24, color: done ? cs.primary : fg),
          const SizedBox(width: 12),
          Expanded(
            child: Text(step.label(L10n.of(context)), style: tt.labelLarge!.copyWith(color: fg)),
          ),
        ],
      ),
    );
  }
}

/// MD3 的四种按钮 + 危险操作（error 角色）
enum BtnKind { primary, tonal, secondary, text, danger }

class Btn extends StatelessWidget {
  const Btn(this.label, {super.key, this.onPressed, this.kind = BtnKind.primary, this.icon, this.autofocus = false});
  final String label;
  final VoidCallback? onPressed;
  final BtnKind kind;
  final IconData? icon;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final child = Text(label);
    final ic = icon == null ? null : Icon(icon);
    switch (kind) {
      case BtnKind.primary:
        return ic == null
            ? FilledButton(onPressed: onPressed, autofocus: autofocus, child: child)
            : FilledButton.icon(onPressed: onPressed, autofocus: autofocus, icon: ic, label: child);
      case BtnKind.tonal:
        return ic == null
            ? FilledButton.tonal(onPressed: onPressed, autofocus: autofocus, child: child)
            : FilledButton.tonalIcon(onPressed: onPressed, autofocus: autofocus, icon: ic, label: child);
      case BtnKind.secondary:
        return ic == null
            ? OutlinedButton(onPressed: onPressed, autofocus: autofocus, child: child)
            : OutlinedButton.icon(onPressed: onPressed, autofocus: autofocus, icon: ic, label: child);
      case BtnKind.text:
        return ic == null
            ? TextButton(onPressed: onPressed, autofocus: autofocus, child: child)
            : TextButton.icon(onPressed: onPressed, autofocus: autofocus, icon: ic, label: child);
      case BtnKind.danger:
        final st = FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError);
        return ic == null
            ? FilledButton(onPressed: onPressed, autofocus: autofocus, style: st, child: child)
            : FilledButton.icon(onPressed: onPressed, autofocus: autofocus, style: st, icon: ic, label: child);
    }
  }
}

/// 可选的卡片（MD3 的可选卡：未选是描边卡，选中是 secondary-container + 单选指示）。
/// 做不到时【禁用 + 写明原因】（C 版 README："'为什么没有这个选项'本身就是用户需要的信息"），
/// 不藏起来；禁用时内容按 MD3 降到 38%，但原因那一行不降 —— 它正是要让人读的。
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
    final cs = context.cs, tt = context.tt, gk = context.gk;
    final enabled = reason == null && onTap != null;
    final disabled = reason != null;
    final bg = selected ? (danger ? cs.errorContainer : cs.secondaryContainer) : cs.surfaceContainerLow;
    final onBg = selected ? (danger ? cs.onErrorContainer : cs.onSecondaryContainer) : cs.onSurface;
    final edge = selected ? (danger ? cs.error : cs.primary) : cs.outlineVariant;
    Widget dim(Widget w) => disabled ? Opacity(opacity: 0.38, child: w) : w;
    final single = body == null && warn == null && good == null && extra == null && reason == null && note == null;
    return Card(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: edge, width: selected ? 2 : 1),
      ),
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 72),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            // 只有一行标题时垂直居中（WiFi 列表那种）；多行时顶端对齐
            child: Row(
              crossAxisAlignment: single ? CrossAxisAlignment.center : CrossAxisAlignment.start,
              children: [
                if (icon != null) ...[
                  dim(
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: danger ? (selected ? cs.error : cs.errorContainer) : (selected ? cs.primary : cs.primaryContainer),
                      ),
                      child: Icon(
                        icon,
                        color: danger ? (selected ? cs.onError : cs.onErrorContainer) : (selected ? cs.onPrimary : cs.onPrimaryContainer),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      dim(
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(title, style: tt.titleLarge!.copyWith(color: onBg)),
                            if (warn != null) ...[
                              const SizedBox(height: 4),
                              Text(warn!, style: tt.bodyLarge!.copyWith(color: selected && danger ? onBg : cs.error)),
                            ],
                            if (good != null) ...[const SizedBox(height: 4), Text(good!, style: tt.bodyLarge!.copyWith(color: gk.success))],
                            if (body != null) ...[
                              const SizedBox(height: 4),
                              Text(body!, style: tt.bodyMedium!.copyWith(color: selected ? onBg.withValues(alpha: 0.8) : cs.onSurfaceVariant)),
                            ],
                            if (extra != null) ...[const SizedBox(height: 12), extra!],
                          ],
                        ),
                      ),
                      for (final (t, c) in [if (reason != null) (reason!, cs.onSurfaceVariant), if (note != null) (note!, gk.warning)]) ...[
                        const SizedBox(height: 10),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.info_outline, size: 20, color: c),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(t, style: tt.bodyMedium!.copyWith(color: c)),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 16), trailing!],
                if (trailing == null && onTap != null) ...[
                  const SizedBox(width: 16),
                  dim(
                    Icon(
                      selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      color: selected ? (danger ? cs.error : cs.primary) : cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 一块盘的布局条：分区按大小占宽度，颜色按系统（都取自 MD3 的角色 + 两个自定义色）
class DiskBar extends StatelessWidget {
  const DiskBar({super.key, required this.disk, this.height = 20, this.highlightFree});
  final Disk disk;
  final double height;

  /// 强调某块空闲区（双系统时 Android 要装进去的那块）
  final FreeRegion? highlightFree;

  static Color colorOf(BuildContext context, String os) {
    final cs = context.cs, gk = context.gk;
    return switch (os) {
      'windows' => cs.primary,
      'winre' || 'msr' => cs.primaryContainer,
      'esp' || 'fat' => gk.warning,
      'android' => gk.success,
      'linux' || 'luks' => cs.tertiary,
      _ => cs.outline,
    };
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs, gk = context.gk;
    final segs = <(int, int, Color)>[]; // start, size, color
    for (final p in disk.parts) {
      segs.add((p.start, p.sizeMib, colorOf(context, p.os)));
    }
    for (final f in disk.free) {
      // 高亮用明亮的 success（与 Android 分区同色："这块将是 Android 的"）；深色的 container 在深色背景上像个洞
      segs.add((f.start, f.sizeMib, identical(f, highlightFree) ? gk.success : cs.surfaceContainerHighest));
    }
    segs.sort((a, b) => a.$1.compareTo(b.$1));
    final total = segs.fold<int>(0, (a, s) => a + s.$2);
    if (total == 0) {
      return Container(
        height: height,
        decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(height / 2)),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            for (final (i, s) in segs.indexed)
              Expanded(
                // 小分区至少占一点点宽度，不然 300 MiB 的 ESP 在 476 GiB 的盘上看不见
                flex: (s.$2 * 1000 ~/ total).clamp(4, 1000),
                child: Container(
                  margin: EdgeInsets.only(right: i == segs.length - 1 ? 0 : 2),
                  color: s.$3,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 最后一步：按住 2 秒（C 版 README："触摸屏误触太容易，而那一步不可撤销"）。
/// 键盘上按住回车 / 空格也行 —— 触摸坏了不能变砖（stage7-live-installer.md §3）。
/// 样子是 MD3 的胶囊按钮（error-container），按住时 error 色从左往右填满。
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
    final cs = context.cs, tt = context.tt;
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
          builder: (context, _) {
            // ★ 焦点框只在用过键盘之后出现（roadmap 第 1 步）：它 autofocus，按 hasFocus 画的话触摸用户也会一直看见一圈白框
            final ring = _focus.hasFocus && FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
            return Container(
              height: kTouch,
              decoration: ShapeDecoration(
                color: widget.enabled ? cs.errorContainer : cs.onSurface.withValues(alpha: 0.12),
                shape: StadiumBorder(side: ring ? BorderSide(color: cs.onSurface, width: 3) : BorderSide.none),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  FractionallySizedBox(
                    widthFactor: _c.value,
                    child: Container(color: cs.error),
                  ),
                  Center(
                    child: Text(
                      _c.value == 0 ? widget.idle : widget.busy((_c.value * 100).round()),
                      style: tt.titleMedium!.copyWith(
                        color: !widget.enabled ? cs.onSurface.withValues(alpha: 0.38) : (_c.value > 0.5 ? cs.onError : cs.onErrorContainer),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 日志（进度页 / 失败页）
class LogView extends StatelessWidget {
  const LogView(this.lines, {super.key, this.controller});
  final List<String> lines;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      padding: const EdgeInsets.all(14),
      child: ListView.builder(
        controller: controller,
        itemCount: lines.length,
        itemBuilder: (_, i) => Text(
          lines[i],
          style: TextStyle(
            fontFamily: 'monospace',
            fontFamilyFallback: kFontFallback,
            fontSize: 13,
            height: 1.45,
            color: lines[i].startsWith('!! ') ? cs.error : (lines[i].startsWith('+ ') ? cs.onSurfaceVariant : cs.onSurface),
          ),
        ),
      ),
    );
  }
}

/// 信号格数（dBm 数字对用户没有意义，roadmap 欠账第 1 条）—— 用 MD3 自带的 WiFi 图标
class SignalBars extends StatelessWidget {
  const SignalBars(this.bars, {super.key, this.secure = false});
  final int bars;
  final bool secure;
  @override
  Widget build(BuildContext context) {
    final icon = switch (bars.clamp(0, 4)) {
      0 => Icons.signal_wifi_0_bar,
      1 => Icons.network_wifi_1_bar,
      2 => Icons.network_wifi_2_bar,
      3 => Icons.network_wifi_3_bar,
      _ => Icons.signal_wifi_4_bar,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (secure) Icon(Icons.lock_outline, size: 18, color: context.cs.onSurfaceVariant),
        const SizedBox(width: 4),
        Icon(icon, color: context.cs.onSurfaceVariant),
      ],
    );
  }
}
