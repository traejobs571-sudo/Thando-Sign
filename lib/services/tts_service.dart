import 'dart:collection';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;

  /// Live-caption utterances — spoken in arrival order without cutting
  /// the current utterance. Bounded so a long session can't stack a
  /// backlog of speech behind a slow engine.
  final Queue<String> _liveQueue = Queue<String>();
  static const _maxPendingLive = 2;
  bool _liveSpeaking = false;

  Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(prefs.getDouble('speech_rate') ?? 0.45);
    await _tts.setVolume(prefs.getDouble('speech_volume') ?? 1.0);
    await _tts.setPitch(prefs.getDouble('speech_pitch') ?? 1.0);
    try {
      await _tts.awaitSpeakCompletion(true);
    } catch (_) {}
    _initialized = true;
  }

  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    await init();
    await _tts.stop();
    await _tts.speak(text);
  }

  /// Speaks [text] after any in-flight live utterance finishes — used for
  /// rolling session captions where chopping the previous segment
  /// mid-word sounds broken. Over-length queues shed the oldest pending
  /// segment so audio stays close to the live transcript.
  Future<void> speakLive(String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    await init();
    _liveQueue.add(clean);
    while (_liveQueue.length > _maxPendingLive) {
      _liveQueue.removeFirst();
    }
    if (_liveSpeaking) return;
    _liveSpeaking = true;
    try {
      while (_liveQueue.isNotEmpty) {
        final next = _liveQueue.removeFirst();
        try {
          await _tts.speak(next);
        } catch (_) {
          // A failed utterance must not wedge the queue — keep draining.
        }
      }
    } finally {
      _liveSpeaking = false;
    }
  }

  /// Stops playback and drops pending live utterances — session stop,
  /// mode switch and dispose all funnel here so stale captions can't
  /// play over a new context.
  Future<void> stopAll() async {
    _liveQueue.clear();
    await _tts.stop();
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
