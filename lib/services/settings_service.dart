import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide tunables exposed to admins in the dashboard — recognition
/// timing and thresholds that used to be hardcoded constants.
class AppSettings extends ChangeNotifier {
  static const _autoMsKey = 'auto_translate_ms';
  static const _floorKey = 'local_confidence_floor';
  static const _syncEnabledKey = 'cloud_sync_enabled';
  static const _lastSyncKey = 'last_sync_at';
  static const _autoSpeakKey = 'auto_speak';
  static const _speechRateKey = 'speech_rate';
  static const _speechPitchKey = 'speech_pitch';
  static const _speechVolumeKey = 'speech_volume';
  static const _retentionDaysKey = 'history_retention_days';
  static const _allowRegistrationKey = 'allow_registration';

  static const defaultAutoTranslateMs = 1200;
  static const defaultConfidenceFloor = 0.70;
  static const defaultSpeechRate = 0.45;
  static const defaultSpeechPitch = 1.0;
  static const defaultSpeechVolume = 1.0;

  /// 0 means keep history forever.
  static const defaultRetentionDays = 0;

  int autoTranslateMs = defaultAutoTranslateMs;
  double localConfidenceFloor = defaultConfidenceFloor;
  bool cloudSyncEnabled = true;
  DateTime? lastSyncAt;

  /// Voice output and per-user playback preferences.
  bool autoSpeak = true;
  double speechRate = defaultSpeechRate;
  double speechPitch = defaultSpeechPitch;
  double speechVolume = defaultSpeechVolume;

  /// Admin data controls.
  int historyRetentionDays = defaultRetentionDays;
  bool allowRegistration = true;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    autoTranslateMs = prefs.getInt(_autoMsKey) ?? defaultAutoTranslateMs;
    localConfidenceFloor = prefs.getDouble(_floorKey) ?? defaultConfidenceFloor;
    cloudSyncEnabled = prefs.getBool(_syncEnabledKey) ?? true;
    lastSyncAt = DateTime.tryParse(prefs.getString(_lastSyncKey) ?? '');
    autoSpeak = prefs.getBool(_autoSpeakKey) ?? true;
    speechRate = prefs.getDouble(_speechRateKey) ?? defaultSpeechRate;
    speechPitch = prefs.getDouble(_speechPitchKey) ?? defaultSpeechPitch;
    speechVolume = prefs.getDouble(_speechVolumeKey) ?? defaultSpeechVolume;
    historyRetentionDays =
        prefs.getInt(_retentionDaysKey) ?? defaultRetentionDays;
    allowRegistration = prefs.getBool(_allowRegistrationKey) ?? true;
    notifyListeners();
  }

  Future<void> setAutoTranslateMs(int value) async {
    autoTranslateMs = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_autoMsKey, value);
  }

  Future<void> setLocalConfidenceFloor(double value) async {
    localConfidenceFloor = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_floorKey, value);
  }

  Future<void> setCloudSyncEnabled(bool value) async {
    cloudSyncEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_syncEnabledKey, value);
  }

  /// Persisted so the dashboard can show when data last reached the
  /// server even after an app restart.
  Future<void> noteSynced(DateTime at) async {
    lastSyncAt = at;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastSyncKey, at.toIso8601String());
  }

  Future<void> setAutoSpeak(bool value) async {
    autoSpeak = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoSpeakKey, value);
  }

  Future<void> setSpeechRate(double value) async {
    speechRate = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_speechRateKey, value);
  }

  Future<void> setSpeechPitch(double value) async {
    speechPitch = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_speechPitchKey, value);
  }

  Future<void> setSpeechVolume(double value) async {
    speechVolume = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_speechVolumeKey, value);
  }

  Future<void> setHistoryRetentionDays(int value) async {
    historyRetentionDays = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_retentionDaysKey, value);
  }

  Future<void> setAllowRegistration(bool value) async {
    allowRegistration = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_allowRegistrationKey, value);
  }
}
