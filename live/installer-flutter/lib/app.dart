import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/app_localizations.dart';
import 'session.dart';
import 'ui/screens_start.dart';
import 'ui/theme.dart';

/// 给子树提供 Session，并在它变化时重建依赖它的部分
class SessionScope extends InheritedNotifier<Session> {
  const SessionScope({super.key, required Session session, required super.child}) : super(notifier: session);

  static Session of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SessionScope>()!.notifier!;
}

extension SessionX on BuildContext {
  Session get session => SessionScope.of(this);
  L10n get l => L10n.of(this);
}

/// 跳到下一步。★ 导航就是 Navigator 的栈：返回 = 回到真正来的那一页。
/// C 版用 screen++/screen-- 时，分支屏插在枚举中间，"来源"页按返回会掉进
/// 一个用户没走过的"缩分区"页（stage7-installer-roadmap.md:139-144）。
Future<T?> go<T>(BuildContext context, Widget page, {bool replace = false}) {
  final route = PageRouteBuilder<T>(
    pageBuilder: (_, _, _) => page,
    transitionDuration: const Duration(milliseconds: 220),
    transitionsBuilder: (_, a, _, child) => FadeTransition(
      opacity: a,
      child: SlideTransition(position: Tween(begin: const Offset(0.03, 0), end: Offset.zero).animate(a), child: child),
    ),
  );
  final nav = Navigator.of(context);
  return replace ? nav.pushReplacement(route) : nav.push(route);
}

class InstallerApp extends StatelessWidget {
  const InstallerApp({super.key, required this.session, this.home});
  final Session session;

  /// 测试 / 出图时直接从某一页开始
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    return SessionScope(
      session: session,
      child: ListenableBuilder(
        listenable: session,
        builder: (context, _) => MaterialApp(
          debugShowCheckedModeBanner: false,
          onGenerateTitle: (c) => L10n.of(c).appTitle,
          theme: buildTheme(),
          locale: Locale(session.language),
          supportedLocales: L10n.supportedLocales,
          localizationsDelegates: const [
            L10n.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) => LogicalCanvas(
            child: Stack(children: [
              child!,
              if (session.backend.demoLabel != null)
                Positioned(right: 16, top: 12, child: _DemoBadge(session.backend.demoLabel!)),
            ]),
          ),
          home: home ?? const WelcomePage(),
        ),
      ),
    );
  }
}

/// 固定 1280×800 的逻辑画布，整体缩放到屏幕上（C 版 README："逻辑坐标固定 1280×800，
/// 输出时整体缩放"）。这也让 golden 出图与真机上的布局一模一样。
/// ★ Esc = 返回（roadmap 第 1 步：Tab/方向键移动焦点、回车确认、Esc 返回）。
class LogicalCanvas extends StatelessWidget {
  const LogicalCanvas({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return ColoredBox(
      color: C.bg,
      child: Center(
        child: FittedBox(
          child: SizedBox.fromSize(
            size: kCanvas,
            child: MediaQuery(
              data: mq.copyWith(size: kCanvas, padding: EdgeInsets.zero, viewInsets: EdgeInsets.zero, textScaler: TextScaler.noScaling),
              child: Shortcuts(
                shortcuts: const {SingleActivator(LogicalKeyboardKey.escape): DismissIntent()},
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DemoBadge extends StatelessWidget {
  const _DemoBadge(this.scenario);
  final String scenario;
  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Material(
          type: MaterialType.transparency,
          child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: C.warn.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(99)),
          child: Text(L10n.of(context).fixtureBadge(scenario), style: const TextStyle(color: C.warn, fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ),
      );
}
