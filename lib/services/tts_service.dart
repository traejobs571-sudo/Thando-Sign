import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(prefs.getDouble('speech_rate') ?? 0.45);
    await _tts.setVolume(prefs.getDouble('speech_volume') ?? 1.0);
    await _tts.setPitch(prefs.getDouble('speech_pitch') ?? 1.0);
    _initialized = true;
  }

  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    await init();
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> stop() async {
    await _tts.stop();
  }

  Future<void> setRate(double rate) async {
    await init();
    await _tts.setSpeechRate(rate);
  }

  Future<void> setPitch(double pitch) async {
    await init();
    await _tts.setPitch(pitch);
  }

  Future<void> setVolume(double volume) async {
    await init();
    await _tts.setVolume(volume);
  }

  Future<void> setLanguage(String lang) async {
    await init();
    await _tts.setLanguage(lang);
  }
}
