import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// 屏幕软键盘。Linux 桌面 embedder 不提供输入法面板，平板又可能没接键盘盖，
/// 所以 WiFi 密码这种东西只能自己画一个（C 版也是自己画的，stage7-installer-roadmap.md:106-108）。
/// 接了实体键盘照样能直接打字 —— 两者写的是同一个 TextEditingController。
class SoftKeyboard extends StatefulWidget {
  const SoftKeyboard({super.key, required this.controller, this.onDone});
  final TextEditingController controller;
  final VoidCallback? onDone;

  @override
  State<SoftKeyboard> createState() => _SoftKeyboardState();
}

class _SoftKeyboardState extends State<SoftKeyboard> {
  bool _shift = false, _symbols = false;

  static const _letters = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm'];
  static const _syms = ['1234567890', '@#\$%&*-+()', '!?_=/\\;:\'"'];

  void _type(String ch) {
    final c = widget.controller;
    final sel = c.selection.isValid ? c.selection : TextSelection.collapsed(offset: c.text.length);
    c.value = TextEditingValue(
      text: c.text.replaceRange(sel.start, sel.end, ch),
      selection: TextSelection.collapsed(offset: sel.start + ch.length),
    );
    if (_shift && !_symbols) setState(() => _shift = false);
    HapticFeedback.selectionClick();
  }

  void _back() {
    final c = widget.controller;
    final sel = c.selection.isValid ? c.selection : TextSelection.collapsed(offset: c.text.length);
    if (sel.start == 0 && sel.isCollapsed) return;
    final start = sel.isCollapsed ? sel.start - 1 : sel.start;
    c.value = TextEditingValue(text: c.text.replaceRange(start, sel.end, ''), selection: TextSelection.collapsed(offset: start));
  }

  Widget _key(String label, VoidCallback onTap, {int flex = 1, bool accent = false, IconData? icon}) => Expanded(
        flex: flex,
        child: Padding(
          // ★ 键帽 80 高 + 上下各 4 的缝 = 每个键的可点区域 88（kTouch）
          padding: const EdgeInsets.all(4),
          child: Material(
            color: accent ? C.accent : C.surf2,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              canRequestFocus: false, // 焦点留在输入框里，实体键盘照常能打
              onTap: onTap,
              child: SizedBox(
                height: kTouch - 8,
                child: Center(
                  child: icon != null
                      ? Icon(icon, color: accent ? C.bg : C.text, size: 28)
                      : Text(label, style: TextStyle(fontSize: 24, color: accent ? C.bg : C.text, fontWeight: FontWeight.w500)),
                ),
              ),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final rows = _symbols ? _syms : _letters;
    String cap(String ch) => (_shift && !_symbols) ? ch.toUpperCase() : ch;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [for (final ch in rows[0].split('')) _key(cap(ch), () => _type(cap(ch)))]),
      Row(children: [
        if (!_symbols) const Spacer(flex: 1),
        for (final ch in rows[1].split('')) _key(cap(ch), () => _type(cap(ch)), flex: 2),
        if (!_symbols) const Spacer(flex: 1),
      ]),
      Row(children: [
        if (_symbols)
          const Spacer(flex: 3)
        else
          _key('', () => setState(() => _shift = !_shift), flex: 3, accent: _shift, icon: Icons.arrow_upward),
        for (final ch in rows[2].split('')) _key(cap(ch), () => _type(cap(ch)), flex: 2),
        _key('', _back, flex: 3, icon: Icons.backspace_outlined),
      ]),
      Row(children: [
        _key(_symbols ? 'abc' : '123', () => setState(() => _symbols = !_symbols), flex: 3),
        _key('', () => _type(' '), flex: 10, icon: Icons.space_bar),
        _key('.', () => _type('.'), flex: 2),
        _key('', widget.onDone ?? () {}, flex: 3, accent: true, icon: Icons.keyboard_return),
      ]),
    ]);
  }
}
