// 通用小部件:按钮、分段控件、下拉、开关、表格、代码块与终端。
// 全部取色来自主题令牌;状态层遵循 M3:悬停 8%、按压 12% 的着色叠加。
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../theme.dart';
import 'fx.dart';

// ---- 按钮 ----

enum EgBtnKind { primary, ghost, danger }

class EgButton extends StatefulWidget {
  final String label;
  final EgBtnKind kind;
  final bool small;
  final VoidCallback? onPressed;
  const EgButton({super.key, required this.label, this.kind = EgBtnKind.ghost, this.small = false, this.onPressed});

  @override
  State<EgButton> createState() => _EgButtonState();
}

class _EgButtonState extends State<EgButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final eg = Eg.of(context);
    final c = eg.c;
    final enabled = widget.onPressed != null;
    final (bg, fg, border) = switch (widget.kind) {
      EgBtnKind.primary => (c.acc, c.accInk, c.acc),
      EgBtnKind.ghost => (c.panel, c.text, c.line2),
      EgBtnKind.danger => (Colors.transparent, c.bad, c.line2),
    };
    final pad = widget.small ? const EdgeInsets.symmetric(horizontal: 12, vertical: 6) : const EdgeInsets.symmetric(horizontal: 16, vertical: 9);
    final radius = widget.small ? 10.0 : 12.0;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          transform: Matrix4.translationValues(0, enabled && _hover ? -1 : 0, 0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            boxShadow: enabled && widget.kind == EgBtnKind.primary ? c.accShadow : (widget.kind == EgBtnKind.ghost ? c.panelShadow : null),
          ),
          child: Material(
            color: bg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius),
              side: BorderSide(color: border),
            ),
            child: InkWell(
              onTap: widget.onPressed,
              borderRadius: BorderRadius.circular(radius),
              overlayColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.pressed)) return fg.withValues(alpha: 0.12);
                if (states.contains(WidgetState.hovered)) return fg.withValues(alpha: 0.08);
                return Colors.transparent;
              }),
              child: Padding(
                padding: pad,
                child: Text(
                  widget.label,
                  style: egText(c, size: widget.small ? 12 : 13, color: fg, weight: FontWeight.w600, height: 1.3),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---- 分段控件 ----

class EgSeg<T> extends StatefulWidget {
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;
  const EgSeg({super.key, required this.options, required this.value, required this.onChanged});

  @override
  State<EgSeg<T>> createState() => _EgSegState<T>();
}

class _EgSegState<T> extends State<EgSeg<T>> {
  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.panel2,
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, (value, label)) in widget.options.indexed)
            _SegBtn(
              c: c,
              label: label,
              selected: identical(value, widget.value) || value == widget.value,
              first: i == 0,
              onTap: () => widget.onChanged(value),
            ),
        ],
      ),
    );
  }
}

class _SegBtn extends StatelessWidget {
  final EgColors c;
  final String label;
  final bool selected;
  final bool first;
  final VoidCallback onTap;
  const _SegBtn({required this.c, required this.label, required this.selected, required this.first, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? c.panel : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(9),
        side: BorderSide(color: selected ? c.line2 : Colors.transparent),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        overlayColor: WidgetStateProperty.resolveWith(
          (states) => c.text.withValues(alpha: states.contains(WidgetState.pressed) ? 0.12 : states.contains(WidgetState.hovered) ? 0.08 : 0),
        ),
        child: Padding(
          padding: selected ? const EdgeInsets.symmetric(horizontal: 13, vertical: 5) : const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          child: Text(label, style: egText(c, size: 12, weight: FontWeight.w600, color: selected ? c.text : c.muted, height: 1.4)),
        ),
      ),
    );
  }
}

// ---- 自定义下拉 ----

class EgDropdown<T> extends StatefulWidget {
  final List<(T, String)> items;
  final T value;
  final ValueChanged<T> onChanged;
  const EgDropdown({super.key, required this.items, required this.value, required this.onChanged});

  @override
  State<EgDropdown<T>> createState() => _EgDropdownState<T>();
}

class _EgDropdownState<T> extends State<EgDropdown<T>> with SingleTickerProviderStateMixin {
  final _controller = OverlayPortalController();
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 180));
  final _link = LayerLink();
  bool get _open => _controller.isShowing;

  void _toggle() {
    if (_open) {
      _close();
    } else {
      _anim.forward(from: 0);
      _controller.show();
      setState(() {});
    }
  }

  void _close() {
    _controller.hide();
    setState(() {});
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    return OverlayPortal(
      controller: _controller,
      overlayChildBuilder: (context) {
        final curve = CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic);
        return Stack(
          children: [
            // 全屏屏障:点菜单外任意处收起;菜单叠在其上,选项点击不受影响。
            GestureDetector(
              onTap: _close,
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
            CompositedTransformFollower(
              link: _link,
              targetAnchor: Alignment.bottomLeft,
              followerAnchor: Alignment.topLeft,
              offset: const Offset(0, 6),
              child: AnimatedBuilder(
                animation: curve,
                builder: (context, child) => Opacity(
                  opacity: curve.value,
                  child: Transform.translate(
                    offset: Offset(0, (1 - curve.value) * -6),
                    child: child,
                  ),
                ),
                child: Material(
                  color: c.panel,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: c.line2)),
                  elevation: 0,
                  shadowColor: Colors.transparent,
                  // 菜单宽度随内容伸缩:隧道地址这类长标签不换行也不截断。
                  child: IntrinsicWidth(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: c.bigShadow,
                      ),
                      padding: const EdgeInsets.all(5),
                      constraints: const BoxConstraints(minWidth: 168, maxWidth: 360),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final (value, label) in widget.items)
                            _DdlOpt(
                              c: c,
                              label: label,
                              selected: value == widget.value,
                              onTap: () {
                                widget.onChanged(value);
                                _close();
                              },
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
      },
      child: CompositedTransformTarget(
        link: _link,
        child: Material(
          color: c.panel2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: c.line2)),
          child: InkWell(
            onTap: _toggle,
            borderRadius: BorderRadius.circular(10),
            overlayColor: WidgetStateProperty.resolveWith(
              (states) => c.text.withValues(alpha: states.contains(WidgetState.pressed) ? 0.12 : states.contains(WidgetState.hovered) ? 0.08 : 0),
            ),
            child: Container(
              constraints: const BoxConstraints(minWidth: 112, maxWidth: 320),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      widget.value == null ? '' : widget.items.firstWhere((it) => it.$1 == widget.value).$2,
                      style: egText(c, size: 12.5, height: 1.4),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 10),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    child: Icon(Icons.keyboard_arrow_down, size: 14, color: c.muted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DdlOpt extends StatelessWidget {
  final EgColors c;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _DdlOpt({required this.c, required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? c.accDim : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        overlayColor: WidgetStateProperty.resolveWith(
          (states) => c.text.withValues(alpha: states.contains(WidgetState.pressed) ? 0.12 : states.contains(WidgetState.hovered) ? 0.08 : 0),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Text(label, style: egText(c, size: 12.5, color: selected ? c.acc : c.muted, weight: selected ? FontWeight.w600 : FontWeight.w400, height: 1.4), maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}

// ---- 开关 ----

class EgSwitch extends StatefulWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const EgSwitch({super.key, required this.value, required this.onChanged});

  @override
  State<EgSwitch> createState() => _EgSwitchState();
}

class _EgSwitchState extends State<EgSwitch> {
  bool _press = false;

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    final on = widget.value;
    return GestureDetector(
      onTapDown: (_) => setState(() => _press = true),
      onTapUp: (_) => setState(() => _press = false),
      onTapCancel: () => setState(() => _press = false),
      onTap: () => widget.onChanged(!on),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 40,
        height: 22,
        decoration: BoxDecoration(
          color: on ? c.acc : c.panel2,
          border: Border.all(color: on ? c.acc : c.line2),
          borderRadius: BorderRadius.circular(999),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: on ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.all(1.5),
            width: 18,
            height: 18,
            transformAlignment: Alignment.center,
            transform: Matrix4.diagonal3Values(_press ? 1.35 : 1, 1, 1),
            decoration: BoxDecoration(color: on ? c.accInk : c.faint, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }
}

// ---- 版式小件 ----

// 小节标题:标题 + 等宽注脚,沿基线对齐。
class Sect extends StatelessWidget {
  final String title;
  final String? sub;
  const Sect({super.key, required this.title, this.sub});

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    return Padding(
      padding: const EdgeInsets.only(top: 32, bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(title, style: egText(c, size: 15, weight: FontWeight.w600)),
          if (sub != null) ...[
            const SizedBox(width: 10),
            Text(sub!, style: egMono(c, size: 11, color: c.faint)),
          ],
        ],
      ),
    );
  }
}

// 软面板:数据与设置的主形态。
class EgPanel extends StatelessWidget {
  final Widget child;
  final Color? border;
  final double radius;
  const EgPanel({super.key, required this.child, this.border, this.radius = 16});

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    return Container(
      decoration: BoxDecoration(
        color: c.panel,
        border: Border.all(color: border ?? c.line),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: c.panelShadow,
      ),
      child: child,
    );
  }
}

// 等宽小标签:tag.host / tag.me / chip.wip 等一行说明。
class EgTag extends StatelessWidget {
  final String text;
  final Color? color;
  const EgTag(this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    return Text(text, style: egMono(c, size: 11, color: color ?? c.muted));
  }
}

// 带边框的开发中徽章。
class EgChip extends StatelessWidget {
  final String text;
  const EgChip(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(border: Border.all(color: c.line2), borderRadius: BorderRadius.circular(8)),
      child: Text(text, style: egMono(c, size: 11, color: c.faint)),
    );
  }
}

// ---- 数据表 ----

class EgTable extends StatelessWidget {
  final List<String> headers;
  final List<List<Widget>> rows;
  final List<int> flexes;
  const EgTable({super.key, required this.headers, required this.rows, required this.flexes});

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    return EgPanel(
      radius: 16,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                for (final (i, h) in headers.indexed)
                  Expanded(
                    flex: flexes[i],
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                      child: Text(h, style: egText(c, size: 11.5, weight: FontWeight.w500, color: c.faint, height: 1.4)),
                    ),
                  ),
              ],
            ),
            Container(height: 1, color: c.line),
            for (final (i, row) in rows.indexed) ...[
              _Row(c: c, cells: row, flexes: flexes, last: i == rows.length - 1),
              if (i != rows.length - 1) Container(height: 1, color: c.line),
            ],
          ],
        ),
      ),
    );
  }
}

class _Row extends StatefulWidget {
  final EgColors c;
  final List<Widget> cells;
  final List<int> flexes;
  final bool last;
  const _Row({required this.c, required this.cells, required this.flexes, required this.last});

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        color: _hover ? c.panel2 : Colors.transparent,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (final (i, cell) in widget.cells.indexed)
              Expanded(
                flex: widget.flexes[i],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: cell,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---- 房间码块:全页唯一的记忆点,像素角括号悬停点亮 ----

class EgCodeBlock extends StatefulWidget {
  final String label;
  final String code;
  final String copyLabel;
  final VoidCallback onCopy;
  const EgCodeBlock({super.key, required this.label, required this.code, required this.copyLabel, required this.onCopy});

  @override
  State<EgCodeBlock> createState() => _EgCodeBlockState();
}

class _EgCodeBlockState extends State<EgCodeBlock> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    final brkColor = _hover ? c.acc : c.line2;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
            decoration: BoxDecoration(
              color: c.panel,
              border: Border.all(color: c.line2),
              borderRadius: BorderRadius.circular(16),
              boxShadow: c.panelShadow,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.label, style: egText(c, size: 11.5, color: c.muted, height: 1.4)),
                      const SizedBox(height: 6),
                      SelectableText(
                        widget.code,
                        style: egMono(c, size: 26, weight: FontWeight.w700, color: c.acc, letterSpacing: 2.5, height: 1.2),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 20),
                EgButton(label: widget.copyLabel, small: true, onPressed: widget.onCopy),
              ],
            ),
          ),
          // 像素角括号:品牌像素语言的唯一装饰性出现,悬停点亮。
          for (final entry in const [
            ('tl', 0),
            ('tr', 1),
            ('bl', 2),
            ('brc', 3),
          ].indexed)
            Positioned(
              top: entry.$2 == 0 || entry.$2 == 1 ? -2 : null,
              bottom: entry.$2 == 2 || entry.$2 == 3 ? -2 : null,
              left: entry.$2 == 0 || entry.$2 == 2 ? -2 : null,
              right: entry.$2 == 1 || entry.$2 == 3 ? -2 : null,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  border: Border(
                    top: entry.$2 == 0 || entry.$2 == 1 ? BorderSide(color: brkColor, width: 2) : BorderSide.none,
                    bottom: entry.$2 == 2 || entry.$2 == 3 ? BorderSide(color: brkColor, width: 2) : BorderSide.none,
                    left: entry.$2 == 0 || entry.$2 == 2 ? BorderSide(color: brkColor, width: 2) : BorderSide.none,
                    right: entry.$2 == 1 || entry.$2 == 3 ? BorderSide(color: brkColor, width: 2) : BorderSide.none,
                  ),
                  borderRadius: BorderRadius.only(
                    topLeft: entry.$2 == 0 ? const Radius.circular(3) : Radius.zero,
                    topRight: entry.$2 == 1 ? const Radius.circular(3) : Radius.zero,
                    bottomLeft: entry.$2 == 2 ? const Radius.circular(3) : Radius.zero,
                    bottomRight: entry.$2 == 3 ? const Radius.circular(3) : Radius.zero,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---- 终端:连接过程以控制台输出呈现,与真实日志同构 ----

class EgTerminal extends StatelessWidget {
  final List<JoinLine> lines;
  const EgTerminal({super.key, required this.lines});

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    return EgPanel(
      radius: 14,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: _TermLine(c: c, line: line),
              ),
          ],
        ),
      ),
    );
  }
}

class _TermLine extends StatelessWidget {
  final EgColors c;
  final JoinLine line;
  const _TermLine({required this.c, required this.line});

  @override
  Widget build(BuildContext context) {
    switch (line.kind) {
      case LogKind.ok:
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('> ', style: egMono(c, size: 12.5, color: c.acc)),
            Expanded(child: Text(line.text, style: egMono(c, size: 12.5, color: c.text))),
          ],
        );
      case LogKind.run:
        return Row(
          children: [
            HopSpinner(c: c),
            const SizedBox(width: 4),
            Expanded(child: Text(line.text, style: egMono(c, size: 12.5, color: c.text))),
          ],
        );
      case LogKind.err:
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('> ', style: egMono(c, size: 12.5, color: c.bad)),
            Expanded(child: Text(line.text, style: egMono(c, size: 12.5, color: c.bad))),
          ],
        );
    }
  }
}

// 错误面板:标题 + 解释 + 重试。
class EgErrorTerm extends StatelessWidget {
  final String title;
  final String body;
  final String? retryLabel;
  final VoidCallback? onRetry;
  const EgErrorTerm({super.key, required this.title, required this.body, this.retryLabel, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.badDim,
        border: Border.all(color: c.bad),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: egMono(c, size: 12.5, weight: FontWeight.w700, color: c.bad, height: 1.5)),
          const SizedBox(height: 6),
          Text(body, style: egText(c, size: 12.5, color: c.text, height: 1.6)),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            EgButton(label: retryLabel ?? '', small: true, onPressed: onRetry),
          ],
        ],
      ),
    );
  }
}

// ---- 文本输入 ----
class EgInput extends StatelessWidget {
  final TextEditingController controller;
  final String? hint;
  final bool mono;
  final bool center;
  final double width;
  final int? maxLength;
  final List<TextInputFormatter>? formatters;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final FocusNode? focusNode;
  const EgInput({super.key, required this.controller, this.hint, this.mono = false, this.center = false, this.width = 86, this.maxLength, this.formatters, this.onChanged, this.onSubmitted, this.focusNode});

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    final style = mono ? egMono(c, size: 12.5, color: c.text) : egText(c, size: 12.5, color: c.text, height: 1.4);
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        maxLength: maxLength,
        inputFormatters: formatters,
        style: style,
        textAlign: center ? TextAlign.center : TextAlign.left,
        cursorColor: c.acc,
        decoration: InputDecoration(
          isDense: true,
          counterText: '',
          hintText: hint,
          hintStyle: egMono(c, size: 12.5, color: c.faint),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          filled: true,
          fillColor: c.panel2,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: c.line2),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: c.acc),
          ),
        ),
      ),
    );
  }
}

// ---- 弹窗骨架:温室质感的对话框(面板底、线框、大圆角) ----

class EgSkinDialog extends StatelessWidget {
  final String title;
  final Widget child;
  final List<Widget> actions;
  const EgSkinDialog({super.key, required this.title, required this.child, required this.actions});

  @override
  Widget build(BuildContext context) {
    final c = Eg.of(context).c;
    return Dialog(
      backgroundColor: c.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: BorderSide(color: c.line2)),
      child: Container(
        width: 420,
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          boxShadow: c.bigShadow,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: egDisplay(c, size: 20)),
            const SizedBox(height: 14),
            child,
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (final (i, a) in actions.indexed) ...[
                  if (i > 0) const SizedBox(width: 8),
                  a,
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
