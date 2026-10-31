import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:native_device_orientation/native_device_orientation.dart';

/// Camera preview that stays upright relative to the PHYSICAL device
/// orientation even though the app UI is portrait-locked.
///
/// On Android the camera_android_camerax implementation's
/// `buildPreview()` applies a platform correction of
/// `display rotation − reported UI orientation`. Under a UI lock the
/// reported orientation stays portraitUp while the display rotation
/// keeps tracking the physical tilt, so the feed swings as the phone
/// moves. This widget adds back the reported orientation and subtracts
/// the real sensor orientation — leaving the texture presented as the
/// platform delivered it, upright for however the device is held.
class AutoUprightCameraPreview extends StatefulWidget {
  const AutoUprightCameraPreview(this.controller, {super.key});

  final CameraController controller;

  @override
  State<AutoUprightCameraPreview> createState() =>
      _AutoUprightCameraPreviewState();
}

class _AutoUprightCameraPreviewState extends State<AutoUprightCameraPreview> {
  /// Real accelerometer-based orientation — what the camera plugin's
  /// UI-locked stream can't report.
  NativeDeviceOrientation _physical = NativeDeviceOrientation.portraitUp;
  StreamSubscription<NativeDeviceOrientation>? _orientationSub;

  static int _turns(DeviceOrientation? orientation) => switch (orientation) {
        DeviceOrientation.landscapeRight => 1,
        DeviceOrientation.portraitDown => 2,
        DeviceOrientation.landscapeLeft => 3,
        _ => 0,
      };

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final communicator = NativeDeviceOrientationCommunicator();
      unawaited(communicator.orientation(useSensor: true).then((o) {
        if (mounted && o != NativeDeviceOrientation.unknown) {
          setState(() => _physical = o);
        }
      }).catchError((_) {}));
      _orientationSub = communicator
          .onOrientationChanged(useSensor: true)
          .listen((o) {
        if (mounted && o != NativeDeviceOrientation.unknown && o != _physical) {
          setState(() => _physical = o);
        }
      });
    }
  }

  @override
  void dispose() {
    _orientationSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (!controller.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.tealAccent),
      );
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return CameraPreview(controller);
    }
    return ValueListenableBuilder<CameraValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final size = value.previewSize;
        if (size == null) return controller.buildPreview();

        final isFront = controller.description.lensDirection ==
            CameraLensDirection.front;

        // Cancel the plugin's (display − ui) correction: add back the
        // reported UI orientation, subtract the real physical orientation.
        var correction =
            _turns(value.deviceOrientation) - _turns(_physical.deviceOrientation);
        // While the video recorder is bound, the capture session is
        // reconfigured and the delivered surface arrives rotated +90°
        // clockwise — counter-rotate by one turn for the recording window.
        if (value.isRecordingVideo) correction -= 1;

        Widget child = RotatedBox(
          quarterTurns: correction,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: controller.buildPreview(),
          ),
        );
        // The front lens follows the exact same rotation logic as the
        // back camera first (correction + recording compensation), then
        // gets its mirror flip in DISPLAY space — mirroring the already-
        // upright image. Mirroring inside the RotatedBox instead makes
        // the horizontal flip become a vertical flip once the feed is
        // rotated 90°, so the front preview stops matching the back.
        if (isFront) {
          child = Transform.scale(
            scaleX: -1,
            alignment: Alignment.center,
            child: child,
          );
        }

        return SizedBox.expand(
          child: FittedBox(fit: BoxFit.cover, child: child),
        );
      },
    );
  }
}
