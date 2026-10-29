import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

/// Monitors network availability so the app can warn the user when
/// Gemini-powered translation can't reach the internet.
class ConnectivityService extends ChangeNotifier {
  ConnectivityService() {
    _sub = Connectivity().onConnectivityChanged.listen(_onChanged);
    _check();
  }

  /// No platform plugin — lets unit tests drive [isOnline] directly.
  @visibleForTesting
  ConnectivityService.testing({bool online = true})
    : _results = online
          ? const [ConnectivityResult.wifi]
          : const [ConnectivityResult.none];

  @visibleForTesting
  void setOnline(bool online) {
    _results = online
        ? const [ConnectivityResult.wifi]
        : const [ConnectivityResult.none];
    notifyListeners();
  }

  StreamSubscription<List<ConnectivityResult>>? _sub;
  List<ConnectivityResult> _results = const [];

  bool get isOnline => _results.any((r) => r != ConnectivityResult.none);
  bool get onWifi => _results.contains(ConnectivityResult.wifi);
  bool get onMobile => _results.contains(ConnectivityResult.mobile);

  String get statusLabel {
    if (!isOnline) return 'Offline';
    if (onWifi && onMobile) return 'Wi-Fi + Mobile data';
    if (onWifi) return 'Wi-Fi';
    if (onMobile) return 'Mobile data';
    return 'Online';
  }

  Future<void> _check() async {
    _onChanged(await Connectivity().checkConnectivity());
  }

  void _onChanged(List<ConnectivityResult> results) {
    _results = results;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
