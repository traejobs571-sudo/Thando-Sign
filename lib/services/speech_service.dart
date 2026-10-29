import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Speech → text for the "hearing person speaks, deaf person sees the sign" flow.
class SpeechService extends ChangeNotifier {
  final stt.SpeechToText _speech = stt.SpeechToText();

  bool _available = false;
  bool _listening = false;
  String _lastError = '';
  String recognizedText = '';
  String partialText = '';

  bool get available => _available;
  bool get listening => _listening;
  String get lastError => _lastError;

  Future<bool> init() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      _lastError = 'Microphone permission denied.';
      notifyListeners();
      return false;
    }
    _available = await _speech.initialize(
      onError: (e) {
        _lastError = e.errorMsg;
        _listening = false;
        notifyListeners();
      },
      onStatus: (status) {
        _listening = status == 'listening';
        notifyListeners();
      },
    );
    notifyListeners();
    return _available;
  }

  Future<void> start() async {
    if (!_available && !await init()) return;
    recognizedText = '';
    partialText = '';
    _lastError = '';
    _listening = true;
    notifyListeners();

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
      ),
    );
  }

  Future<void> stop() async {
    await _speech.stop();
    _listening = false;
    if (recognizedText.isEmpty) recognizedText = partialText;
    notifyListeners();
  }

  Future<void> cancel() async {
    await _speech.cancel();
    _listening = false;
    partialText = '';
    notifyListeners();
  }
}
