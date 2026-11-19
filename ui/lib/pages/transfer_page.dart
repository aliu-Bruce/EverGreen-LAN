// 传输页:主机与成员之间点对点发文件。
// 一条传输 = 一条可靠流;界面只做目标选择、报价确认、进度与记录展示。
import 'package:material_ui/material_ui.dart';

import '../core/app_state.dart';
import '../core/ipc.dart';
import '../theme.dart';
import '../widgets/eg.dart';
import '../widgets/fx.dart';

class TransferPage extends StatefulWidget {
  const TransferPage({super.key});

  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage> {
  String? _target; // 选中的目标成员 IP
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => AppState.of(context).refreshMembers());
  }

  // 目标列表:主机可选各成员,成员只有房主一个目标。
  List<(String, String)> _targets(AppState app) {
    if (app.room == RoomState.hosting) {
      return [
        for (final m in app.members)
          if (((m['ip'] as String?) ?? '').isNotEmpty)
            ((m['ip'] as String), '${(m['name'] as String?) ?? '—'} · ${m['ip']}'),
      ];
    }
    if (app.room == RoomState.joined) {
      final addr = app.hostAddr;
      return [(addr, '${app.hostName ?? addr} · $addr')];
    }
    return const [];
  }

  String? _targetFor(AppState app) {
    final targets = _targets(app);
    if (targets.isEmpty) return null;
    for (final t in targets) {
      if (t.$1 == _target) return t.$1;
    }
    return targets.first.$1;
  }

  Future<void> _pickAndSend(AppState app) async {
    final to = _targetFor(app);
    if (to == null) {
      setState(() => _error = app.langs.t('tr.noMember'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final path = await app.pickFile();
      if (path != null) {
        final err = await app.sendFile(path, to: to);
        if (err != null && mounted) setState(() => _error = err);
      }
    } on IpcError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _accept(AppState app, TransferTask t) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final err = await app.acceptTransfer(t);
      if (err != null && mounted) setState(() => _error = err);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject(AppState app, TransferTask t) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final err = await app.rejectTransfer(t);
      if (err != null && mounted) setState(() => _error = err);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.of(context);
    final c = Eg.of(context).c;
    final t = (k, [Map<String, Object?>? vars]) => app.langs.t(k, vars);

    final targets = _targets(app);
    final offers = app.transfers.where((x) => x.awaiting).toList();
    final active = app.transfers.where((x) => x.phase == TransferPhase.active).toList();
    final finished = app.transfers.where((x) => x.finished).toList();

    return StaggerIn(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t('tr.title'), style: egDisplay(c, size: 30, letterSpacing: -0.01, height: 1.2)),
            const SizedBox(width: 14),
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(t('tr.meta'), style: egText(c, size: 12.5, color: c.muted)),
            ),
          ],
        ),

        if (!app.inRoom)
          Padding(
            padding: const EdgeInsets.only(top: 22),
            child: DashedBorder(
              color: c.line2,
              radius: 18,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 44),
                child: Column(
                  children: [
                    PixelArt(rects: egChainArt(c), cols: 14, rows: 10, scale: 7),
                    const SizedBox(height: 14),
                    Text(t('tr.notInRoom'), style: egDisplay(c, size: 16)),
                    const SizedBox(height: 8),
                    Text(
                      t('tr.notInRoomSub'),
                      textAlign: TextAlign.center,
                      style: egText(c, size: 12.5, color: c.faint, height: 1.6),
                    ),
                  ],
                ),
              ),
            ),
          )
        else ...[
          // 发送:目标 + 选择文件;选中即发送。
          Padding(
            padding: const EdgeInsets.only(top: 22),
            child: EgPanel(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(t('tr.sendTo'), style: egText(c, size: 11.5, color: c.muted)),
                              const SizedBox(height: 7),
                              if (targets.isEmpty)
                                Text(t('tr.noMember'), style: egText(c, size: 13, color: c.faint))
                              else
                                EgDropdown<String>(
                                  items: targets,
                                  value: _targetFor(app)!,
                                  onChanged: (v) => setState(() => _target = v),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        EgButton(
                          label: t('tr.pick'),
                          kind: EgBtnKind.primary,
                          onPressed: (targets.isEmpty || _busy) ? null : () => _pickAndSend(app),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(t('tr.pickHint'), style: egText(c, size: 11.5, color: c.faint, height: 1.5)),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      SelectableText(_error!, style: egText(c, size: 12, color: c.bad, height: 1.5)),
                    ],
                  ],
                ),
              ),
            ),
          ),

          if (offers.isNotEmpty) ...[
            Sect(title: t('tr.offers'), sub: t('tr.offersSub')),
            _rows(c, [
              for (final o in offers)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
                  child: Row(
                    children: [
                      Icon(Icons.south_west, size: 15, color: c.acc),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(o.name, style: egText(c, size: 13, weight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 4),
                            Text(
                              '${t('tr.from')} ${app.peerLabel(o.peer)} · ${_bytes(o.size)}',
                              style: egText(c, size: 11.5, color: c.muted),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      EgButton(
                        label: t('tr.accept'),
                        kind: EgBtnKind.primary,
                        small: true,
                        onPressed: _busy ? null : () => _accept(app, o),
                      ),
                      const SizedBox(width: 8),
                      EgButton(
                        label: t('tr.reject'),
                        small: true,
                        onPressed: _busy ? null : () => _reject(app, o),
                      ),
                    ],
                  ),
                ),
            ]),
          ],

          if (active.isNotEmpty) ...[
            Sect(title: t('tr.active'), sub: t('tr.activeSub', {'n': '${active.length}'})),
            _rows(c, [for (final a in active) _TransferRow(app: app, task: a)]),
          ],

          Row(
            children: [
              Expanded(child: Sect(title: t('tr.history'), sub: t('tr.historySub'))),
              if (finished.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 22),
                  child: EgButton(label: t('tr.clear'), small: true, onPressed: app.clearFinishedTransfers),
                ),
            ],
          ),
          if (finished.isEmpty)
            EgPanel(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 26),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.inbox_outlined, size: 16, color: c.faint),
                    const SizedBox(width: 8),
                    Text(t('tr.empty'), style: egText(c, size: 12.5, color: c.faint)),
                  ],
                ),
              ),
            )
          else
            _rows(c, [for (final f in finished) _TransferRow(app: app, task: f)]),
        ],
      ],
    );
  }

  // 面板内多行,行间一条细线。
  Widget _rows(EgColors c, List<Widget> rows) {
    return EgPanel(
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Container(height: 1, color: c.line),
            rows[i],
          ],
        ],
      ),
    );
  }
}

class _TransferRow extends StatelessWidget {
  final AppState app;
  final TransferTask task;
  const _TransferRow({required this.app, required this.task});

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    final t = (k) => app.langs.t(k);
    final running = task.phase == TransferPhase.active;
    final failed = task.phase == TransferPhase.failed;
    final status = running
        ? (task.done == 0 && !task.incoming ? t('tr.waiting') : '${(task.progress * 100).floor()}% · ${_bytes(task.done)} / ${_bytes(task.size)}')
        : failed
            ? (task.error ?? t('tr.failed'))
            : t('tr.done');

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(task.incoming ? Icons.south_west : Icons.north_east, size: 15, color: task.incoming ? c.acc : c.muted),
              const SizedBox(width: 10),
              Expanded(
                child: Text(task.name, style: egText(c, size: 13, weight: FontWeight.w600), overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 12),
              Text(_bytes(task.size), style: egMono(c, size: 11.5, color: c.faint)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${task.incoming ? t('tr.from') : t('tr.to')} ${app.peerLabel(task.peer)}',
                  style: egText(c, size: 11.5, color: c.muted),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                status,
                style: egText(c, size: 11.5, color: failed ? c.bad : (running ? c.muted : c.acc)),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          if (running) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                height: 3,
                child: Stack(
                  children: [
                    Positioned.fill(child: ColoredBox(color: c.line)),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: task.progress,
                        child: ColoredBox(color: c.acc),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (task.phase == TransferPhase.done && task.incoming && task.path != null) ...[
            const SizedBox(height: 5),
            Text(
              '${t('tr.savedTo')} ${task.path}',
              style: egMono(c, size: 11, color: c.faint),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

// 人类可读的字节数;传输与进度共用同一套单位。
String _bytes(int n) {
  if (n < 1024) return '$n B';
  const units = ['KiB', 'MiB', 'GiB', 'TiB'];
  var v = n / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}
