// 加入页:房间码两段输入 + 房主地址;连接过程以终端呈现,失败给错误面板。
// v1 需要房主 IP:端口(核心以 peer 直连);发现与打洞随后续版本发布。
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/invite.dart';
import '../core/qr.dart';
import '../theme.dart';
import '../widgets/eg.dart';
import '../widgets/fx.dart';

class JoinPage extends StatefulWidget {
  final VoidCallback goHome;
  const JoinPage({super.key, required this.goHome});

  @override
  State<JoinPage> createState() => _JoinPageState();
}

class _JoinPageState extends State<JoinPage> with TickerProviderStateMixin {
  final _seg1 = TextEditingController();
  final _seg2 = TextEditingController();
  final _peer = TextEditingController();
  final _seg1Focus = FocusNode();
  final _seg2Focus = FocusNode();
  final _peerFocus = FocusNode();
  late final _shake = ShakeController(this, () => setState(() {}));

  @override
  void dispose() {
    _seg1.dispose();
    _seg2.dispose();
    _peer.dispose();
    _seg1Focus.dispose();
    _seg2Focus.dispose();
    _peerFocus.dispose();
    super.dispose();
  }

  bool get _complete => _seg1.text.trim().length >= 4 && _seg2.text.trim().length >= 4;

  String get _code => '${_seg1.text.trim()}${_seg2.text.trim()}';

  // 把邀请文本或房间码填入输入框:优先识别邀请链接,否则提取字母数字。
  // 返回是否成功填入。
  bool _fillInvite(String text) {
    final invite = EgInvite.parse(text);
    if (invite != null) {
      final code = invite.code;
      setState(() {
        _seg1.text = code.substring(0, code.length.clamp(0, 4));
        _seg2.text = code.substring(4, code.length.clamp(4, 8));
        if (invite.peer != null) _peer.text = invite.peer!;
      });
      return true;
    }
    final b = StringBuffer();
    for (final r in text.runes) {
      final ch = String.fromCharCode(r).toUpperCase();
      if ((r >= 0x30 && r <= 0x39) || (r >= 0x41 && r <= 0x5A)) b.write(ch);
      if (b.length >= 8) break;
    }
    final s = b.toString();
    if (s.isEmpty) return false;
    setState(() {
      _seg1.text = s.substring(0, s.length.clamp(0, 4));
      _seg2.text = s.substring(4, s.length.clamp(4, 8));
    });
    return true;
  }

  void _paste() async {
    final text = (await Clipboard.getData('text/plain'))?.text?.trim() ?? '';
    if (text.isEmpty) return;
    _fillInvite(text);
  }

  // 从图片导入二维码:选图 → 解码 → 填入。相机扫码留给 Android 版。
  void _importQr() async {
    final app = AppState.of(context);
    final path = await app.pickFile(title: app.langs.t('qr.pickTitle'));
    if (path == null || !mounted) return;
    String? text;
    try {
      final bytes = await File(path).readAsBytes();
      text = decodeQr(bytes);
    } catch (_) {}
    if (!mounted) return;
    final ok = text != null && _fillInvite(text);
    if (!ok) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(app.langs.t('qr.decodeFail')),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ));
    }
  }

  void _connect() {
    if (!_complete) {
      _shake.ensure();
      return;
    }
    final peer = _peer.text.trim();
    if (peer.isEmpty) {
      _shake.ensure();
      final app = AppState.of(context);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(app.langs.t('join.needPeer')),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ));
      return;
    }
    AppState.of(context).joinRoom(_code, peer);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.of(context);
    final c = Eg.of(context).c;

    return StaggerIn(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: _BackLink(
            label: app.langs.t('back.home'),
            onTap: () {
              app.leaveRoom();
              widget.goHome();
            },
          ),
        ),
        Text(app.langs.t('join.title'), style: egDisplay(c, size: 30, letterSpacing: -0.01, height: 1.2)),
        Text(
          app.langs.t('join.hint'),
          style: egText(c, size: 12.5, color: c.muted),
        ),

        // 房间码两段:满 4 位自动跳下一段
        AnimatedBuilder(
          animation: _shake.ctl,
          builder: (context, _) {
            return Transform.translate(
              offset: Offset(_shake.dx, 0),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 26),
                child: Row(
                  children: [
                    _CodeSeg(c: c, ctrl: _seg1, focusNode: _seg1Focus, next: _seg2Focus),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text('-', style: egMono(c, size: 20, color: c.faint)),
                    ),
                    _CodeSeg(c: c, ctrl: _seg2, focusNode: _seg2Focus, next: _peerFocus),
                  ],
                ),
              ),
            );
          },
        ),

        // 房主地址(v1 直连;发现与打洞随后续版本发布)
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(app.langs.t('join.peer'), style: egText(c, size: 11.5, color: c.muted, height: 1.4)),
            const SizedBox(height: 6),
            Row(
              children: [
                EgInput(controller: _peer, width: 240, mono: true, hint: 'IP:${app.prefs.port}', focusNode: _peerFocus),
                const SizedBox(width: 12),
                EgButton(label: app.langs.t('btn.pasteInvite'), small: true, onPressed: _paste),
              ],
            ),
            const SizedBox(height: 6),
            Text(app.langs.t('join.peerHint'), style: egText(c, size: 11.5, color: c.faint, height: 1.5)),
          ],
        ),

        // 动作行
        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              EgButton(label: app.langs.t('btn.importQr'), onPressed: _importQr),
              const SizedBox(width: 8),
              EgButton(label: app.langs.t('btn.connect'), kind: EgBtnKind.primary, onPressed: app.room == RoomState.idle ? _connect : null),
            ],
          ),
        ),

        Sect(title: app.langs.t('join.console'), sub: app.langs.t('tag.demo')),
        if (app.joinLog.isNotEmpty) EgTerminal(lines: app.joinLog),
        if (app.joinError != null)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: EgErrorTerm(
              title: app.joinError!,
              body: app.langs.t('join.errBody'),
              retryLabel: app.langs.t('btn.retry'),
              onRetry: _connect,
            ),
          ),
      ],
    );
  }
}

class _BackLink extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const _BackLink({required this.label, required this.onTap});

  @override
  State<_BackLink> createState() => _BackLinkState();
}

class _BackLinkState extends State<_BackLink> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedSlide(
          offset: _hover ? const Offset(-0.06, 0) : Offset.zero,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          child: Text(
            widget.label,
            style: egText(c, size: 13, color: _hover ? c.text : c.muted, height: 1.6),
          ),
        ),
      ),
    );
  }
}

// 一段 4 位房间码:自动大写、仅限字母数字,满 4 位把焦点交给下一格。
class _CodeSeg extends StatelessWidget {
  final EgColors c;
  final TextEditingController ctrl;
  final FocusNode focusNode;
  final FocusNode? next;
  const _CodeSeg({required this.c, required this.ctrl, required this.focusNode, this.next});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 128,
      child: TextField(
        controller: ctrl,
        focusNode: focusNode,
        maxLength: 4,
        textAlign: TextAlign.center,
        cursorColor: c.acc,
        style: egMono(c, size: 22, weight: FontWeight.w700, color: c.acc, letterSpacing: 4, height: 1.3),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
          TextInputFormatter.withFunction((old, newValue) {
            return newValue.copyWith(text: newValue.text.toUpperCase());
          }),
        ],
        onChanged: (v) {
          if (v.length >= 4) {
            FocusScope.of(context).requestFocus(next);
          }
        },
        decoration: InputDecoration(
          isDense: true,
          counterText: '',
          hintText: '····',
          hintStyle: egMono(c, size: 22, color: c.faint, letterSpacing: 4),
          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 13),
          filled: true,
          fillColor: c.panel,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: c.line2),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: c.acc, width: 1),
          ),
        ),
      ),
    );
  }
}
