// 加入页:房间码两段输入 + 房主地址;连接过程以终端呈现,失败给错误面板。
// v1 需要房主 IP:端口(核心以 peer 直连);发现与打洞随后续版本发布。
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
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

  void _paste() async {
    final text = (await Clipboard.getData('text/plain'))?.text?.trim() ?? '';
    if (text.isEmpty) return;
    final b = StringBuffer();
    for (final r in text.runes) {
      final ch = String.fromCharCode(r).toUpperCase();
      if ((r >= 0x30 && r <= 0x39) || (r >= 0x41 && r <= 0x5A)) b.write(ch);
      if (b.length >= 8) break;
    }
    final s = b.toString();
    setState(() {
      _seg1.text = s.substring(0, s.length.clamp(0, 4));
      _seg2.text = s.substring(4, s.length.clamp(4, 8));
    });
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
                EgButton(label: app.langs.t('btn.paste'), small: true, onPressed: _paste),
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
              EgButton(label: app.langs.t('btn.scan'), onPressed: null),
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
