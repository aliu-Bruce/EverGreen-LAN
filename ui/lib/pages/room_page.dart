// 房间页:房间码(或房主信息)、成员表、联机指南、退出。
// 主机与成员共用一页;名册由 opMembers 提供,主机行由界面自行合成。
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/invite.dart';
import '../core/qr.dart';
import '../theme.dart';
import '../widgets/eg.dart';
import '../widgets/fx.dart';
import '../widgets/qr_view.dart';

class RoomPage extends StatefulWidget {
  final VoidCallback goHome;
  final VoidCallback onCreate;
  final VoidCallback onJoin;
  const RoomPage({super.key, required this.goHome, required this.onCreate, required this.onJoin});

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  bool _guideOpen = false;
  bool _copied = false;
  bool _inviteCopied = false;
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => AppState.of(context).refreshMembers());
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.of(context);
    final c = Eg.of(context).c;

    if (!app.inRoom) {
      // 空态:页头与传输页同一语法(大标题 + 元信息),下面是一张温室虚线卡——
      // 复用 .drop 的语言:像素温室、一句说明、创建与加入两个出口。
      return StaggerIn(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(app.langs.t('room.h1'), style: egDisplay(c, size: 30, letterSpacing: -0.01, height: 1.2)),
              const SizedBox(width: 14),
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(app.langs.t('room.notInRoom'), style: egText(c, size: 12.5, color: c.muted)),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 22),
            child: MouseRegion(
              cursor: SystemMouseCursors.basic,
              onEnter: (_) => setState(() => _hover = true),
              onExit: (_) => setState(() => _hover = false),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                transform: Matrix4.translationValues(0, _hover ? -2 : 0, 0),
                child: DashedBorder(
                  color: _hover ? c.acc : c.line2,
                  radius: 18,
                  child: Container(
                    color: _hover ? c.panel2 : null,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 44),
                    child: Column(
                      children: [
                        PixelArt(rects: egRoomArt(c), cols: 20, rows: 15, scale: 7),
                        const SizedBox(height: 16),
                        Text(app.langs.t('room.emptyTitle'), style: egDisplay(c, size: 16)),
                        const SizedBox(height: 8),
                        Text(
                          app.langs.t('room.emptyBody'),
                          textAlign: TextAlign.center,
                          style: egText(c, size: 12.5, color: c.faint, height: 1.6),
                        ),
                        const SizedBox(height: 18),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            EgButton(label: app.langs.t('home.create'), kind: EgBtnKind.primary, onPressed: widget.onCreate),
                            const SizedBox(width: 8),
                            EgButton(label: app.langs.t('home.join'), onPressed: widget.onJoin),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    final hosting = app.room == RoomState.hosting;
    final n = app.memberCount;

    return StaggerIn(
      children: [
        // 页头:房名(取主机名)+ 状态行 + 二维码按钮
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(app.hostName ?? 'EGLAN', style: egDisplay(c, size: 30, letterSpacing: -0.01, height: 1.2)),
                  const SizedBox(height: 2),
                  Text(
                    hosting ? app.langs.t('room.hostMeta', {'n': '$n'}) : app.langs.t('room.guestMeta', {'host': app.hostName ?? '—'}),
                    style: egText(c, size: 12.5, color: c.muted, height: 1.5),
                  ),
                ],
              ),
            ),
            EgButton(label: app.langs.t('btn.qr'), onPressed: () => _showQr(context, app)),
          ],
        ),

        // 房间码(主机)或房主信息(成员)
        if (hosting) ...[
          Padding(
            padding: const EdgeInsets.only(top: 22, bottom: 12),
            child: EgCodeBlock(
              label: app.langs.t('room.code'),
              code: app.code ?? '',
              copyLabel: _copied ? app.langs.t('btn.copied') : app.langs.t('btn.copyCode'),
              onCopy: () async {
                await Clipboard.setData(ClipboardData(text: (app.code ?? '').replaceAll(' ', '')));
                if (!mounted) return;
                setState(() => _copied = true);
                Future.delayed(const Duration(milliseconds: 1200), () {
                  if (mounted) setState(() => _copied = false);
                });
              },
            ),
          ),
          _SharePanel(
            app: app,
            copied: _inviteCopied,
            onProbe: () => app.probePublic(),
            onCopy: () => _copyInvite(app),
          ),
          const SizedBox(height: 28),
        ] else ...[
          Padding(
            padding: const EdgeInsets.only(top: 22, bottom: 8),
            child: EgPanel(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
                child: Row(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(app.langs.t('join.peer'), style: egText(c, size: 11.5, color: c.muted, height: 1.4)),
                        const SizedBox(height: 6),
                        SelectableText(app.hostAddr, style: egMono(c, size: 20, weight: FontWeight.w700, color: c.acc, height: 1.3)),
                      ],
                    ),
                    const Spacer(),
                    EgTag(app.langs.t('log.joined', {'ip': app.selfIp ?? '—'}), color: c.muted),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 28),
        ],

        Sect(title: app.langs.t('room.members'), sub: app.langs.t('room.membersOnline', {'n': '$n'})),
        _MembersTable(app: app, hosting: hosting),

        // 联机指南
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 28),
          child: EgPanel(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => setState(() => _guideOpen = !_guideOpen),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: Text(
                            app.langs.t('room.guide'),
                            style: egText(c, size: 13.5, weight: FontWeight.w600),
                          ),
                        ),
                      ),
                      AnimatedRotation(
                        turns: _guideOpen ? 0.25 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: Icon(Icons.chevron_right, size: 18, color: c.acc),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_guideOpen) _GuideSteps(app: app),

        EgButton(
          label: app.langs.t('btn.leave'),
          kind: EgBtnKind.danger,
          onPressed: () async {
            await app.leaveRoom();
            if (context.mounted) widget.goHome();
          },
        ),
      ],
    );
  }

  String _inviteText(AppState app) {
    final peer = app.invitePeer;
    if (peer == null || app.code == null) return '';
    final code = EgInvite.normalizeCode(app.code!);
    return '${app.langs.t('invite.text', {'code': app.code})}\n${EgInvite.build(code, peer)}';
  }

  void _copyInvite(AppState app) async {
    final text = _inviteText(app);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _inviteCopied = true);
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _inviteCopied = false);
    });
  }

  // 二维码内容:带 peer 的邀请链接;若地址尚未就绪则退化为纯房间码链接。
  String _qrPayload(AppState app) {
    final code = app.code == null ? '' : EgInvite.normalizeCode(app.code!);
    final peer = app.invitePeer;
    if (code.isEmpty) return '';
    return (peer == null || peer.isEmpty)
        ? 'eglan://join/$code'
        : EgInvite.build(code, peer);
  }

  Future<void> _exportQr(AppState app, String payload) async {
    final path = await app.pickSave('eglan-qr.png');
    if (path == null) return;
    final png = renderQrPng(payload);
    if (png == null) return;
    await File(path).writeAsBytes(png);
  }

  void _showQr(BuildContext context, AppState app) {
    final c = Eg.of(context).c;
    final payload = _qrPayload(app);
    final matrix = payload.isEmpty ? null : encodeQr(payload);
    showDialog<void>(
      context: context,
      builder: (context) => EgSkinDialog(
        title: app.langs.t('qr.title'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              app.langs.t('qr.hint', {'room': app.hostName ?? ''}),
              style: egText(c, size: 13.5, color: c.muted, height: 1.6),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            if (matrix != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: EgQrView(matrix: matrix, size: 220),
              )
            else
              Text(app.langs.t('qr.unavailable'), style: egText(c, size: 13, color: c.bad)),
            const SizedBox(height: 12),
            SelectableText(app.code ?? '', style: egMono(c, size: 20, weight: FontWeight.w700, color: c.acc, letterSpacing: 2)),
            if (matrix != null) ...[
              const SizedBox(height: 4),
              SelectableText(payload, style: egMono(c, size: 10.5, color: c.faint, height: 1.4), textAlign: TextAlign.center),
            ],
          ],
        ),
        actions: [
          EgButton(label: app.langs.t('btn.close'), small: true, onPressed: () => Navigator.of(context).pop()),
          if (matrix != null) ...[
            const SizedBox(width: 8),
            EgButton(
              label: app.langs.t('qr.save'),
              small: true,
              kind: EgBtnKind.primary,
              onPressed: () => _exportQr(app, payload),
            ),
          ],
        ],
      ),
    );
  }
}

// 房主分享面板:局域网地址常驻,公网映射按需探测;邀请优先带公网地址。
class _SharePanel extends StatelessWidget {
  final AppState app;
  final bool copied;
  final VoidCallback onProbe;
  final VoidCallback onCopy;
  const _SharePanel({required this.app, required this.copied, required this.onProbe, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    final t = app.langs.t;
    final publicAddr = app.publicAddr;
    final hasPeer = app.invitePeer != null;
    final mapHint = publicAddr == null
        ? t('room.needMap', {'local': app.prefs.port})
        : t('room.mapHint', {'pub': app.publicPort ?? '—', 'local': app.prefs.port});

    return EgPanel(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t('room.shareTitle'), style: egText(c, size: 13, weight: FontWeight.w600, height: 1.5)),
                      const SizedBox(height: 3),
                      Text(t('room.shareHint'), style: egText(c, size: 12, color: c.muted, height: 1.55)),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                EgButton(label: app.stunRunning ? t('btn.probing') : t('btn.probe'), small: true, onPressed: app.stunRunning ? null : onProbe),
                const SizedBox(width: 8),
                EgButton(
                  label: copied ? t('btn.copied') : t('btn.copyInvite'),
                  kind: EgBtnKind.primary,
                  small: true,
                  onPressed: hasPeer ? onCopy : null,
                ),
              ],
            ),
          ),
          Container(height: 1, color: c.line),
          _ShareRow(
            c: c,
            label: t('room.lan'),
            value: app.lanAddrs.isNotEmpty ? app.lanAddrs.first : '—',
            color: c.text,
          ),
          _ShareRow(
            c: c,
            label: t('room.public'),
            value: publicAddr ?? t('room.unprobed'),
            color: publicAddr == null ? c.faint : c.acc,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (app.stunError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SelectableText(app.stunError!, style: egText(c, size: 11.5, color: c.bad, height: 1.5)),
                  ),
                Text(mapHint, style: egText(c, size: 11.5, color: c.faint, height: 1.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ShareRow extends StatelessWidget {
  final EgColors c;
  final String label;
  final String value;
  final Color color;
  const _ShareRow({required this.c, required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: Row(
        children: [
          SizedBox(width: 86, child: Text(label, style: egText(c, size: 11.5, color: c.muted, height: 1.4))),
          Expanded(
            child: SelectableText(value, style: egMono(c, size: 13, color: color, height: 1.4)),
          ),
        ],
      ),
    );
  }
}

// 成员表:第一行恒为本机;主机侧随后是各成员,成员侧是房主一行。
class _MembersTable extends StatelessWidget {
  final AppState app;
  final bool hosting;
  const _MembersTable({required this.app, required this.hosting});

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    final t = (k) => app.langs.t(k);

    final rows = <List<Widget>>[
      [
        Row(
          children: [
            Flexible(child: Text(app.prefs.name, style: egText(c, size: 13, weight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 8),
            if (hosting) EgTag(t('tag.host'), color: c.warn),
            if (hosting) const SizedBox(width: 8),
            EgTag(t('tag.me')),
          ],
        ),
        Text(app.selfIp ?? '—', style: egMono(c, size: 12.5, color: c.muted)),
        Text('—', style: egMono(c, size: 12.5, color: c.muted)),
        Text('—', style: egMono(c, size: 12.5, color: c.muted)),
      ],
    ];

    if (hosting) {
      for (final m in app.members) {
        rows.add([
          Text((m['name'] as String?) ?? '', style: egText(c, size: 13, weight: FontWeight.w600)),
          Text((m['ip'] as String?) ?? '—', style: egMono(c, size: 12.5, color: c.muted)),
          Text(t('link.direct'), style: egMono(c, size: 12.5, color: c.acc)),
          Text('—', style: egMono(c, size: 12.5, color: c.muted)),
        ]);
      }
    } else {
      rows.add([
        Text(app.hostName ?? '—', style: egText(c, size: 13, weight: FontWeight.w600)),
        Text(app.hostAddr, style: egMono(c, size: 12.5, color: c.muted)),
        Text(t('link.direct'), style: egMono(c, size: 12.5, color: c.acc)),
        Text('—', style: egMono(c, size: 12.5, color: c.muted)),
      ]);
    }

    return EgTable(
      headers: [t('th.player'), t('th.addr'), t('th.link'), t('th.ping')],
      rows: rows,
      flexes: const [4, 3, 2, 2],
    );
  }
}

// 联机三步:展开后逐条上浮。
class _GuideSteps extends StatelessWidget {
  final AppState app;
  const _GuideSteps({required this.app});

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    return StaggerIn(
      children: [
        for (final (i, key) in ['guide.1', 'guide.2', 'guide.3'].indexed)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              border: i > 0 ? Border(top: BorderSide(color: c.line)) : null,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('0${i + 1}', style: egMono(c, size: 12, color: c.acc)),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    app.langs.t(key),
                    style: egText(c, size: 13, color: c.muted, height: 1.6),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
