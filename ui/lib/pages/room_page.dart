// 房间页:房间码(或房主信息)、成员表、联机指南、退出。
// 主机与成员共用一页;名册由 opMembers 提供,主机行由界面自行合成。
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../theme.dart';
import '../widgets/eg.dart';
import '../widgets/fx.dart';

class RoomPage extends StatefulWidget {
  final VoidCallback goHome;
  const RoomPage({super.key, required this.goHome});

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  bool _guideOpen = false;
  bool _copied = false;

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
      return StaggerIn(
        children: [
          const SizedBox(height: 48),
          Text(app.langs.t('room.notInRoom'), style: egText(c, size: 13.5, color: c.muted)),
          const SizedBox(height: 18),
          Align(
            alignment: Alignment.centerLeft,
            child: EgButton(label: app.langs.t('nav.home'), onPressed: widget.goHome),
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
        if (hosting)
          Padding(
            padding: const EdgeInsets.only(top: 22, bottom: 8),
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
          )
        else
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
        Padding(
          padding: const EdgeInsets.only(bottom: 28),
          child: Text(
            app.langs.t('room.shareHint'),
            style: egText(c, size: 12.5, color: c.faint),
          ),
        ),

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

  void _showQr(BuildContext context, AppState app) {
    final c = Eg.of(context).c;
    showDialog<void>(
      context: context,
      builder: (context) => EgSkinDialog(
        title: app.langs.t('qr.title'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              app.langs.t('qr.hint', {'room': app.hostName ?? ''}),
              style: egText(c, size: 13.5, color: c.muted, height: 1.6),
            ),
            const SizedBox(height: 18),
            SelectableText(app.code ?? '', style: egMono(c, size: 22, weight: FontWeight.w700, color: c.acc, letterSpacing: 2)),
            const SizedBox(height: 10),
            Text(app.langs.t('join.peer'), style: egText(c, size: 11.5, color: c.muted)),
            SelectableText(app.selfIp ?? '', style: egMono(c, size: 13, color: c.text)),
            const SizedBox(height: 14),
            EgChip(app.langs.t('chip.wip')),
          ],
        ),
        actions: [
          EgButton(label: app.langs.t('btn.close'), small: true, onPressed: () => Navigator.of(context).pop()),
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
