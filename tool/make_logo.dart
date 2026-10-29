import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart';

/// Crops the pasted icon screenshot down to the rounded-square glyph and
/// exports a 1024x1024 PNG for use as the in-app logo + launcher icon.
void main() {
  const srcPath =
      r'C:\Users\tanak\AppData\Local\Temp\devin-pasted-images\1791814349615929200-40564-3-pasted.png';
  final img = decodePng(File(srcPath).readAsBytesSync());
  if (img == null) {
    stderr.writeln('Could not decode $srcPath');
    exit(1);
  }

  // The dark launcher background is sampled from the corner; find the
  // bounding box of everything noticeably brighter (the gradient icon).
  final bg = img.getPixel(0, 0);
  var minX = img.width;
  var minY = img.height;
  var maxX = 0;
  var maxY = 0;
  for (var y = 0; y < img.height; y++) {
    for (var x = 0; x < img.width; x++) {
      final p = img.getPixel(x, y);
      final diff = (p.r - bg.r).abs() + (p.g - bg.g).abs() + (p.b - bg.b).abs();
      if (diff > 40) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  final icon = copyCrop(
    img,
    x: minX,
    y: minY,
    width: maxX - minX + 1,
    height: maxY - minY + 1,
  );

  // Pad to a square using the background colour so corners stay dark, then
  // upscale — the launcher icon generator expects a large square source.
  final side = math.max(icon.width, icon.height);
  final square = Image(width: side, height: side, numChannels: 4);
  fill(
    square,
    color: ColorRgba8(
      bg.r.toInt(),
      bg.g.toInt(),
      bg.b.toInt(),
      255,
    ),
  );
  compositeImage(
    square,
    icon,
    dstX: (side - icon.width) ~/ 2,
    dstY: (side - icon.height) ~/ 2,
  );
  final out = copyResize(square, width: 1024, height: 1024);
  File('assets/logo.png').writeAsBytesSync(encodePng(out));
  stdout.writeln(
    'Cropped ${img.width}x${img.height} -> icon ${icon.width}x${icon.height} -> assets/logo.png 1024x1024',
  );
}
