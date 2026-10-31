import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_compress/video_compress.dart';

import '../ml/frame_convert.dart';
import '../ml/hand_sign_classifier.dart';
import '../models/translation_record.dart';
import '../services/db_service.dart';
import '../services/gemini_service.dart';
import '../services/settings_service.dart';
import '../services/tts_service.dart';
import '../services/auth_service.dart';
import '../widgets/hand_landmark.dart';

class TranslationController extends ChangeNotifier {
  TranslationController({
    required this.db,
    required this.gemini,
    required this.tts,
    required this.auth,
    required this.ml,
    required this.settings,
  }) {
    _lastUserId = auth.currentUser?.id;
    auth.addListener(_onAuthChanged);
  }

  final DbService db;
  final GeminiService gemini;
  final TtsService tts;
  final AuthService auth;
  final HandSignClassifier ml;
  final AppSettings settings;

  static const _maxFailures = 3;
  static const _backoffSeconds = 30;

  CameraController? cameraController;
  List<CameraDescription> cameras = [];

  /// The lens currently bound to [cameraController] — tracked so the UI
  /// can label the preview and [switchCamera] knows what to swap to.
  CameraDescription? activeCamera;
  bool cameraReady = false;
  bool cameraBusy = false;
  bool translating = false;

  /// Latest frame from the camera image stream — capture is instant,
  /// unlike takePicture() which waits for the shutter cycle.
  CameraImage? _latestImage;
  img.Image? _lastDecoded;
  DateTime _lastMlAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _rotationDeg = 0;

  /// Front lenses show a mirrored preview while the raw stream stays
  /// unmirrored — uploaded frames and thumbnails are flipped to match
  /// what the user actually saw.
  bool _mirrorFrames = false;
  bool _mlBusy = false;
  bool _cameraStarting = false;
  int? _lastUserId;

  /// Live on-device guess for the sign currently in frame.
  HandGuess? localGuess;

  Uint8List? lastFrame;
  GestureResult? lastResult;
  String? error;
  DateTime? lastCaptureAt;

  /// Frames queued for a multi-sign capture — translated together in a
  /// single request so fingerspelled words/phrases come back as one
  /// result instead of one API call per sign.
  final List<Uint8List> batchFrames = [];
  static const maxBatchFrames = 10;

  /// Motion capture state — a timed burst of frames while a dynamic sign
  /// is performed. [motionCaptured] tracks progress for the UI.
  bool capturingMotion = false;
  int motionCaptured = 0;
  static const motionFrameCount = 8;
  static const _motionGapMs = 250;

  /// Conversation-recording state — a real .mp4 is written by the camera
  /// plugin while [_sessionFrames] accumulate sampled JPEGs for the
  /// single translation request fired on stop. [sessionStartedAt] powers
  /// the elapsed-time indicator in the UI.
  bool recordingSession = false;
  DateTime? sessionStartedAt;
  String? lastSessionVideoPath;
  Timer? _sessionTicker;
  final List<Uint8List> _sessionFrames = [];
  DateTime _lastSessionSample = DateTime.fromMillisecondsSinceEpoch(0);
  bool _sessionHasVideo = false;

  /// Rolling live-caption text while a session records — appended
  /// segment-by-segment so the screen keeps up with a signer in near
  /// real time.
  String liveTranscript = '';

  /// Sign labels recognised so far in the active session, in order —
  /// powers the live sign strip rendered under the transcript.
  List<String> liveSigns = const [];

  /// Short reason when a live segment can't be determined — surfaced so
  /// the signer knows what to fix (hand left the frame, blur, etc).
  String liveStatus = '';
  Timer? _liveTicker;
  bool _liveBusy = false;

  /// Serialises start/stop transitions — recordingSession flips before the
  /// async camera calls finish, so without this a fast re-tap could start a
  /// new recording while the previous stop is still in flight.
  bool _sessionTransition = false;

  /// Hard cap on a conversation recording — ~100 sampled frames at
  /// [_sessionSampleGapMs] each keeps the single upload under ~8MB.
  static const sessionMaxSeconds = 30;
  static const _sessionSampleGapMs = 300;
  static const _maxSessionFrames = 100;
  static const _maxKeptRecordings = 5;

  Duration get sessionElapsed => sessionStartedAt == null
      ? Duration.zero
      : DateTime.now().difference(sessionStartedAt!);

  int get sessionFrameCount => _sessionFrames.length;

  /// Becomes true after repeated failures — continuous mode should stop.
  bool autoDisabled = false;
  int _failureCount = 0;
  DateTime? _backoffUntil;

  /// Set when a cloud call fails — further calls are skipped for
  /// [_cloudDownSeconds] so auto mode doesn't burn through the whole
  /// model-fallback list on every interval during an outage.
  DateTime? _cloudDownUntil;
  static const _cloudDownSeconds = 60;

  List<String> _vocabulary = [];
  Map<String, List<List<double>>> _samples = {};
  List<TranslationRecord> history = [];

  Future<void> loadHistory() async {
    final user = auth.currentUser;
    if (user == null) return;
    history = await db.getTranslationsForUser(user.id!);
    notifyListeners();
  }

  Future<void> _loadVocabulary() async {
    _vocabulary = await db.getActiveGestureLabels();
    // Recorded landmark samples power the k-NN recogniser — reload on every
    // camera init so samples captured since the last visit take effect.
    _samples = await db.getGestureSamples();
  }

  /// Clears per-user state when a different account signs in — otherwise
  /// the previous user's history and results leak into the next session.
  void _onAuthChanged() {
    final id = auth.currentUser?.id;
    if (id == _lastUserId) return;
    _lastUserId = id;
    history = [];
    lastResult = null;
    localGuess = null;
    lastFrame = null;
    lastCaptureAt = null;
    lastSessionVideoPath = null;
    notifyListeners();
  }

  Future<void> initCamera() async {
    if (cameraController != null || _cameraStarting) return;
    _cameraStarting = true;
    error = null;
    notifyListeners();

    try {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        error = 'Camera permission denied. Please enable camera access in settings.';
        return;
      }

      try {
        await _loadVocabulary();
        cameras = await availableCameras();
        if (cameras.isEmpty) {
          error = 'No camera found on this device.';
          return;
        }
        activeCamera = cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cameras.first,
        );
        cameraController = CameraController(
          activeCamera!,
          ResolutionPreset.medium,
          enableAudio: false,
          imageFormatGroup: ImageFormatGroup.yuv420,
        );
        await cameraController!.initialize();
        // One-time lock→unlock: sets CameraX's shouldSetDefaultRotation so
        // every use case bound later (video recording, image streams)
        // automatically targets the CURRENT physical display rotation —
        // recorded .mp4s stay upright WITHOUT touching orientation
        // mid-session, which reconfigures the capture session and can
        // rotate the live preview.
        try {
          await cameraController!.lockCaptureOrientation(
            DeviceOrientation.portraitUp,
          );
          await cameraController!.unlockCaptureOrientation();
        } catch (_) {}
        // Use default camera behavior — no focus/exposure mode overrides
        _applyLensInfo(activeCamera!);
        // Rolling copy of the newest preview frame so captures are
        // effectively free — essential for tracking continuous signing.
        await cameraController!.startImageStream(_onStreamFrame);
        cameraReady = true;
      } catch (e) {
        error = 'Failed to initialize camera: $e';
        cameraReady = false;
        // Don't leave a dead controller behind — the next attempt must be
        // allowed to create a fresh one.
        await cameraController?.dispose();
        cameraController = null;
      }
    } finally {
      _cameraStarting = false;
      notifyListeners();
    }
  }

  /// Per-lens decode parameters — sensor frames are stored sideways on
  /// Android, and the front lens mirrors its preview while the raw
  /// stream stays unmirrored.
  void _applyLensInfo(CameraDescription description) {
    _rotationDeg = description.sensorOrientation;
    _mirrorFrames = description.lensDirection == CameraLensDirection.front;
  }

  /// Shared image-stream callback — a named method so the stream can be
  /// re-registered after recording (which swaps in its own callback).
  void _onStreamFrame(CameraImage frame) {
    _latestImage = frame;
    _maybeRunLocal(frame);
  }

  /// The opposite lens to the active one — null on single-camera devices.
  CameraDescription? get _nextLens {
    if (cameras.length < 2 || activeCamera == null) return null;
    final want = activeCamera!.lensDirection == CameraLensDirection.front
        ? CameraLensDirection.back
        : CameraLensDirection.front;
    return cameras.firstWhere(
      (c) => c.lensDirection == want,
      orElse: () => cameras.firstWhere((c) => c != activeCamera),
    );
  }

  bool get canSwitchCamera =>
      cameras.length > 1 &&
      cameraReady &&
      cameraController?.value.isInitialized == true &&
      !recordingSession &&
      !_sessionTransition &&
      !capturingMotion &&
      !translating &&
      !_cameraStarting;

  /// Swaps between the front and back lenses in place — setDescription
  /// re-initialises under the same controller object, so the preview
  /// widget survives the switch.
  Future<void> switchCamera() async {
    final next = _nextLens;
    final controller = cameraController;
    if (next == null || controller == null || !canSwitchCamera) return;
    _cameraStarting = true;
    error = null;
    notifyListeners();
    try {
      await controller.stopImageStream();
      await controller.setDescription(next);
      activeCamera = next;
      _applyLensInfo(next);
      _latestImage = null;
      _lastDecoded = null;
      localGuess = null;
      // Use default camera behavior — no focus/exposure mode overrides
      await controller.startImageStream(_onStreamFrame);
    } catch (e) {
      // The in-place swap failed — rebuild the camera cleanly rather than
      // leaving a half-configured controller behind.
      error = 'Could not switch camera: $e';
      await _releaseCamera();
      _cameraStarting = false;
      await initCamera();
      return;
    }
    _cameraStarting = false;
    notifyListeners();
  }

  /// Throttled on-device pass over the preview stream (about 2.5 fps) so
  /// the "Hand detected / On-device: X" chip updates in near real time.
  /// Inference is async on a worker isolate — [_mlBusy] keeps requests
  /// from piling up while a pass is in flight.
  void _maybeRunLocal(CameraImage frame) {
    if (!ml.isReady || _mlBusy) return;
    final now = DateTime.now();
    if (now.difference(_lastMlAt).inMilliseconds < 400) return;
    _lastMlAt = now;
    final decoded = cameraImageToImage(
      frame,
      targetWidth: 320,
      rotationDeg: _rotationDeg,
    );
    if (decoded == null) return;
    _mlBusy = true;
    unawaited(() async {
      try {
        final raw = await ml.analyze(decoded);
        // Null means the model was busy or failed — keep the last guess
        // rather than clearing the chip.
        if (raw == null) return;
        final guess = _applyKnn(raw);
        if (guess.presence != localGuess?.presence ||
            guess.label != localGuess?.label) {
          localGuess = guess;
          notifyListeners();
        }
      } catch (_) {
        // Keep the previous guess when a single pass fails.
      } finally {
        _mlBusy = false;
      }
    }());
  }

  /// Refines a geometric guess with the k-NN match against recorded
  /// samples — user-trained signs win when the vote is confident.
  HandGuess _applyKnn(HandGuess guess) {
    final lm = guess.landmarks;
    if (!guess.handPresent || lm == null || _samples.isEmpty) {
      return guess;
    }
    final knn = HandSignClassifier.knnLabel(
      HandSignClassifier.normalizeLandmarks(lm),
      _samples,
    );
    if (knn == null) return guess;
    if (_vocabulary.isNotEmpty && !_vocabulary.contains(knn.$1)) return guess;
    return HandGuess(
      handPresent: true,
      presence: guess.presence,
      label: knn.$1,
      confidence: knn.$2,
      landmarks: lm,
    );
  }

  Future<void> disposeCamera() async {
    await _releaseCamera();
    notifyListeners();
  }

  /// Pauses the frame stream and preview while the Translate tab sits
  /// hidden in the IndexedStack — the controller stays initialized so
  /// [resumeCamera] is instant. An in-flight session recording keeps
  /// running (its frames belong to the recorder).
  Future<void> pauseCamera() async {
    final controller = cameraController;
    if (controller == null ||
        !controller.value.isInitialized ||
        recordingSession) {
      return;
    }
    if (controller.value.isStreamingImages) {
      try {
        await controller.stopImageStream();
      } catch (_) {}
    }
    try {
      await controller.pausePreview();
    } catch (_) {}
  }

  /// Resumes after [pauseCamera] — falls back to a full [initCamera]
  /// when the controller was released meanwhile (e.g. a pushed route
  /// took the camera).
  Future<void> resumeCamera() async {
    final controller = cameraController;
    if (controller == null || !controller.value.isInitialized) {
      await initCamera();
      return;
    }
    try {
      await controller.resumePreview();
    } catch (_) {}
    if (!controller.value.isStreamingImages) {
      try {
        await controller.startImageStream(_onStreamFrame);
      } catch (_) {}
    }
    cameraReady = true;
    notifyListeners();
  }

  /// Stops the stream and releases the controller without notifying —
  /// safe to call from ChangeNotifier.dispose().
  Future<void> _releaseCamera() async {
    // An active recording must be torn down first — its frame stream is
    // owned by the recorder and the mp4 is discarded.
    if (recordingSession) {
      await stopSessionRecording(cancel: true);
    }
    if (cameraController?.value.isStreamingImages == true) {
      try {
        await cameraController!.stopImageStream();
      } catch (_) {}
    }
    await cameraController?.dispose();
    cameraController = null;
    cameraReady = false;
    _latestImage = null;
    _lastDecoded = null;
  }

  Future<Uint8List?> captureFrame() async {
    final controller = cameraController;
    if (controller == null || !controller.value.isInitialized) return null;

    try {
      cameraBusy = true;
      final streamed = _latestImage;
      if (streamed != null) {
        lastFrame = _cameraImageToJpeg(streamed);
      } else {
        if (controller.value.isTakingPicture) return null;
        final file = await controller.takePicture();
        final bytes = await file.readAsBytes();
        lastFrame = await _resizeImage(bytes);
      }
      lastCaptureAt = DateTime.now();
      return lastFrame;
    } catch (e) {
      error = 'Capture failed: $e';
      return null;
    } finally {
      cameraBusy = false;
      notifyListeners();
    }
  }

  /// One live-caption tick: sends the trailing ~16 frames (~5s) for
  /// translation and merges the text into [liveTranscript]. Skips when a
  /// segment is already in flight or the cloud is down — ticks never
  /// pile up.
  Future<void> _liveSegmentTick() async {
    if (_liveBusy ||
        _cloudDownUntil != null ||
        !recordingSession ||
        _sessionFrames.length < 8) {
      return;
    }
    _liveBusy = true;
    try {
      final frames = _sessionFrames.length > 16
          ? _sessionFrames.sublist(_sessionFrames.length - 16)
          : List<Uint8List>.of(_sessionFrames);
      final result = await gemini.identifySigningSession(
        frames,
        vocabulary: _vocabulary,
      );
      final snapped = GeminiService.snapToVocabulary(result, _vocabulary);
      if (snapped.english == 'Could not determine') {
        liveStatus = snapped.note.isEmpty
            ? 'Sign unclear — keep signing in the frame'
            : snapped.note;
      } else {
        liveStatus = '';
        final before = liveTranscript;
        liveTranscript = mergeLiveSegment(liveTranscript, snapped.english);
        // The newly appended words are spoken aloud right away — live
        // captions the hearing person can hear, not just read.
        final tail = liveTranscript.length > before.length
            ? liveTranscript.substring(before.length).trim()
            : '';
        liveSigns = mergeLiveSigns(
          liveSigns,
          tokenizeSignLabels(snapped.gesture, _vocabulary),
        );
        if (tail.isNotEmpty && settings.autoSpeak) {
          unawaited(tts.speakLive(tail));
        }
      }
      notifyListeners();
    } catch (_) {
      // A failed segment skips — the next tick retries.
    } finally {
      _liveBusy = false;
    }
  }

  /// Merges a new transcript segment onto the running text: the longest
  /// suffix of [current] matching a prefix of [segment] is counted once,
  /// so overlapping capture windows don't duplicate words.
  static String mergeLiveSegment(String current, String segment) {
    final cur = current.trim();
    final seg = segment.trim();
    if (seg.isEmpty) return cur;
    if (cur.isEmpty) return seg;
    final curWords = cur.split(RegExp(r'\s+'));
    final segWords = seg.split(RegExp(r'\s+'));
    var overlap = math.min(curWords.length, segWords.length);
    while (overlap > 0) {
      if (curWords.sublist(curWords.length - overlap).join(' ') ==
          segWords.sublist(0, overlap).join(' ')) {
        break;
      }
      overlap--;
    }
    final tail = overlap < segWords.length
        ? segWords.sublist(overlap).join(' ')
        : '';
    return tail.isEmpty ? cur : '$cur $tail';
  }

  /// List version of [mergeLiveSegment]: drops the longest suffix of
  /// [current] that reappears as a prefix of [segment], so overlapping
  /// capture windows don't double-count the same sign.
  static List<String> mergeLiveSigns(
    List<String> current,
    List<String> segment,
  ) {
    if (segment.isEmpty) return current;
    if (current.isEmpty) return List.of(segment);
    var overlap = math.min(current.length, segment.length);
    while (overlap > 0) {
      if (listEquals(
        current.sublist(current.length - overlap),
        segment.sublist(0, overlap),
      )) {
        break;
      }
      overlap--;
    }
    return [...current, ...segment.sublist(overlap)];
  }

  /// Splits a space-joined GESTURE response into sign labels — greedy
  /// longest-match against [vocabulary] so multi-word labels like
  /// "Thank You" stay whole; unmatched words pass through as single
  /// tokens so the UI can still show a placeholder tile.
  static List<String> tokenizeSignLabels(
    String gesture,
    List<String> vocabulary,
  ) {
    final vocab = List.of(vocabulary)
      ..sort((a, b) => b.length.compareTo(a.length));
    final s = gesture.trim();
    final wordChar = RegExp(r"[A-Za-z0-9']");
    final out = <String>[];
    var i = 0;
    while (i < s.length) {
      if (!wordChar.hasMatch(s[i])) {
        i++;
        continue;
      }
      final rest = s.substring(i).toLowerCase();
      String? matched;
      for (final label in vocab) {
        final l = label.toLowerCase();
        if (rest.startsWith(l) &&
            (rest.length == l.length || !wordChar.hasMatch(rest[l.length]))) {
          matched = label;
          break;
        }
      }
      if (matched != null) {
        out.add(matched);
        i += matched.length;
      } else {
        var j = i;
        while (j < s.length && wordChar.hasMatch(s[j])) {
          j++;
        }
        final token = s.substring(i, j);
        if (token.toLowerCase() != 'unknown') out.add(token);
        i = j;
      }
    }
    return out;
  }

  /// Converts a streamed camera frame to a small JPEG (~448px wide).
  /// Small uploads noticeably cut model latency and mobile-data cost.
  Uint8List? _cameraImageToJpeg(CameraImage frame) {
    try {
      var decoded = cameraImageToImage(
        frame,
        targetWidth: 448,
        rotationDeg: _rotationDeg,
      );
      if (decoded == null) return null;
      if (_mirrorFrames) {
        decoded = img.flipHorizontal(decoded);
      }
      if (decoded.width > 448) {
        decoded = img.copyResize(decoded, width: 448);
      }
      _lastDecoded = decoded;
      return Uint8List.fromList(img.encodeJpg(decoded, quality: 70));
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _resizeImage(Uint8List bytes) async {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return bytes;
      // Still-image captures carry EXIF orientation — bake it in so the
      // uploaded frame is upright.
      final oriented = img.bakeOrientation(decoded);
      final resized = oriented.width > 560
          ? img.copyResize(oriented, width: 560)
          : oriented;
      return Uint8List.fromList(img.encodeJpg(resized, quality: 75));
    } catch (_) {
      return bytes;
    }
  }

  bool get _inBackoff =>
      _backoffUntil != null && DateTime.now().isBefore(_backoffUntil!);

  /// [manual] is true when the user tapped Translate Now — always speaks.
  /// In continuous mode repeated identical signs are not saved or spoken
  /// again, so history and audio keep pace without spamming.
  ///
  /// The pipeline is local-first: the bundled hand model watches the stream
  /// in the background, rejects empty frames, and answers immediately when
  /// it is confident. Ambiguous frames escalate to the cloud service.
  Future<void> captureAndTranslate({bool manual = false}) async {
    if (translating || recordingSession || _sessionTransition) return;
    if (_inBackoff) {
      final secs = _backoffUntil!.difference(DateTime.now()).inSeconds;
      error = 'Translation paused after errors — retry in ${secs}s.';
      notifyListeners();
      return;
    }

    error = null;
    translating = true;
    notifyListeners();

    try {
      final frame = await captureFrame();
      if (frame == null) {
        if (manual) error = 'Could not capture a frame from the camera.';
        return;
      }

      // On-device pass: gate empty frames and answer confident static signs.
      final decoded = _lastDecoded;
      var guess = decoded != null ? await ml.analyze(decoded) : localGuess;
      if (guess != null) guess = _applyKnn(guess);
      if (guess != null) localGuess = guess;
      // Empty frames are skipped silently in auto mode. On a manual tap the
      // frame still goes to the cloud — the local model is an assist,
      // not a hard gate, and the user explicitly asked.
      if (guess != null && !guess.handPresent && !manual) {
        return;
      }
      if (guess != null &&
          guess.confidence >= settings.localConfidenceFloor &&
          guess.label != null &&
          (_vocabulary.isEmpty || _vocabulary.contains(guess.label))) {
        await _applyResult(
          _localResult(guess),
          manual: manual,
          source: 'on-device',
        );
        return;
      }

      if (_cloudDownUntil != null &&
          DateTime.now().isBefore(_cloudDownUntil!)) {
        await _failOrFallback(
          'Cloud translator offline — using on-device recognition.',
          manual: manual,
          markCloudDown: false,
        );
        return;
      }
      final refs = await _candidateReferences(localGuess);
      final result = await gemini.identifyGesture(
        frame,
        vocabulary: _vocabulary,
        referenceImages: refs,
      );
      _cloudDownUntil = null;
      final snapped = ensembleResult(
        GeminiService.snapToVocabulary(result, _vocabulary),
        localGuess,
        _vocabulary,
      );
      await _applyResult(snapped, manual: manual, source: 'gemini');
    } on GeminiQuotaException {
      await _failOrFallback(
        'Translation service is busy. Pausing for ${_backoffSeconds}s — try again shortly.',
        manual: manual,
      );
    } on StateError catch (e) {
      await _failOrFallback(e.message, manual: manual);
    } catch (e) {
      await _failOrFallback(
        'Translation failed — check your connection and try again.',
        manual: manual,
      );
    } finally {
      translating = false;
      notifyListeners();
    }
  }

  /// When the cloud service is unreachable, answer from the on-device
  /// classifier rather than failing outright — the bundled model knows
  /// the core static signs, so degraded translation beats no translation.
  /// Below [settings.localConfidenceFloor] guesses are still accepted
  /// here (floor 0.40) because this path only runs when the cloud gave
  /// up entirely; the note tells the user accuracy may be lower.
  GestureResult? _offlineFallback() {
    final guess = localGuess;
    if (guess == null ||
        !guess.handPresent ||
        guess.label == null ||
        guess.confidence < 0.40) {
      return null;
    }
    final label = guess.label!;
    return GestureResult(
      gesture: label,
      english: label.startsWith('Letter ') ? label.substring(7) : label,
      confidence: guess.confidence,
      note: 'Recognised on-device — cloud translator unavailable.',
    );
  }

  /// Grabs the current frame into [batchFrames] without translating —
  /// the user accumulates one frame per sign, then taps Translate all.
  Future<void> captureToBatch() async {
    if (recordingSession || _sessionTransition) return;
    if (batchFrames.length >= maxBatchFrames) {
      error = 'Batch is full ($maxBatchFrames frames) — translate or clear it.';
      notifyListeners();
      return;
    }
    final frame = await captureFrame();
    if (frame == null) {
      error = 'Could not capture a frame from the camera.';
    } else {
      error = null;
      batchFrames.add(frame);
    }
    notifyListeners();
  }

  void clearBatch() {
    batchFrames.clear();
    error = null;
    notifyListeners();
  }

  /// Sends every queued frame to the cloud in one request; the reply
  /// contains each sign in order plus the combined English phrase.
  /// Falls back to per-frame on-device classification when offline.
  Future<void> translateBatch() async {
    if (translating || recordingSession || _sessionTransition) return;
    if (batchFrames.length < 2) {
      error = 'Capture at least 2 frames first — tap "Add frame" per sign.';
      notifyListeners();
      return;
    }

    error = null;
    translating = true;
    notifyListeners();

    try {
      if (_cloudDownUntil != null &&
          DateTime.now().isBefore(_cloudDownUntil!)) {
        await _batchFailOrFallback(
          'Cloud translator offline — using on-device recognition.',
          markCloudDown: false,
        );
        return;
      }
      final result = await gemini.identifyGestureSequence(
        batchFrames,
        vocabulary: _vocabulary,
      );
      _cloudDownUntil = null;
      batchFrames.clear();
      await _applyResult(
        GeminiService.snapToVocabulary(result, _vocabulary),
        manual: true,
        source: 'gemini',
        inputType: 'batch',
      );
    } on GeminiQuotaException {
      await _batchFailOrFallback(
        'Translation service is busy — try again shortly.',
      );
    } on StateError catch (e) {
      await _batchFailOrFallback(e.message);
    } catch (_) {
      await _batchFailOrFallback(
        'Translation failed — check your connection and try again.',
      );
    } finally {
      translating = false;
      notifyListeners();
    }
  }

  /// Records a short burst of frames while the signer performs ONE
  /// dynamic sign, then sends the whole sequence to the cloud so the
  /// model can see the hand's path and shape change. Falls back to the
  /// on-device classifier (on the final frame) when the cloud is down.
  Future<void> captureMotionBurst() async {
    if (translating || capturingMotion || recordingSession) return;
    if (!cameraReady) {
      error = 'Camera is not ready yet.';
      notifyListeners();
      return;
    }

    error = null;
    capturingMotion = true;
    motionCaptured = 0;
    notifyListeners();

    final frames = <Uint8List>[];
    for (var i = 0; i < motionFrameCount; i++) {
      final frame = await captureFrame();
      if (frame != null) {
        frames.add(frame);
        motionCaptured = frames.length;
        notifyListeners();
      }
      if (i < motionFrameCount - 1) {
        await Future.delayed(const Duration(milliseconds: _motionGapMs));
      }
    }
    capturingMotion = false;

    if (frames.length < 2) {
      error =
          'Could not capture enough frames — try again with the sign in view.';
      notifyListeners();
      return;
    }
    lastFrame = frames.last;

    translating = true;
    notifyListeners();
    try {
      if (_cloudDownUntil != null &&
          DateTime.now().isBefore(_cloudDownUntil!)) {
        await _motionFailOrFallback(
          'Cloud translator offline — using on-device recognition.',
          frames,
          markCloudDown: false,
        );
        return;
      }
      final result = await gemini.identifyDynamicSign(
        frames,
        vocabulary: _vocabulary,
      );
      _cloudDownUntil = null;
      await _applyResult(
        GeminiService.snapToVocabulary(result, _vocabulary),
        manual: true,
        source: 'gemini',
        inputType: 'motion',
      );
    } on GeminiQuotaException {
      await _motionFailOrFallback(
        'Translation service is busy — try again shortly.',
        frames,
      );
    } on StateError catch (e) {
      await _motionFailOrFallback(e.message, frames);
    } catch (_) {
      await _motionFailOrFallback(
        'Translation failed — check your connection and try again.',
        frames,
      );
    } finally {
      translating = false;
      notifyListeners();
    }
  }

  /// On-device fallback for a motion burst — classifies the last frame
  /// (a dynamic sign ends on its final hand shape, which is the most
  /// stable image for the landmark model).
  Future<void> _motionFailOrFallback(
    String failureMessage,
    List<Uint8List> frames, {
    bool markCloudDown = true,
  }) async {
    if (markCloudDown) {
      _cloudDownUntil = DateTime.now().add(
        const Duration(seconds: _cloudDownSeconds),
      );
    }
    final decoded = img.decodeImage(frames.last);
    var guess = decoded == null ? null : await ml.analyze(decoded);
    if (guess != null) guess = _applyKnn(guess);
    if (guess != null &&
        guess.handPresent &&
        guess.label != null &&
        guess.confidence >= 0.40) {
      await _applyResult(
        _localResult(guess),
        manual: true,
        source: 'on-device',
        inputType: 'motion',
      );
    } else {
      _registerFailure(failureMessage);
    }
  }

  Future<void> _batchFailOrFallback(
    String failureMessage, {
    bool markCloudDown = true,
  }) async {
    if (markCloudDown) {
      _cloudDownUntil = DateTime.now().add(
        const Duration(seconds: _cloudDownSeconds),
      );
    }
    final fallback = await _localBatchResult();
    if (fallback != null) {
      batchFrames.clear();
      await _applyResult(
        fallback,
        manual: true,
        source: 'on-device',
        inputType: 'batch',
      );
    } else {
      _registerFailure(failureMessage);
    }
  }

  /// Runs the on-device classifier over each stored frame and joins the
  /// labels — the offline equivalent of the single-call batch translate.
  Future<GestureResult?> _localBatchResult() async {
    if (batchFrames.isEmpty) return null;
    final labels = <String>[];
    for (final frame in batchFrames) {
      final decoded = img.decodeImage(frame);
      if (decoded == null) continue;
      var guess = await ml.analyze(decoded);
      if (guess != null) guess = _applyKnn(guess);
      if (guess != null &&
          guess.handPresent &&
          guess.label != null &&
          guess.confidence >= 0.40) {
        labels.add(guess.label!);
      }
    }
    if (labels.isEmpty) return null;
    return GestureResult(
      gesture: labels.join(' '),
      english: labels
          .map((l) => l.startsWith('Letter ') ? l.substring(7) : l)
          .join(' '),
      confidence: 0.5,
      note: 'Recognised on-device — cloud translator unavailable.',
    );
  }

  // -------------------------------------------------------- session capture

  /// Starts a conversation recording: the camera writes an .mp4 while the
  /// frame stream keeps feeding [_latestImage], the on-device hand
  /// detector and the JPEG sampler that powers the single end-of-session
  /// translation request.
  Future<void> startSessionRecording() async {
    final controller = cameraController;
    if (controller == null || !cameraReady || recordingSession) return;
    if (translating ||
        capturingMotion ||
        _sessionTransition ||
        _cameraStarting ||
        !controller.value.isInitialized) {
      return;
    }

    _sessionTransition = true;
    error = null;
    // A stale clip must not be replayable while a new session is underway.
    lastSessionVideoPath = null;
    _sessionFrames.clear();
    _lastSessionSample = DateTime.fromMillisecondsSinceEpoch(0);
    _sessionHasVideo = true;
    try {
      // The platform allows only one frame stream at a time — while
      // recording, onAvailable replaces the regular image stream.
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      // No lockCaptureOrientation here — mid-session orientation calls
      // reconfigure the capture session and rotate the live preview.
      // The init-time lock→unlock already armed CameraX's default-rotation
      // path, so the recording is stamped with the physical orientation
      // automatically.
      try {
        await controller.prepareForVideoRecording();
      } catch (_) {}
      await controller.startVideoRecording(onAvailable: _onRecordingFrame);
    } catch (e) {
      // Devices that refuse video+stream combos still get the feature:
      // frames keep sampling through a normal stream and no video file
      // is saved — the replay button simply stays hidden.
      _sessionHasVideo = false;
      try {
        await controller.startImageStream(_onRecordingFrame);
      } catch (e2) {
        error = 'Could not start recording: $e2';
        try {
          await controller.startImageStream(_onStreamFrame);
        } catch (_) {}
        _sessionTransition = false;
        notifyListeners();
        return;
      }
    }
    _sessionTransition = false;

    recordingSession = true;
    sessionStartedAt = DateTime.now();
    liveTranscript = '';
    liveStatus = '';
    liveSigns = const [];
    // Rolling live captions — translate the trailing ~5s every 3s and
    // merge into [liveTranscript] while the person keeps signing.
    _liveTicker?.cancel();
    _liveTicker = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _liveSegmentTick(),
    );
    _sessionTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (sessionElapsed.inSeconds >= sessionMaxSeconds) {
        unawaited(stopSessionRecording());
      } else {
        notifyListeners();
      }
    });
    notifyListeners();
  }

  /// Frame callback during recording — keeps the live preview pipeline
  /// fed and stashes a JPEG every [_sessionSampleGapMs]. The sampling
  /// half is guarded by [recordingSession] so a stream that outlives the
  /// stop call can't keep writing into a dead buffer.
  void _onRecordingFrame(CameraImage frame) {
    _latestImage = frame;
    _maybeRunLocal(frame);
    if (!recordingSession) return;
    if (_sessionFrames.length >= _maxSessionFrames) return;
    final now = DateTime.now();
    if (now.difference(_lastSessionSample).inMilliseconds <
        _sessionSampleGapMs) {
      return;
    }
    _lastSessionSample = now;
    final jpeg = _cameraImageToJpeg(frame);
    if (jpeg != null) _sessionFrames.add(jpeg);
  }

  /// Stops the active session recording, then sends every sampled frame
  /// to the cloud in one request — the whole signed message comes back
  /// as a single transcript. [cancel] (tab hidden / disposed) discards
  /// the session without translating and skips notifyListeners, which is
  /// unsafe while the controller itself is being disposed.
  Future<void> stopSessionRecording({bool cancel = false}) async {
    if (!recordingSession || _sessionTransition) return;
    _sessionTransition = true;
    recordingSession = false;
    _sessionTicker?.cancel();
    _sessionTicker = null;
    _liveTicker?.cancel();
    _liveTicker = null;
    // Live segments already spoken must not keep playing over the final
    // result — clear the utterance queue on every stop path.
    unawaited(tts.stopAll());

    final controller = cameraController;
    String? rawPath;
    if (_sessionHasVideo &&
        controller != null &&
        controller.value.isRecordingVideo) {
      try {
        final file = await controller.stopVideoRecording();
        rawPath = file.path;
      } catch (_) {}
    } else if (controller?.value.isStreamingImages == true) {
      // Frames-only fallback mode — the recording sampler was a plain
      // image stream.
      try {
        await controller!.stopImageStream();
      } catch (_) {}
    }
    // Recording owns the frame stream — restore the normal preview
    // pipeline unless the camera is about to be released anyway.
    if (!cancel && controller != null && controller.value.isInitialized) {
      try {
        await controller.startImageStream(_onStreamFrame);
      } catch (_) {}
    }

    _sessionHasVideo = false;

    if (cancel) {
      _sessionFrames.clear();
      _sessionTransition = false;
      if (rawPath != null) {
        final f = File(rawPath);
        unawaited(f.delete().catchError((_) => f));
      }
      return;
    }

    final frames = List<Uint8List>.of(_sessionFrames);
    _sessionFrames.clear();
    if (frames.length < 3) {
      error = 'Recording too short — hold record while the person signs.';
      _sessionTransition = false;
      // The clip is still worth keeping for replay even when it was too
      // short to translate.
      if (rawPath != null) unawaited(_saveCompressedVideo(rawPath));
      notifyListeners();
      return;
    }
    lastFrame = frames.last;

    translating = true;
    _sessionTransition = false;
    notifyListeners();
    try {
      final cloudDown =
          _cloudDownUntil != null && DateTime.now().isBefore(_cloudDownUntil!);
      // The real .mp4 carries actual motion — far more accurate for
      // continuous signing than the sampled stills. Compression must
      // wait until the upload attempt finishes (it deletes rawPath).
      GestureResult? result;
      if (!cloudDown && rawPath != null) {
        final r = await gemini.identifySigningSessionFromVideo(
          File(rawPath),
          vocabulary: _vocabulary,
        );
        if (r != null) {
          result = GeminiService.snapToVocabulary(r, _vocabulary);
        }
      }
      // Compression + retention run in the background so a transcode
      // never delays the translation.
      if (rawPath != null) unawaited(_saveCompressedVideo(rawPath));
      if (result != null) {
        _cloudDownUntil = null;
        await _applyResult(
          result,
          manual: true,
          source: 'gemini',
          inputType: 'recording',
        );
        return;
      }
      if (cloudDown) {
        await _sessionFailOrFallback(
          'Cloud translator offline — using on-device recognition.',
          frames,
          markCloudDown: false,
        );
        return;
      }
      result = await gemini.identifySigningSession(
        frames,
        vocabulary: _vocabulary,
        preferAccuracy: true,
      );
      _cloudDownUntil = null;
      await _applyResult(
        GeminiService.snapToVocabulary(result, _vocabulary),
        manual: true,
        source: 'gemini',
        inputType: 'recording',
      );
    } on GeminiQuotaException {
      await _sessionFailOrFallback(
        'Translation service is busy — try again shortly.',
        frames,
      );
    } on StateError catch (e) {
      await _sessionFailOrFallback(e.message, frames);
    } catch (_) {
      await _sessionFailOrFallback(
        'Translation failed — check your connection and try again.',
        frames,
      );
    } finally {
      translating = false;
      notifyListeners();
    }
  }

  /// Offline answer for a session recording — classify each sampled frame
  /// on-device, drop empties, collapse consecutive repeats and join the
  /// survivors into a rough transcript. Striding over a long clip keeps
  /// this under ~50 ML passes.
  Future<void> _sessionFailOrFallback(
    String failureMessage,
    List<Uint8List> frames, {
    bool markCloudDown = true,
  }) async {
    if (markCloudDown) {
      _cloudDownUntil = DateTime.now().add(
        const Duration(seconds: _cloudDownSeconds),
      );
    }
    // Live captions already translated much of the session — present the
    // accumulated transcript rather than discarding the session entirely.
    if (liveTranscript.isNotEmpty) {
      await _applyResult(
        GestureResult(
          gesture: 'Signing session',
          english: liveTranscript,
          confidence: 0.6,
          note: '$failureMessage — showing live transcript.',
        ),
        manual: true,
        source: 'gemini',
        inputType: 'recording',
      );
      return;
    }
    final labels = <String?>[];
    final step = frames.length > 50 ? 2 : 1;
    for (var i = 0; i < frames.length; i += step) {
      final decoded = img.decodeImage(frames[i]);
      if (decoded == null) {
        labels.add(null);
        continue;
      }
      var guess = await ml.analyze(decoded);
      if (guess != null) guess = _applyKnn(guess);
      labels.add(
        guess != null &&
                guess.handPresent &&
                guess.label != null &&
                guess.confidence >= 0.40
            ? guess.label
            : null,
      );
    }
    final deduped = dedupeLabels(labels);
    if (deduped.isNotEmpty) {
      await _applyResult(
        GestureResult(
          gesture: deduped.join(' '),
          english: deduped
              .map((l) => l.startsWith('Letter ') ? l.substring(7) : l)
              .join(' '),
          confidence: 0.5,
          note: 'Recognised on-device — cloud translator unavailable.',
        ),
        manual: true,
        source: 'on-device',
        inputType: 'recording',
      );
    } else {
      _registerFailure(failureMessage);
    }
  }

  /// Collapses consecutive duplicate labels from a sampled frame
  /// sequence — the same sign held across several frames counts once.
  /// A run of null entries separates two performances of the same sign,
  /// so repeats on either side of a gap are both kept.
  static List<String> dedupeLabels(List<String?> raw) {
    final out = <String>[];
    String? previous;
    var gapSeen = false;
    for (final label in raw) {
      if (label == null) {
        gapSeen = true;
        continue;
      }
      if (label == previous && !gapSeen) continue;
      out.add(label);
      previous = label;
      gapSeen = false;
    }
    return out;
  }

  /// Transcodes the just-finished recording to a smaller file, moves it
  /// into app storage and prunes old sessions — runs in the background
  /// after [stopSessionRecording] so translation isn't delayed. Falls
  /// back to keeping the raw file when compression fails.
  Future<void> _saveCompressedVideo(String rawPath) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'recordings'));
      await dir.create(recursive: true);

      String? compressedPath;
      try {
        final info = await VideoCompress.compressVideo(
          rawPath,
          quality: VideoQuality.MediumQuality,
          deleteOrigin: false,
          includeAudio: false,
        );
        compressedPath = info?.path;
      } catch (_) {
        // Compression is best-effort — the original still counts.
      }

      final dest = p.join(
        dir.path,
        'session_${DateTime.now().millisecondsSinceEpoch}.mp4',
      );
      // The compressor can report a path for output it never wrote —
      // verify before trusting it over the raw capture.
      var source = rawPath;
      if (compressedPath != null &&
          compressedPath.isNotEmpty &&
          await File(compressedPath).exists()) {
        source = compressedPath;
      }
      await File(source).copy(dest);
      try {
        if (rawPath != dest) await File(rawPath).delete();
        if (compressedPath != null && compressedPath != dest) {
          await File(compressedPath).delete();
        }
      } catch (_) {}

      lastSessionVideoPath = dest;
      await _pruneRecordings(dir);
      notifyListeners();
    } catch (_) {
      // Storage failures shouldn't affect the translation result.
    }
  }

  /// Keeps only the newest [_maxKeptRecordings] clips so saved sessions
  /// can't grow storage unboundedly.
  Future<void> _pruneRecordings(Directory dir) async {
    try {
      final files = await dir
          .list()
          .where((e) => e is File && e.path.endsWith('.mp4'))
          .cast<File>()
          .toList();
      if (files.length <= _maxKeptRecordings) return;
      files.sort(
        (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
      );
      for (final old in files.skip(_maxKeptRecordings)) {
        await old.delete();
      }
    } catch (_) {}
  }

  /// Applies the on-device result when the cloud failed but the local
  /// model saw a sign; otherwise records the failure as before.
  /// [markCloudDown] opens the [_cloudDownUntil] window — the skip-cloud
  /// path itself passes false so the window isn't extended forever.
  Future<void> _failOrFallback(
    String failureMessage, {
    required bool manual,
    bool markCloudDown = true,
  }) async {
    if (markCloudDown) {
      _cloudDownUntil = DateTime.now().add(
        const Duration(seconds: _cloudDownSeconds),
      );
    }
    final fallback = _offlineFallback();
    if (fallback != null) {
      await _applyResult(fallback, manual: manual, source: 'on-device');
    } else {
      _registerFailure(failureMessage);
    }
  }

  /// Up to 8 candidate sign illustrations for the classification prompt —
  /// the on-device guess label plus the k-NN's nearest sample labels.
  /// Best-effort: missing illustrations are skipped so the request is
  /// never delayed by image lookup.
  Future<Map<String, Uint8List>> _candidateReferences(HandGuess? guess) async {
    final candidates = <String>{if (guess?.label != null) guess!.label!};
    final lm = guess?.landmarks;
    if (lm != null && _samples.isNotEmpty) {
      final normalized = HandSignClassifier.normalizeLandmarks(lm);
      final scored = <(String, double)>[];
      _samples.forEach((label, vectors) {
        var best = double.infinity;
        for (final v in vectors) {
          var d = 0.0;
          for (
            var i = 0;
            i + 1 < v.length && i + 1 < normalized.length;
            i += 3
          ) {
            final dx = v[i] - normalized[i];
            final dy = v[i + 1] - normalized[i + 1];
            d += dx * dx + dy * dy;
          }
          if (d < best) best = d;
        }
        scored.add((label, best));
      });
      scored.sort((a, b) => a.$2.compareTo(b.$2));
      candidates.addAll(scored.take(7).map((s) => s.$1));
    }
    final refs = <String, Uint8List>{};
    for (final label in candidates.take(8)) {
      final asset = signAssetFor(label);
      if (asset == null) continue;
      try {
        refs[label] = (await rootBundle.load(asset)).buffer.asUint8List();
      } catch (_) {}
    }
    return refs;
  }

  /// Low-confidence cloud answers become "Could not determine" while
  /// keeping the model's reason — a refusal that explains itself beats a
  /// wrong guess. On-device answers are trusted as-is.
  static GestureResult gateResult(
    GestureResult result, {
    required String source,
  }) {
    if (source != 'gemini' ||
        result.english == 'Could not determine' ||
        result.confidence >= 0.45) {
      return result;
    }
    return GestureResult(
      gesture: 'Unknown',
      english: 'Could not determine',
      confidence: result.confidence,
      note: result.note.isEmpty
          ? 'Low confidence — sign again slowly and clearly.'
          : result.note,
    );
  }

  /// Reconciles a cloud answer with the on-device guess — agreement
  /// boosts displayed confidence; a confident trained k-NN label beats a
  /// conflicting cloud guess (recorded samples are the strongest
  /// evidence this system has).
  static GestureResult ensembleResult(
    GestureResult cloud,
    HandGuess? guess,
    List<String> vocabulary,
  ) {
    if (guess == null ||
        !guess.handPresent ||
        guess.label == null ||
        cloud.english == 'Could not determine') {
      return cloud;
    }
    if (guess.label == cloud.gesture) {
      return GestureResult(
        gesture: cloud.gesture,
        english: cloud.english,
        confidence: math.max(cloud.confidence, 0.95),
        note: cloud.note,
      );
    }
    if (guess.confidence >= 0.8 &&
        (vocabulary.isEmpty || vocabulary.contains(guess.label))) {
      final label = guess.label!;
      return GestureResult(
        gesture: label,
        english: label.startsWith('Letter ') ? label.substring(7) : label,
        confidence: guess.confidence,
        note: 'Matched on-device training samples.',
      );
    }
    return cloud;
  }

  GestureResult _localResult(HandGuess guess) {
    final label = guess.label!;
    return GestureResult(
      gesture: label,
      english: label.startsWith('Letter ') ? label.substring(7) : label,
      confidence: guess.confidence,
      note: 'Recognised on-device.',
    );
  }

  Future<void> _applyResult(
    GestureResult result, {
    required bool manual,
    required String source,
    String inputType = 'gesture',
  }) async {
    final gated = gateResult(result, source: source);
    final changed =
        lastResult == null ||
        lastResult!.gesture != gated.gesture ||
        lastResult!.english != gated.english;
    lastResult = gated;
    _failureCount = 0;
    autoDisabled = false;
    _backoffUntil = null;

    final unrecognized = gated.english == 'Could not determine';
    final user = auth.currentUser;
    if (user != null && changed && !unrecognized) {
      final record = TranslationRecord(
        userId: user.id!,
        inputType: inputType,
        inputLabel: gated.gesture,
        translatedText: gated.english,
        confidence: gated.confidence,
        source: source,
        createdAt: DateTime.now(),
      );
      await db.saveTranslation(record);
      history.insert(0, record);
      if (history.length > 200) history.removeRange(200, history.length);
    }

    // Recorded sessions already spoke each live segment — re-reading the
    // whole transcript would duplicate the audio. When nothing was
    // spoken live (e.g. all segments failed), the final still speaks.
    if (settings.autoSpeak &&
        gated.english.isNotEmpty &&
        gated.english != 'Could not determine' &&
        (manual || changed) &&
        (inputType != 'recording' || liveTranscript.isEmpty)) {
      await tts.speak(gated.english);
    }
    notifyListeners();
  }

  void _registerFailure(String message) {
    _failureCount++;
    error = message.replaceFirst('Bad state: ', '');
    if (_failureCount >= _maxFailures) {
      _backoffUntil = DateTime.now().add(
        const Duration(seconds: _backoffSeconds),
      );
      autoDisabled = true;
    }
  }

  Future<void> speakLast() async {
    final text = lastResult?.english;
    if (text != null && text.isNotEmpty) {
      await tts.speak(text);
    }
  }

  /// Set once [dispose] runs — in-flight async work (recording stop,
  /// video compression, auto-translate ticks) may outlive the widget and
  /// still reach notifyListeners; notifying a disposed ChangeNotifier
  /// throws, so those late calls are dropped here.
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _liveTicker?.cancel();
    _disposed = true;
    auth.removeListener(_onAuthChanged);
    unawaited(tts.stopAll());
    unawaited(_releaseCamera());
    super.dispose();
  }
}
