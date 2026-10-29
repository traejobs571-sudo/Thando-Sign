import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';

import 'auto_upright_camera_preview.dart';

/// A self-contained, portrait-locked camera card for sign-language
/// recording. The preview stays upright on Android even when
/// `startVideoRecording()` is called, and the recorded file is handed
/// back through [onVideoRecorded].
class SignTranslatorCameraCard extends StatefulWidget {
  final List<CameraDescription> cameras;
  final Function(File videoFile) onVideoRecorded;

  const SignTranslatorCameraCard({
    super.key,
    required this.cameras,
    required this.onVideoRecorded,
  });

  @override
  State<SignTranslatorCameraCard> createState() =>
      _SignTranslatorCameraCardState();
}

class _SignTranslatorCameraCardState extends State<SignTranslatorCameraCard>
    with WidgetsBindingObserver {
  CameraController? _controller;
  bool _isCameraInitialized = false;
  bool _isRecording = false;
  int _selectedCameraIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _initCamera(_selectedCameraIndex);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  // Handle app lifecycle (background/foreground) safely.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _controller;
    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      cameraController.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera(_selectedCameraIndex);
    }
  }

  /// Initializes the camera once and locks orientation so it never flips on record.
  Future<void> _initCamera(int cameraIndex) async {
    if (widget.cameras.isEmpty) return;

    final previousController = _controller;
    final CameraController newController = CameraController(
      widget.cameras[cameraIndex],
      ResolutionPreset.high, // Avoid 'max'/'ultraHigh' — some Androids glitch.
      enableAudio: false, // Sign-language translation doesn't need audio.
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    await previousController?.dispose();

    if (mounted) {
      setState(() {
        _controller = newController;
        _isCameraInitialized = false;
      });
    }

    try {
      await newController.initialize();

      // One-time lock→unlock arms CameraX's default-rotation path so a
      // recording started later is stamped with the physical orientation
      // without touching orientation mid-session.
      await newController.lockCaptureOrientation(DeviceOrientation.portraitUp);
      await newController.unlockCaptureOrientation();
      // Use default camera behavior — no focus/exposure mode overrides

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
        });
      }
    } on CameraException catch (e) {
      debugPrint('Error initializing camera: ${e.description}');
    }
  }

  /// Starts recording without re-initializing or rotating the preview.
  Future<void> _startRecordingSession() async {
    final CameraController? cameraController = _controller;
    if (cameraController == null ||
        !cameraController.value.isInitialized ||
        cameraController.value.isRecordingVideo) {
      return;
    }

    try {
      // No lockCaptureOrientation here — mid-session orientation calls
      // reconfigure the capture session and rotate the live preview. The
      // init-time lock→unlock already armed CameraX's default-rotation
      // path, so the recording is stamped with the physical orientation.
      await cameraController.startVideoRecording();

      if (mounted) {
        setState(() {
          _isRecording = true;
        });
      }
    } on CameraException catch (e) {
      debugPrint('Error starting video recording: ${e.description}');
    }
  }

  /// Stops recording and returns the upright portrait MP4 file for the API.
  Future<void> _stopAndTranslate() async {
    final CameraController? cameraController = _controller;
    if (cameraController == null || !cameraController.value.isRecordingVideo) {
      return;
    }

    try {
      final XFile recordedFile = await cameraController.stopVideoRecording();
      try {
        await cameraController.unlockCaptureOrientation();
      } catch (_) {}

      if (mounted) {
        setState(() {
          _isRecording = false;
        });
      }

      // Pass the recorded upright video file to your API uploader.
      widget.onVideoRecorded(File(recordedFile.path));
    } on CameraException catch (e) {
      debugPrint('Error stopping video recording: ${e.description}');
    }
  }

  /// Switches between the front and back cameras cleanly.
  void _switchCamera() {
    if (widget.cameras.length < 2 || _isRecording) return;
    _selectedCameraIndex = (_selectedCameraIndex + 1) % widget.cameras.length;
    _initCamera(_selectedCameraIndex);
  }

  /// Builds the switch and record controls, rotating them to stay readable.
  Widget _buildControls(int turns) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        RotatedBox(
          quarterTurns: turns,
          child: IconButton(
            onPressed: _isRecording ? null : _switchCamera,
            icon: const Icon(Icons.cameraswitch_outlined, color: Colors.white),
          ),
        ),
        RotatedBox(
          quarterTurns: turns,
          child: GestureDetector(
            onTap: _isRecording ? _stopAndTranslate : _startRecordingSession,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isRecording ? Colors.red : Colors.transparent,
                    border: Border.all(color: Colors.white, width: 4),
                  ),
                  child: Center(
                    child: Container(
                      width: _isRecording ? 24 : 28,
                      height: _isRecording ? 24 : 28,
                      decoration: BoxDecoration(
                        color: _isRecording ? Colors.white : Colors.red,
                        borderRadius: BorderRadius.circular(
                            _isRecording ? 4 : 50),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _isRecording ? 'Stop & translate' : 'Record session',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 440, // Matches a rounded card layout.
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(24),
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Native-style portrait camera preview.
          _buildUprightCameraPreview(),

          // 2. Green target frame overlay.
          Center(
            child: Container(
              margin: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                border: Border.all(
                  color: const Color(0xFF1ABC9C),
                  width: 3,
                ),
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),

          // 3. Bottom controls (switch camera, record/stop).
          Positioned(
            bottom: 16,
            left: 16,
            right: 16,
            child: _buildControls(0),
          ),
        ],
      ),
    );
  }

  /// Renders the camera preview — orientation follows the physical device.
  Widget _buildUprightCameraPreview() {
    final CameraController? cameraController = _controller;

    if (!_isCameraInitialized ||
        cameraController == null ||
        !cameraController.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.tealAccent),
      );
    }

    return AutoUprightCameraPreview(cameraController);
  }
}
