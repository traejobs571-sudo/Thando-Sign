import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

/// Converts a streamed [CameraImage] to a decoded RGB [img.Image],
/// downsampling during conversion so it stays cheap on the UI isolate.
/// Handles Android YUV420_888 and single-plane BGRA (iOS).
/// [rotationDeg] corrects for the sensor's physical orientation — Android
/// camera buffers are typically stored 90° off from portrait display.
img.Image? cameraImageToImage(
  CameraImage frame, {
  int targetWidth = 560,
  int rotationDeg = 0,
}) {
  try {
    img.Image decoded;
    if (frame.planes.length == 1) {
      decoded = img.Image.fromBytes(
        width: frame.width,
        height: frame.height,
        bytes: frame.planes.first.bytes.buffer,
        order: img.ChannelOrder.bgra,
      );
    } else {
      decoded = _yuv420ToImage(frame, targetWidth: targetWidth);
    }
    if (rotationDeg != 0) {
      decoded = img.copyRotate(decoded, angle: rotationDeg);
    }
    return decoded;
  } catch (_) {
    return null;
  }
}

/// YUV420 → RGB with built-in downsampling: sampling every `stride`
/// source pixel keeps the loop cheap.
img.Image _yuv420ToImage(CameraImage frame, {int targetWidth = 560}) {
  final srcW = frame.width;
  final srcH = frame.height;
  final stride = (srcW / targetWidth).ceil().clamp(1, srcW);
  final w = srcW ~/ stride;
  final h = srcH ~/ stride;

  final yPlane = frame.planes[0];
  final uPlane = frame.planes[1];
  final vPlane = frame.planes[2];
  final yRowStride = yPlane.bytesPerRow;
  final uvRowStride = uPlane.bytesPerRow;
  final uvPixelStride = uPlane.bytesPerPixel ?? 1;

  final out = img.Image(width: w, height: h);
  for (var oy = 0; oy < h; oy++) {
    final sy = oy * stride;
    final yOff = sy * yRowStride;
    final uvOff = (sy >> 1) * uvRowStride;
    for (var ox = 0; ox < w; ox++) {
      final sx = ox * stride;
      final yv = yPlane.bytes[yOff + sx] & 0xFF;
      final uvIdx = uvOff + (sx >> 1) * uvPixelStride;
      final uu = uPlane.bytes[uvIdx] & 0xFF;
      final vv = vPlane.bytes[uvIdx] & 0xFF;

      // Integer-only BT.601 conversion — much faster than doubles.
      var r = yv + ((91881 * (vv - 128)) >> 16);
      var g = yv - ((22554 * (uu - 128) + 46802 * (vv - 128)) >> 16);
      var b = yv + ((116130 * (uu - 128)) >> 16);
      out.setPixelRgb(
        ox,
        oy,
        r.clamp(0, 255),
        g.clamp(0, 255),
        b.clamp(0, 255),
      );
    }
  }
  return out;
}
