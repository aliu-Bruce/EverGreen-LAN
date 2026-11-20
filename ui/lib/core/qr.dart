// 二维码工具:用 zxing2 编解码邀请链接,image 包做 PNG 像素转换。
// 只处理 Byte 模式的短文本(邀请链接),白底黑块,留出静默区便于扫描。
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

// 生成矩阵:返回 (size, 每个模块是否黑) 的方阵,size = 模块数。
// 超长内容返回 null(邀请链接不会触发)。
class QrMatrixData {
  final int size;
  final Uint8List dark; // size*size,1=黑
  const QrMatrixData(this.size, this.dark);

  bool isDark(int row, int col) => dark[row * size + col] == 1;
}

QrMatrixData? encodeQr(String data, {ErrorCorrectionLevel? level}) {
  try {
    final code = Encoder.encode(data, level ?? ErrorCorrectionLevel.m);
    final matrix = code.matrix;
    if (matrix == null) return null;
    final size = matrix.width;
    final dark = Uint8List(size * size);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        if (matrix.get(x, y) == 1) dark[y * size + x] = 1;
      }
    }
    return QrMatrixData(size, dark);
  } catch (_) {
    return null;
  }
}

// 把矩阵渲染成 PNG 字节。quiet 为静默区模块数(标准建议 4)。
// scale 为每个模块的像素边长,固定 8 → 约 300~400px 的图。
Uint8List? renderQrPng(String data, {int quiet = 4, int scale = 8, ErrorCorrectionLevel? level}) {
  final m = encodeQr(data, level: level);
  if (m == null) return null;
  final side = (m.size + quiet * 2) * scale;
  final image = img.Image(width: side, height: side, numChannels: 4);
  final white = img.ColorRgba8(0xFF, 0xFF, 0xFF, 0xFF);
  final black = img.ColorRgba8(0, 0, 0, 0xFF);
  img.fill(image, color: white);
  for (var y = 0; y < m.size; y++) {
    for (var x = 0; x < m.size; x++) {
      if (!m.isDark(y, x)) continue;
      img.fillRect(
        image,
        x1: (x + quiet) * scale,
        y1: (y + quiet) * scale,
        x2: (x + quiet + 1) * scale,
        y2: (y + quiet + 1) * scale,
        color: black,
      );
    }
  }
  return img.encodePng(image);
}

// 从图片字节中解码出第一条文本;失败返回 null。
// 支持 PNG/JPEG 等 image 包能识别的格式。
String? decodeQr(Uint8List bytes) {
  try {
    final image = img.decodeImage(bytes);
    if (image == null) return null;
    // zxing2 需要 ABGR 顺序的 32 位像素缓冲。
    final rgba = image.convert(numChannels: 4).getBytes(order: img.ChannelOrder.abgr);
    final source = RGBLuminanceSource(
      image.width,
      image.height,
      Int32List.view(rgba.buffer, rgba.offsetInBytes, (image.width * image.height)),
    );
    final bitmap = BinaryBitmap(GlobalHistogramBinarizer(source));
    final result = QRCodeReader().decode(bitmap);
    return result.text;
  } catch (_) {
    return null;
  }
}
