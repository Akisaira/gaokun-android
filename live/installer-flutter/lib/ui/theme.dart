import 'package:flutter/material.dart';

/// 配色取自 C 版（live/installer/gk3-installer.c:35-44），一个都没改
abstract final class C {
  static const bg = Color(0xFF101418);
  static const surf = Color(0xFF1A2029);
  static const surf2 = Color(0xFF232B36);
  static const line = Color(0xFF343E4B);
  static const text = Color(0xFFE8EEF5);
  static const muted = Color(0xFF8B99A8);
  static const accent = Color(0xFF4DA3FF);
  static const danger = Color(0xFFFF6B5E);
  static const ok = Color(0xFF5AD19A);
  static const dim = Color(0xFF4D5766);
  static const warn = Color(0xFFF2C14E);
}

/// ★ 触摸目标最小 88 逻辑像素（C 版 README 的界面决定）："这机器没有鼠标，手指的实际
///   接触面积远大于设计稿上看着的那点。"逻辑坐标固定 1280×800（见 app.dart 的 LogicalCanvas）。
const double kTouch = 88;

/// 逻辑画布。面板物理 1600×2560 竖屏、平板横用；旋转交给 cage，缩放在这里做。
const Size kCanvas = Size(1280, 800);

ThemeData buildTheme() {
  final scheme = const ColorScheme.dark(
    surface: C.bg,
    primary: C.accent,
    onPrimary: C.bg,
    secondary: C.ok,
    error: C.danger,
    onSurface: C.text,
    outline: C.line,
  );
  const t = TextTheme(
    headlineMedium: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: C.text, height: 1.25),
    titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: C.text, height: 1.3),
    titleMedium: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: C.text, height: 1.3),
    bodyLarge: TextStyle(fontSize: 17, color: C.text, height: 1.5),
    bodyMedium: TextStyle(fontSize: 15, color: C.muted, height: 1.5),
    labelLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, height: 1.2),
    bodySmall: TextStyle(fontSize: 13, color: C.muted, height: 1.4),
  );
  return ThemeData(
    useMaterial3: true,
    // ⚠️★ 按名字列出中文回退字体。2026-09-25 在 cage 里跑真 Linux 版：镜像里装着
    //   fonts-wqy-microhei、fontconfig 按字符也查得到它（fc-match "sans-serif:charset=4e2d"），
    //   但 Flutter 没回退过去，中文全是方块 —— 离线出图发现不了（出图时字体是手动注册的）。
    //   C 版 README 警告过"写死字体名会在换字体包时静默变成方框"：所以这里只作【回退】，
    //   并且 live 镜像构建时断言这几个字体在（scripts/live/test-render.sh 的截图也要看）。
    fontFamilyFallback: const ['WenQuanYi Micro Hei', 'Noto Sans CJK SC', 'Noto Sans SC'],
    colorScheme: scheme,
    scaffoldBackgroundColor: C.bg,
    textTheme: t,
    // ★ 焦点框只在用过键盘之后才出现（roadmap 第 1 步的要求）——Flutter 的
    //   FocusManager.highlightMode 自己就是这么切的，这里只需要让焦点框醒目
    focusColor: C.accent.withValues(alpha: 0.28),
    splashFactory: InkRipple.splashFactory,
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.bg : C.muted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.accent : C.surf2),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: C.accent,
      inactiveTrackColor: C.surf2,
      thumbColor: C.accent,
      trackHeight: 8,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 16),
      overlayShape: RoundSliderOverlayShape(overlayRadius: 36),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: C.accent, linearTrackColor: C.surf2),
  );
}
