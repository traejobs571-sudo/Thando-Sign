import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'cloud_stt_service.dart';

/// Speech → text for the "hearing person speaks, deaf person sees the sign" flow.
/// The OS recogniser streams live partials; the FINAL transcript comes
/// from the recorded audio through cloud STT when available — the
/// OS text is only the live preview and the offline fallback.
/// Which hardware consumer holds the mic this session — never both at
/// once, so Android's single-client audio path can't deadlock.
enum _CaptureMode { none, recorderOnly, osRecognizerOnly }

class SpeechService extends ChangeNotifier {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final AudioRecorder _recorder = AudioRecorder();
  CloudSttService? _cloudStt;
  String? _recordingPath;
  bool _transcribing = false;
  _CaptureMode _captureMode = _CaptureMode.none;
  bool _isTransitioning = false;

  /// Circuit breaker for cloud STT. While the recorder owns the mic the
  /// OS recogniser gets no audio, so a failed cloud call leaves the
  /// session with NO text at all — dead feature. When transcription
  /// fails (quota exhausted, backend down) we stop recording for a
  /// cooldown so the next capture gives the mic back to the OS
  /// recogniser and keeps working degraded instead of dead.
  DateTime? _cloudDownUntil;
  static const _cloudDownSeconds = 300;
  bool _probedCloud = false;

  bool get _cloudDown =>
      _cloudDownUntil != null && DateTime.now().isBefore(_cloudDownUntil!);

  /// Locale preference order — Zimbabwean and South African English
  /// recognise regional names and accents (Thando, Tariro, Tatenda)
  /// far better than the US-English default most devices ship with.
  /// The first one the device actually supports wins.
  static const _preferredLocales = ['en_zw', 'en_za', 'en_gb'];

  bool _available = false;
  bool _listening = false;
  String _lastError = '';
  String? _localeId;
  String recognizedText = '';
  String partialText = '';

  /// Where the displayed transcript came from — 'cloud' once the cloud
  /// verifies it, 'device' while it's still the OS recogniser's text.
  String transcriptSource = 'device';

  bool get available => _available;
  bool get listening => _listening;
  bool get transcribing => _transcribing;
  String get lastError => _lastError;

  void setCloudStt(CloudSttService stt) => _cloudStt = stt;

  /// Mic permission is all the recorder path needs — the OS recogniser
  /// initialises lazily and its failure must not gate recording.
  Future<bool> init() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      _lastError = 'Microphone permission denied.';
      notifyListeners();
      return false;
    }
    if (!_available) {
      _available = await _speech.initialize(
        onError: (e) {
          _lastError = e.errorMsg;
          // Diagnostics only — the recogniser losing the mic must NOT
          // kill the user's capture session; stop()/cancel() end it.
          notifyListeners();
        },
        onStatus: (status) {
          // Diagnostics only — _listening means "the user is capturing",
          // owned solely by start()/stop()/cancel().
          notifyListeners();
        },
      );
      if (_available) await _pickLocale();
    }
    // One probe per session — quota/billing/key problems only surface
    // in a real transcription call, and learning about them BEFORE the
    // first capture lets that attempt keep the OS recogniser's mic
    // instead of recording a clip that can never be transcribed.
    if (_cloudStt != null && !_probedCloud) {
      _probedCloud = true;
      switch (await _cloudStt!.checkHealth()) {
        case CloudSttHealth.ready:
          break;
        case CloudSttHealth.down:
          _cloudDownUntil = DateTime.now().add(
            const Duration(seconds: _cloudDownSeconds),
          );
        case CloudSttHealth.misconfigured:
          // The backend reports itself unconfigured (e.g. no
          // STT_SELFHOSTED_URL) — no cooldown makes that recoverable,
          // so drop the cloud path entirely this session. The recorder
          // never claims the mic and the OS recogniser handles every
          // capture instead of alternating dead/error cycles.
          _cloudStt = null;
      }
    }
    notifyListeners();
    // Mic permission granted — recorder path usable even when the OS
    // recogniser failed to initialise on this device.
    return true;
  }

  /// Chooses the best installed recognition locale — first preference
  /// the device supports, otherwise the system default. Devices report
  /// ids as 'en-ZW' or 'en_ZW', so comparison is normalised.
  Future<void> _pickLocale() async {
    try {
      final locales = await _speech.locales();
      final ids = locales.map((l) => l.localeId).toList();
      for (final want in _preferredLocales) {
        final hit = ids.where(
          (id) => id.replaceAll('-', '_').toLowerCase() == want,
        );
        if (hit.isNotEmpty) {
          _localeId = hit.first;
          return;
        }
      }
      _localeId = (await _speech.systemLocale())?.localeId;
    } catch (_) {
      _localeId = null; // default locale is a safe fallback
    }
  }

  Future<void> start() async {
    // Atomic guard — a rapid double-tap can't interleave start/stop.
    if (_isTransitioning) return;
    _isTransitioning = true;
    try {
      if (!await init()) return; // fails only on denied mic permission
      recognizedText = '';
      partialText = '';
      _lastError = '';
      transcriptSource = 'device';
      _listening = true;
      _captureMode = _CaptureMode.none;
      notifyListeners();

      // Single-mic ownership: try the hardware recorder first — it
      // feeds cloud STT, the accurate path. The FIRST consumer holds the
      // mic exclusively, so after a successful start the recorder can't
      // lose it — the OS listen below is best-effort live partials on
      // devices that allow both, and provides fallback text at stop.
      // No recorder when the cloud is absent or known-down: the clip
      // couldn't be transcribed anyway and recording would only starve
      // the OS recogniser of audio.
      if (_cloudStt != null && !_cloudDown && await _startRecording()) {
        _captureMode = _CaptureMode.recorderOnly;
      } else if (_available) {
        // Recorder failed → OS recogniser fallback.
        _captureMode = _CaptureMode.osRecognizerOnly;
      } else {
        _lastError = 'Microphone unavailable.';
        _listening = false;
        notifyListeners();
        return;
      }

      try {
        await _speech.listen(
          onResult: (result) {
            partialText = result.recognizedWords;
            if (result.finalResult) {
              recognizedText = result.recognizedWords;
              _listening = false;
            }
            notifyListeners();
          },
          listenOptions: stt.SpeechListenOptions(
            listenFor: const Duration(seconds: 30),
            pauseFor: const Duration(seconds: 4),
            partialResults: true,
            localeId: _localeId,
          ),
        );
      } catch (e) {
        // In recorderOnly mode the recogniser losing the mic is
        // expected — ignore it. Only when the OS path was the plan do
        // we surface a failure.
        if (_captureMode == _CaptureMode.osRecognizerOnly) {
          _lastError = 'Microphone unavailable.';
          _listening = false;
          _captureMode = _CaptureMode.none;
          notifyListeners();
        }
      }
    } finally {
      _isTransitioning = false;
    }
  }

  /// Records mic audio to a temp m4a — returns true only when the
  /// recorder actually owns the mic, so callers can pick a mode.
  Future<bool> _startRecording() async {
    try {
      if (!await _recorder.hasPermission()) return false;
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/speech_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );
      // Confirm the recorder actually owns the mic — some devices hand
      // it to the OS recogniser instead and silently write nothing.
      if (await _recorder.isRecording()) {
        _recordingPath = path;
        return true;
      }
    } catch (_) {}
    _recordingPath = null;
    return false;
  }

  Future<void> stop() async {
    // A tap that lands while start() is still opening the mic waits for
    // it rather than being dropped — otherwise the session stays live
    // with no way to end it from the same button.
    var waitedMs = 0;
    while (_isTransitioning && waitedMs < 1500) {
      await Future.delayed(const Duration(milliseconds: 50));
      waitedMs += 50;
    }
    if (_isTransitioning) return;
    _isTransitioning = true;
    try {
      final mode = _captureMode;
      _captureMode = _CaptureMode.none;
      _listening = false;

      if (mode == _CaptureMode.recorderOnly) {
        final path = _recordingPath;
        _recordingPath = null;
        try {
          await _recorder.stop();
        } catch (_) {}
        try {
          await _speech.stop(); // also end the best-effort OS listen
        } catch (_) {}
        if (recognizedText.isEmpty) recognizedText = partialText;
        // Flag BEFORE notifying — the UI sees a verified transcript is
        // on the way and doesn't flash 'Nothing heard' prematurely.
        final expectCloud = path != null && _cloudStt != null;
        _transcribing = expectCloud;
        notifyListeners();
        if (expectCloud) unawaited(_transcribeRecording(path));
      } else {
        // OS-recogniser mode — the normal stop path.
        try {
          await _speech.stop();
        } catch (_) {}
        if (recognizedText.isEmpty) recognizedText = partialText;
        notifyListeners();
      }
    } finally {
      _isTransitioning = false;
    }
  }

  /// Sends the clip through cloud STT — the accurate transcript
  /// replaces the OS text and notifies listeners. On failure (quota,
  /// network, backend down), the on-device heard text still wins so
  /// speech→sign keeps working — degraded, never dead.
  Future<void> _transcribeRecording(String path) async {
    final text = await _cloudStt?.transcribe(path);
    _transcribing = false;
    if (text != null) {
      _cloudDownUntil = null;
      recognizedText = text;
      transcriptSource = 'cloud';
    } else {
      // Mark the cloud path down — the next capture hands the mic to
      // the OS recogniser instead of recording another untranscribable
      // clip. A success later clears the flag. Clearing _probedCloud
      // makes the first capture after the cooldown re-verify health —
      // a still-misconfigured backend is dropped permanently instead
      // of burning a clip on every cooldown expiry.
      _cloudDownUntil = DateTime.now().add(
        const Duration(seconds: _cloudDownSeconds),
      );
      _probedCloud = false;
      if (recognizedText.isEmpty && partialText.isNotEmpty) {
        recognizedText = partialText;
        transcriptSource = 'device';
      } else if (recognizedText.isEmpty) {
        _lastError = 'Speech service unavailable — tap the mic to try again.';
      }
    }
    notifyListeners();
  }

  Future<void> cancel() async {
    _captureMode = _CaptureMode.none;
    _listening = false;
    partialText = '';
    _recordingPath = null;
    try {
      await _speech.cancel();
    } catch (_) {}
    try {
      await _recorder.stop();
    } catch (_) {}
    notifyListeners();
  }

  @override
  void dispose() {
    _recorder.dispose();
    super.dispose();
  }
}
