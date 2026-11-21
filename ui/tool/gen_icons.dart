// 由源图标生成 macOS 图标集与 Linux 桌面图标(尺寸固定,避免随包携带超大 PNG)。
import 'dart:io';

import 'package:image/image.dart' as img;

img.Image _resize(img.Image source, int size) => img.copyResize(
      source,
      width: size,
      height: size,
      interpolation: img.Interpolation.cubic,
    );

void main() {
  final source = img.decodeImage(File('assets/icon/icon.png').readAsBytesSync());
  if (source == null) {
    stderr.writeln('无法读取 assets/icon/icon.png');
    exit(1);
  }

  final appIconDir =
      Directory('macos/Runner/Assets.xcassets/AppIcon.appiconset');
  for (final size in <int>[16, 32, 64, 128, 256, 512, 1024]) {
    final scaled = img.copyResize(
      source,
      width: size,
      height: size,
      interpolation: img.Interpolation.cubic,
    );
    File('${appIconDir.path}/app_icon_$size.png')
        .writeAsBytesSync(img.encodePng(scaled));
  }

  final linuxIcon = img.copyResize(
    source,
    width: 256,
    height: 256,
    interpolation: img.Interpolation.cubic,
  );
  File('../packaging/linux/eglan.png')
      .writeAsBytesSync(img.encodePng(linuxIcon));

  // Windows 可执行文件图标:多尺寸 ICO(PNG 压缩项,Windows Vista 起支持)。
  final icoSizes = <int>[256, 128, 64, 48, 32, 16];
  final ico = img.Image.from(_resize(source, icoSizes.first));
  for (final size in icoSizes.skip(1)) {
    ico.addFrame(_resize(source, size));
  }
  File('windows/runner/resources/app_icon.ico')
      .writeAsBytesSync(img.encodeIco(ico));

  stdout.writeln('图标已生成');
}
