// 二维码显示:把 QrMatrixData 画成白底黑块的方阵,带静默区。
// 白底是标准要求(相机对反色识别差),不随主题变化。
import 'package:flutter/widgets.dart';

import '../core/qr.dart';

class EgQrView extends StatelessWidget {
  final QrMatrixData matrix;
  final double size;
  final int quiet;
  const EgQrView({super.key, required this.matrix, this.size = 220, this.quiet = 4});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _QrPainter(matrix, quiet)),
    );
  }
}

class _QrPainter extends CustomPainter {
  final QrMatrixData matrix;
  final int quiet;
  const _QrPainter(this.matrix, this.quiet);

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.shortestSide / (matrix.size + quiet * 2);
    final origin = cell * quiet;
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFFFFFF));
    final path = Path();
    for (var y = 0; y < matrix.size; y++) {
      for (var x = 0; x < matrix.size; x++) {
        if (matrix.isDark(y, x)) {
          path.addRect(Rect.fromLTWH(origin + x * cell, origin + y * cell, cell, cell));
        }
      }
    }
    canvas.drawPath(path, Paint()..color = const Color(0xFF000000));
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.matrix != matrix || old.quiet != quiet;
}
