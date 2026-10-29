import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// A locally-computed guess at a static handshape — produced entirely
/// on-device, so it can answer instantly even without internet.
class HandGuess {
  const HandGuess({
    required this.handPresent,
    required this.presence,
    this.label,
    this.confidence = 0,
    this.landmarks,
  });

  final bool handPresent;
  final double presence;
  final String? label;
  final double confidence;

  /// Raw 21×3 landmark vector — used by the training-data recorder.
  final List<double>? landmarks;
}

/// MediaPipe-style 21-landmark hand model wrapped behind a simple API.
///
/// The bundled `hand_landmark_full.tflite` regresses 21 (x, y, z) keypoints
/// plus a hand-presence score from a 224x224 crop. We feed it the centre of
/// the camera frame (the same region the on-screen guide box marks), so the
/// interaction contract is simply "hold the sign inside the box".
class HandSignClassifier {
  Interpreter? _interpreter;
  IsolateInterpreter? _iso;
  int _inputSize = 224;

  bool get isReady => _interpreter != null;

  /// Landmark indices for each finger's joints (tip, dip, pip, mcp).
  static const _fingers = {
    'index': [8, 7, 6, 5],
    'middle': [12, 11, 10, 9],
    'ring': [16, 15, 14, 13],
    'pinky': [20, 19, 18, 17],
  };

  Future<void> load() async {
    if (_interpreter != null) return;
    try {
      final options = InterpreterOptions()..threads = 2;
      _interpreter = await Interpreter.fromAsset(
        'assets/ml/hand_landmark_full.tflite',
        options: options,
      );
      final inShape = _interpreter!.getInputTensor(0).shape;
      if (inShape.length == 4) _inputSize = inShape[1];
      // Run inference on a worker isolate so the preview doesn't stutter;
      // fall back to the UI isolate if spawning fails.
      try {
        _iso = await IsolateInterpreter.create(address: _interpreter!.address);
      } catch (e) {
        debugPrint('Isolate inference unavailable, using UI isolate: $e');
        _iso = null;
      }
      debugPrint('HandSignClassifier loaded (input $_inputSize)');
    } catch (e) {
      debugPrint('HandSignClassifier failed to load: $e');
      _interpreter = null;
    }
  }

  /// Analyse a decoded camera frame. Returns null if the model is not
  /// loaded — callers should treat that as "no local answer".
  ///
  /// The landmark model is stage two of a two-stage pipeline — it expects a
  /// fairly tight hand region. Since we skip the palm-detector stage, we try
  /// the guided centre crop first and fall back to the whole frame, keeping
  /// whichever pass reports the strongest hand presence.
  bool _busy = false;

  Future<HandGuess?> analyze(img.Image frame) async {
    final interpreter = _interpreter;
    // IsolateInterpreter drops concurrent requests and would leave the
    // output buffers zeroed — refuse a second pass instead.
    if (interpreter == null || _busy) return null;
    _busy = true;
    try {
      HandGuess? best;
      for (final frac in const [0.85, 1.0]) {
        final guess = await _runOnce(interpreter, frame, frac);
        if (guess == null) continue;
        if (best == null || guess.presence > best.presence) best = guess;
        if (guess.presence >= 0.6) break; // confident enough — stop early
      }
      return best;
    } finally {
      _busy = false;
    }
  }

  bool _loggedOutputs = false;

  Future<HandGuess?> _runOnce(
    Interpreter interpreter,
    img.Image frame,
    double frac,
  ) async {
    try {
      // Centre crop matching roughly the on-screen guide box.
      final side = (math.min(frame.width, frame.height) * frac).round();
      final cx = ((frame.width - side) / 2).round();
      final cy = ((frame.height - side) / 2).round();
      final crop = img.copyCrop(frame, x: cx, y: cy, width: side, height: side);
      final resized = img.copyResize(
        crop,
        width: _inputSize,
        height: _inputSize,
      );

      // Build NHWC float32 input normalised to 0..1 — bulk byte read,
      // ~10x faster than per-pixel getPixel calls on the UI isolate.
      final input = Float32List(_inputSize * _inputSize * 3);
      final bytes = resized.getBytes(order: img.ChannelOrder.rgb);
      for (var i = 0; i < input.length; i++) {
        input[i] = bytes[i] / 255.0;
      }

      // The model emits landmark coords (63), handedness and a presence
      // score — match outputs by name where possible.
      final outputs = interpreter.getOutputTensors();
      final buffers = <int, Object>{};
      final landmarkBuf = Float32List(63);
      var presenceIdx = -1;
      var landmarksAssigned = false;
      final scalarIdx = <int>[];
      final scalarBufs = <int, Float32List>{};
      for (var t = 0; t < outputs.length; t++) {
        final numel = outputs[t].numElements();
        final name = outputs[t].name.toLowerCase();
        // The model has TWO 63-float outputs (screen landmarks and world
        // landmarks). Only the first is normalised 0..1 crop coordinates —
        // that's the one we read. Every output must still be bound because
        // IsolateInterpreter copies every tensor back after inference.
        if (numel == 63 && !landmarksAssigned) {
          buffers[t] = landmarkBuf.reshape([1, 63]);
          landmarksAssigned = true;
          continue;
        } else if (numel == 63) {
          buffers[t] = Float32List(numel).reshape([1, 63]);
          continue;
        } else {
          final b = Float32List(numel);
          scalarBufs[t] = b;
          scalarIdx.add(t);
          if (name.contains('presence') || name.contains('segment')) {
            presenceIdx = t;
          }
          buffers[t] = b.reshape(outputs[t].shape);
        }
      }
      if (presenceIdx < 0 && scalarIdx.isNotEmpty) {
        // No named presence output — assume the last scalar carries it.
        presenceIdx = scalarIdx.last;
      }

      final iso = _iso;
      if (iso != null) {
        await iso.runForMultipleInputs([
          input.reshape([1, _inputSize, _inputSize, 3]),
        ], buffers);
      } else {
        interpreter.runForMultipleInputs([
          input.reshape([1, _inputSize, _inputSize, 3]),
        ], buffers);
      }

      final raw = presenceIdx >= 0 ? scalarBufs[presenceIdx]![0] : 0.0;
      if (!_loggedOutputs) {
        _loggedOutputs = true;
        debugPrint(
          'HandSignClassifier outputs: '
          '${outputs.map((o) => '${o.name}${o.shape}').join(', ')} '
          '→ raw presence $raw',
        );
      }

      // The score may be a calibrated 0..1 probability or a raw logit —
      // apply sigmoid only when the value is outside the unit range.
      var presence = raw;
      if (presence < 0 || presence > 1) {
        presence = 1 / (1 + math.exp(-raw.clamp(-20.0, 20.0)));
      }

      return _classify(List<double>.from(landmarkBuf), presence);
    } catch (e) {
      debugPrint('HandSignClassifier inference failed: $e');
      return null;
    }
  }

  /// Recenters the landmark vector on the wrist and scales it by the
  /// wrist→middle-knuckle distance, making samples comparable across
  /// different hands, sizes, and distances from the camera.
  static List<double> normalizeLandmarks(List<double> lm) {
    final wx = lm[0], wy = lm[1], wz = lm[2];
    final sx = lm[27] - wx, sy = lm[28] - wy, sz = lm[29] - wz;
    final scale = math.sqrt(sx * sx + sy * sy + sz * sz).clamp(1e-6, 1e9);
    final out = List<double>.filled(lm.length, 0);
    for (var i = 0; i < lm.length; i += 3) {
      out[i] = (lm[i] - wx) / scale;
      out[i + 1] = (lm[i + 1] - wy) / scale;
      out[i + 2] = (lm[i + 2] - wz) / scale;
    }
    return out;
  }

  /// k-nearest-neighbour match against recorded landmark samples.
  /// Returns (label, confidence) for the majority label, or null when the
  /// vote is too weak or the nearest sample is too far away.
  /// [useZ] defaults off — MediaPipe's z channel is estimated and noisy;
  /// measured separability is better on x,y alone (~56% vs ~52% LOO).
  static (String, double)? knnLabel(
    List<double> normalized,
    Map<String, List<List<double>>> samples, {
    int k = 5,
    double minScore = 0.6,
    double maxDistance = 0.9,
    bool useZ = false,
  }) {
    final scored = <(String, double)>[];
    samples.forEach((label, vectors) {
      for (final v in vectors) {
        var d = 0.0;
        for (
          var i = 0;
          i + 2 < v.length && i + 2 < normalized.length;
          i += 3
        ) {
          final dx = v[i] - normalized[i];
          final dy = v[i + 1] - normalized[i + 1];
          d += dx * dx + dy * dy;
          if (useZ) {
            final dz = v[i + 2] - normalized[i + 2];
            d += dz * dz;
          }
        }
        scored.add((label, math.sqrt(d)));
      }
    });
    if (scored.isEmpty) return null;
    scored.sort((a, b) => a.$2.compareTo(b.$2));
    if (scored.first.$2 > maxDistance) return null;

    final votes = <String, int>{};
    for (final s in scored.take(k)) {
      votes[s.$1] = (votes[s.$1] ?? 0) + 1;
    }
    final best = votes.entries.reduce((a, b) => a.value >= b.value ? a : b);
    final confidence = best.value / k;
    if (confidence < minScore) return null;
    return (best.key, confidence);
  }

  // ------------------------------------------------------------ geometry

  HandGuess _classify(List<double> lm, double presence) {
    if (presence < 0.45) {
      return HandGuess(handPresent: false, presence: presence, landmarks: lm);
    }

    double px(int i) => lm[i * 3];
    double py(int i) => lm[i * 3 + 1];
    double pz(int i) => lm[i * 3 + 2];

    double dist(int a, int b) {
      final dx = px(a) - px(b);
      final dy = py(a) - py(b);
      final dz = pz(a) - pz(b);
      return math.sqrt(dx * dx + dy * dy + dz * dz);
    }

    // A finger counts as extended when its tip sits meaningfully farther
    // from the wrist than its middle knuckle.
    bool extended(String finger) {
      final j = _fingers[finger]!;
      return dist(j[0], 0) > dist(j[2], 0) * 1.10;
    }

    final thumb = dist(4, 9) > dist(3, 9) * 1.18;
    final index = extended('index');
    final middle = extended('middle');
    final ring = extended('ring');
    final pinky = extended('pinky');

    final pattern = <bool>[thumb, index, middle, ring, pinky];

    String? label;

    if (pattern.every((e) => e)) {
      label = 'Hello'; // open palm — also the sign for five
    } else if (pattern.every((e) => !e)) {
      label = 'Letter S'; // closed fist, thumb folded over
    } else if (!thumb && index && middle && !ring && !pinky) {
      // Spread tips = V/two, tips together = U.
      label = dist(8, 12) > dist(6, 10) * 0.9 ? 'Two' : 'Letter U';
    } else if (!thumb && index && middle && ring && !pinky) {
      label = 'Three';
    } else if (!thumb && index && !middle && !ring && !pinky) {
      // Thumb resting on the middle finger's tip makes a D, otherwise 1.
      label = dist(4, 12) < 0.06 ? 'Letter D' : 'One';
    } else if (!thumb && !index && !middle && !ring && pinky) {
      label = 'Letter I';
    } else if (thumb && !index && !middle && !ring && pinky) {
      label = 'Letter Y'; // shaka — also used for "call me"
    } else if (thumb && index && !middle && !ring && !pinky) {
      label = 'Letter L';
    } else if (thumb && index && !middle && !ring && pinky) {
      label = 'I Love You';
    } else if (thumb && !index && !middle && !ring && !pinky) {
      // Thumb alone: approval requires the tip above the index knuckle —
      // comparing against the wrist would always pass.
      label = py(4) < py(5) ? 'Good' : 'Letter A';
    } else if (!thumb && index && middle && ring && pinky) {
      label = 'Letter B'; // four fingers up, thumb tucked
    } else if (!index && !middle && !ring && !pinky && !thumb) {
      label = 'Letter E';
    } else {
      // Curved hand (C) or fingertip circle (O/F) — approximate by checking
      // whether the index tip is close to the thumb tip.
      if (dist(4, 8) < 0.08) {
        label = (middle || ring || pinky) ? 'Letter F' : 'Letter O';
      }
    }

    if (label == null) {
      return HandGuess(handPresent: true, presence: presence, landmarks: lm);
    }
    return HandGuess(
      handPresent: true,
      presence: presence,
      label: label,
      confidence: presence * 0.9,
      landmarks: lm,
    );
  }

  void dispose() {
    _iso?.close();
    _iso = null;
    _interpreter?.close();
    _interpreter = null;
  }
}
