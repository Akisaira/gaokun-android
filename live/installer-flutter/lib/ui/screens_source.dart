// 来源 →（连 WiFi → 输密码 → 选版本）
import 'package:flutter/material.dart';

import '../app.dart';
import '../backend/protocol.dart';
import '../model/model.dart';
import '../session.dart';
import 'screens_finish.dart';
import 'soft_keyboard.dart';
import 'theme.dart';
import 'widgets.dart';

class SourcePage extends StatelessWidget {
  const SourcePage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.session, l = context.l;
    final rel = s.usbRelease;
    final usbOk = rel?.installable ?? false;
    // U 盘里没有镜像时替用户选到网络那一张
    if (!usbOk && s.source == Source.usb) {
      WidgetsBinding.instance.addPostFrameCallback((_) => s.setSource(Source.net));
    }
    return StepPage(
      step: Gk3Step.source,
      title: l.sourceTitle,
      subtitle: l.sourceSub,
      onBack: () => Navigator.pop(context),
      onNext: () {
        if (s.source == Source.usb) {
          go(context, const OptsPage());
        } else {
          go(context, const NetPage());
        }
      },
      child: ListView(children: [
        ChoiceCard(
          icon: Icons.usb,
          title: l.sourceUsbTitle,
          body: [l.sourceUsbBody, if (rel != null && rel.version.isNotEmpty) rel.version].join('\n'),
          reason: usbOk ? null : l.sourceUsbMissing,
          selected: s.source == Source.usb && usbOk,
          onTap: () => s.setSource(Source.usb),
        ),
        const SizedBox(height: 14),
        ChoiceCard(
          icon: Icons.wifi,
          title: l.sourceNetTitle,
          body: l.sourceNetBody,
          selected: s.source == Source.net,
          onTap: () => s.setSource(Source.net),
        ),
      ]),
    );
  }
}

// ── WiFi 第一步：选网络 ──────────────────────────────────────────────────────
// ★ 两步式（roadmap 欠账第 1 条）：C 版把密码框挤在 AP 列表下面，列表一长就把
//   按钮顶到边上。现在：先选网络，再换一屏只放 SSID + 密码框 + 软键盘。

class NetPage extends StatefulWidget {
  const NetPage({super.key});
  @override
  State<NetPage> createState() => _NetPageState();
}

class _NetPageState extends State<NetPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.session.scanWifi());
  }

  Future<void> _pick(Ap ap) async {
    final s = context.session;
    if (!ap.secure) {
      await go(context, PasswordPage(ap: ap, open: true));
    } else {
      await go(context, PasswordPage(ap: ap));
    }
    if (mounted && s.online) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = context.session, l = context.l, tt = Theme.of(context).textTheme;
    final aps = s.aps;
    final net = s.net;
    return StepPage(
      step: Gk3Step.source,
      title: l.netTitle,
      subtitle: l.netSub,
      onBack: () => Navigator.pop(context),
      bottomLeft: Btn(l.netRescan, kind: BtnKind.secondary, icon: Icons.refresh, onPressed: s.scanning ? null : s.scanWifi),
      onNext: s.online ? () => go(context, const VariantPage()) : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (s.online && net != null) ...[
          Row(children: [
            Icon(Icons.wifi, color: context.gk.success),
            const SizedBox(width: 10),
            Text(l.netConnected(net['ssid'], net['ip']), style: tt.bodyLarge!.copyWith(color: context.gk.success)),
          ]),
          const SizedBox(height: 16),
        ],
        Expanded(
          child: s.scanning && aps == null
              ? Row(children: [const CircularProgressIndicator(), const SizedBox(width: 16), Text(l.netScanning, style: tt.bodyLarge)])
              : (aps == null || aps.isEmpty)
                  ? Text(l.netNone, style: tt.bodyLarge)
                  : GridView(
                      // 固定行高而不是宽高比：卡片里最多两行（标题 + 说明 / 不支持的原因）
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, mainAxisExtent: 100),
                      children: [
                        for (final ap in aps)
                          ChoiceCard(
                            title: ap.ssid,
                            body: ap.supported ? (ap.secure ? null : l.netOpen) : null,
                            reason: ap.supported ? null : l.netEnterprise,
                            selected: s.online && net?['ssid'] == ap.ssid,
                            trailing: SignalBars(ap.bars, secure: ap.secure),
                            onTap: () => _pick(ap),
                          ),
                      ],
                    ),
        ),
      ]),
    );
  }
}

// ── WiFi 第二步：输密码 ──────────────────────────────────────────────────────

class PasswordPage extends StatefulWidget {
  const PasswordPage({super.key, required this.ap, this.open = false});
  final Ap ap;
  final bool open;
  @override
  State<PasswordPage> createState() => _PasswordPageState();
}

class _PasswordPageState extends State<PasswordPage> {
  final _pw = TextEditingController();
  final _focus = FocusNode();
  bool _show = false, _busy = false;
  String? _error;
  int _pct = 0;

  @override
  void initState() {
    super.initState();
    _pw.addListener(() => setState(() {}));
    if (widget.open) WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
  }

  @override
  void dispose() {
    _pw.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// wpa_supplicant 只收 8–63 个字符（wpa-2.10 wpa_supplicant/config.c:571）——
  /// 在这里就拦住，不让用户白等 20 秒超时（gk3_wifi_connect 里也会再验一遍）
  bool get _lengthOk => widget.open || (_pw.text.length >= 8 && _pw.text.length <= 63);

  Future<void> _connect() async {
    if (!_lengthOk || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _pct = 0;
    });
    final r = await context.session.connect(widget.ap, widget.open ? '' : _pw.text, (e) {
      if (e is Gk3Progress && mounted) setState(() => _pct = e.percent);
    });
    if (!mounted) return;
    if (r.ok) {
      Navigator.pop(context);
    } else {
      setState(() {
        _busy = false;
        _error = context.l.netFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l, tt = Theme.of(context).textTheme;
    return StepPage(
      step: Gk3Step.source,
      title: widget.open ? l.netConnecting(widget.ap.ssid) : l.netPasswordFor(widget.ap.ssid),
      onBack: _busy ? null : () => Navigator.pop(context),
      nextLabel: l.netConnect,
      onNext: _lengthOk && !_busy ? _connect : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!widget.open)
          TextField(
            controller: _pw,
            focusNode: _focus,
            autofocus: true,
            obscureText: !_show,
            enabled: !_busy,
            style: tt.titleLarge,
            onSubmitted: (_) => _connect(),
            decoration: InputDecoration(
              labelText: l.netPassword,
              prefixIcon: const Icon(Icons.key_outlined),
              suffixIcon: IconButton(
                tooltip: l.netShowPassword,
                icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                onPressed: () => setState(() => _show = !_show),
              ),
              // 长度不对是 MD3 的"错误"状态：框变 error 色、下面一行说明
              errorText: _pw.text.isNotEmpty && !_lengthOk ? l.netPasswordLength : null,
            ),
          ),
        const SizedBox(height: 12),
        if (_busy) ...[
          LinearProgressIndicator(value: _pct / 100, minHeight: 8),
          const SizedBox(height: 12),
        ],
        if (_error != null) Text(_error!, style: tt.bodyLarge!.copyWith(color: context.cs.error)),
        const Spacer(),
        if (!widget.open) SoftKeyboard(controller: _pw, onDone: _connect),
      ]),
    );
  }
}

// ── 选版本 ───────────────────────────────────────────────────────────────────

class VariantPage extends StatefulWidget {
  const VariantPage({super.key});
  @override
  State<VariantPage> createState() => _VariantPageState();
}

class _VariantPageState extends State<VariantPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final s = context.session;
      if (s.variants == null) s.fetchVariants();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.session, l = context.l, tt = Theme.of(context).textTheme;
    final vs = s.variants;
    return StepPage(
      step: Gk3Step.source,
      title: l.variantTitle,
      subtitle: l.variantSub,
      onBack: () => Navigator.pop(context),
      onNext: s.variant == null ? null : () => go(context, const OptsPage()),
      child: s.variantsError != null
          ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.variantFailed, style: tt.bodyLarge!.copyWith(color: context.cs.error)),
              const SizedBox(height: 16),
              Btn(l.btnRetry, kind: BtnKind.secondary, onPressed: s.fetchVariants),
            ])
          : vs == null
              ? const Center(child: CircularProgressIndicator())
              : ListView.separated(
                  itemCount: vs.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (_, i) {
                    final v = vs[i];
                    return ChoiceCard(
                      title: v.name,
                      body: '${v.desc}\n${l.variantSize(fmtMib(v.sizeMib))}',
                      selected: identical(s.variant, v),
                      onTap: () => s.setVariant(v),
                    );
                  },
                ),
    );
  }
}
