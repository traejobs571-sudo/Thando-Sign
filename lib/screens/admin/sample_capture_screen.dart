import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../ml/frame_convert.dart';
import '../../ml/hand_sign_classifier.dart';
import '../../services/db_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/auto_upright_camera_preview.dart';
import '../../widgets/glass_card.dart';

/// Records labelled landmark samples for a gesture. Collected vectors feed
/// the on-device k-NN recogniser — this is how the system learns real ZSL
/// signs from actual users instead of relying only on rules.
class SampleCaptureScreen extends StatefulWidget {
  const SampleCaptureScreen({super.key, required this.label});

  final String label;

  @override
  State<SampleCaptureScreen> createState() => _SampleCaptureScreenState();
}

class _SampleCaptureScreenState extends State<SampleCaptureScreen> {
  static const _targetSamples = 25;

  CameraController? _cam;
  bool _recording = false;
  bool _saving = false;
  String? _error;
  DateTime _lastRun = DateTime.fromMillisecondsSinceEpoch(0);
  final List<List<double>> _samples = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() => _error = 'Camera permission denied.');
      return;
    }
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      setState(() => _error = 'No camera found.');
      return;
    }
    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    _cam = CameraController(
      back,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    await _cam!.initialize();
    // Orientation follows the physical device — the preview widget keeps
    // the feed upright regardless of tilt. Lock→unlock arms the
    // default-rotation path so captures stay upright.
    try {
      await _cam!.lockCaptureOrientation(DeviceOrientation.portraitUp);
      await _cam!.unlockCaptureOrientation();
      await _cam!.setFocusMode(FocusMode.auto);
      await _cam!.setExposureMode(ExposureMode.auto);
    } catch (_) {}
    await _cam!.startImageStream(_onFrame);
    if (mounted) setState(() {});
  }

  void _onFrame(CameraImage frame) {
    if (!_recording || _samples.length >= _targetSamples) return;
    final now = DateTime.now();
    if (now.difference(_lastRun).inMilliseconds < 350) return;
    _lastRun = now;

    final ml = context.read<HandSignClassifier>();
    if (!ml.isReady) return;
    final decoded = cameraImageToImage(
      frame,
      targetWidth: 320,
      rotationDeg: _cam?.description.sensorOrientation ?? 0,
    );
    if (decoded == null) return;
    ml.analyze(decoded).then((guess) {
      final lm = guess?.landmarks;
      if (guess != null && guess.handPresent && lm != null) {
        _samples.add(HandSignClassifier.normalizeLandmarks(lm));
        if (mounted) setState(() {});
      }
    });
  }

  /// Shows the live preview — orientation follows the physical device.
  Widget _buildUprightPreview(CameraController cam) {
    return AutoUprightCameraPreview(cam);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final db = context.read<DbService>();
    for (final s in _samples) {
      await db.saveGestureSample(widget.label, s);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved ${_samples.length} samples.')),
      );
      Navigator.pop(context, true);
    }
  }

  @override
  void dispose() {
    _cam?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _cam?.value.isInitialized == true;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppGradients.dark),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    Expanded(
                      child: Text(
                        'Teach "${widget.label}"',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: GlassCard(
                    padding: const EdgeInsets.all(12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: ready
                          ? _buildUprightPreview(_cam!)
                          : Center(
                              child: _error != null
                                  ? Text(
                                      _error!,
                                      style: const TextStyle(
                                        color: Colors.white70,
                                      ),
                                    )
                                  : const CircularProgressIndicator(
                                      color: AppColors.primary,
                                    ),
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                GlassCard(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Text(
                        _recording
                            ? 'Recording… perform the sign slowly (${_samples.length}/$_targetSamples)'
                            : 'Hold the sign inside the frame, then record.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: _samples.length / _targetSamples,
                          minHeight: 8,
                          backgroundColor: Colors.white.withValues(alpha: 0.1),
                          valueColor: const AlwaysStoppedAnimation(
                            AppColors.primary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed:
                                  !ready || _samples.length >= _targetSamples
                                  ? null
                                  : () => setState(
                                      () => _recording = !_recording,
                                    ),
                              icon: Icon(
                                _recording
                                    ? Icons.stop
                                    : Icons.fiber_manual_record,
                              ),
                              label: Text(_recording ? 'Stop' : 'Record'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primary,
                              ),
                              onPressed:
                                  _samples.isNotEmpty && !_saving && !_recording
                                  ? _save
                                  : null,
                              icon: _saving
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.save_outlined),
                              label: Text(
                                _saving ? 'Saving…' : 'Save ${_samples.length}',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
