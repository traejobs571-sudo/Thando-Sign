import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'auth_service.dart';
import 'connectivity_service.dart';
import 'db_service.dart';
import 'gesture_image_service.dart';
import 'settings_service.dart';
import 'supabase_service.dart';

/// Uploads queued local writes to Supabase and pulls shared data down.
///
/// Local SQLite stays the source of truth — every write lands there first
/// and queues in `pending_sync`; this service flushes the queue whenever
/// the device is online and a Supabase session exists. Gestures and
/// profiles also pull down so admin changes propagate between devices.
class SyncService extends ChangeNotifier {
  SyncService({
    required this.db,
    required this.supabase,
    required this.connectivity,
    required this.settings,
    this.images,
  }) {
    lastSyncAt = settings.lastSyncAt;
    connectivity.addListener(_onConnectivityChanged);
    settings.addListener(_onSettingsChanged);
  }

  final DbService db;
  final SupabaseService supabase;
  final ConnectivityService connectivity;
  final AppSettings settings;
  final GestureImageService? images;
  AuthService? _auth;
  StreamSubscription<List<Map<String, dynamic>>>? _gestureSub;
  Timer? _realtimeRetry;
  int _realtimeAttempts = 0;

  static const _maxAttempts = 5;
  static const _skipWhenForeign = {'translations'};

  bool syncing = false;
  int pendingCount = 0;
  DateTime? lastSyncAt;
  String? lastError;

  /// Bumped whenever a Realtime push lands — UIs diff this to know the
  /// local dataset changed without polling on every notify.
  DateTime? lastRemoteChangeAt;

  bool get enabled => supabase.enabled;
  bool get canSync =>
      enabled &&
      settings.cloudSyncEnabled &&
      connectivity.isOnline &&
      supabase.isAuthed;

  /// Human-readable reason sync can't run right now, or null when
  /// [canSync] is true. Surfaced under the sync card so the manual
  /// button never appears dead.
  String? get blocker {
    if (!enabled) {
      return 'Supabase is not configured — set SUPABASE_URL and '
          'SUPABASE_ANON_KEY in assets/.env.';
    }
    if (!settings.cloudSyncEnabled) {
      return 'Cloud sync is off — enable it under Admin → Settings.';
    }
    if (!connectivity.isOnline) {
      return 'No network connection detected.';
    }
    if (!supabase.isAuthed) {
      final detail = _auth?.provisionError;
      return 'No cloud session — the local sign-in is offline-only. '
          'Sign out and sign back in while online to reconnect.'
          '${detail != null ? ' Last attempt: $detail.' : ''}';
    }
    return null;
  }

  /// Called once from main() after AuthService exists — kicks a sync on
  /// every sign-in and on startup if a session was restored.
  void attachAuth(AuthService auth) {
    _auth = auth;
    auth.addListener(_onAuthChanged);
    _updateRealtime();
    unawaited(refreshPending());
  }

  void _onAuthChanged() {
    _updateRealtime();
    if (_auth?.currentUser != null) unawaited(syncNow());
  }

  void _onConnectivityChanged() {
    _updateRealtime();
    if (connectivity.isOnline) unawaited(syncNow());
  }

  void _onSettingsChanged() {
    _updateRealtime();
    notifyListeners();
  }

  Future<void> refreshPending() async {
    pendingCount = await db.pendingSyncCount();
    notifyListeners();
  }

  /// Manual trigger — pull shared rows, then flush the outbox.
  Future<void> syncNow() async {
    if (syncing) return;
    syncing = true;
    lastError = null;
    notifyListeners();
    try {
      // A stored refresh token can resurrect an expired session — try
      // once before declaring sync impossible.
      if (enabled &&
          settings.cloudSyncEnabled &&
          connectivity.isOnline &&
          !supabase.isAuthed) {
        await supabase.refreshSession();
      }
      if (canSync) {
        await _pull();
        await _flush();
        lastSyncAt = DateTime.now();
        await settings.noteSynced(lastSyncAt!);
        debugPrint('Sync OK — pending: ${await db.pendingSyncCount()}');
      } else {
        lastError = blocker;
      }
    } catch (e) {
      lastError = e.toString();
      debugPrint('Sync failed: $e');
    } finally {
      pendingCount = await db.pendingSyncCount();
      syncing = false;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------ push

  Future<void> _flush() async {
    final rows = await db.pendingSyncRows();
    for (final row in rows) {
      if (!canSync) return;
      final id = row['id'] as int;
      final entity = row['entity'] as String;
      final payload =
          jsonDecode(row['payload'] as String) as Map<String, dynamic>;

      // Rows owned by another signed-out account wait for that account.
      if (_skipWhenForeign.contains(entity) &&
          payload['user_email'] != null &&
          payload['user_email'] != supabase.currentEmail) {
        continue;
      }

      try {
        final result = await supabase.pushRow(
          entity,
          row['entity_key'] as String,
          row['op'] as String,
          payload,
        );
        if (entity == 'profiles' && result != null) {
          await db.linkRemoteUser(
            payload['email'] as String,
            remoteId: result['id'] as String?,
          );
        }
        await db.markSynced(id);
      } on PostgrestException catch (e) {
        // RLS denial — e.g. an admin-only op queued while a normal user is
        // signed in. Leave it queued; it flushes when an admin signs in.
        if (e.code == '42501' || e.message.contains('row-level security')) {
          continue;
        }
        await _recordFailure(id, row, e);
        return; // preserve order — stop at first real failure
      } catch (e) {
        await _recordFailure(id, row, e);
        return;
      }
    }
  }

  Future<void> _recordFailure(
    int id,
    Map<String, Object?> row,
    Object error,
  ) async {
    await db.bumpSyncAttempt(id);
    if ((row['attempts'] as int? ?? 0) + 1 >= _maxAttempts) {
      await db.markSynced(id);
      await db.logActivity(
        null,
        'sync_drop',
        'Dropped ${row['entity']} ${row['op']} after $_maxAttempts attempts: $error',
      );
    }
    lastError = error.toString();
  }

  // ------------------------------------------------------------------ pull

  Future<void> _pull() async {
    // A failed pull must not starve the outbox — the flush below still
    // runs even when the shared tables are unreachable mid-cycle.
    var changed = false;
    try {
      await db.applyRemoteGestures(await supabase.pullGestures());
      changed = true;
    } catch (e) {
      debugPrint('Gesture pull failed: $e');
    }
    // Fetch any remote gesture illustrations we don't have yet — lazy,
    // deduplicated, and never blocks sync.
    unawaited(images?.primeFromDb() ?? Future.value());

    try {
      final profiles = await supabase.pullProfiles();
      for (final p in profiles) {
        await db.upsertProfileFromRemote(p);
      }
      changed = true;
    } catch (e) {
      debugPrint('Profile pull failed: $e');
    }

    // Let listeners (dataset + users tabs) know remote state landed —
    // profiles aren't realtime, so this is the only refresh trigger.
    if (changed) {
      lastRemoteChangeAt = DateTime.now();
      notifyListeners();
    }
  }

  // -------------------------------------------------------------- realtime

  /// Live dataset updates: while signed in + online, a Realtime stream on
  /// `gestures` feeds every remote change straight into the local DB, so
  /// a second device (or a Supabase-side edit) appears without waiting
  /// for the next manual sync.
  void _updateRealtime() {
    if (canSync && _gestureSub == null) {
      _gestureSub = supabase.gesturesStream().listen(
        (rows) => unawaited(_onRemoteGestures(rows)),
        onError: (Object e) {
          debugPrint('Realtime gestures error: $e');
          _scheduleRealtimeRetry();
        },
      );
    } else if (!canSync && _gestureSub != null) {
      _realtimeRetry?.cancel();
      _realtimeAttempts = 0;
      unawaited(_gestureSub!.cancel());
      _gestureSub = null;
    }
  }

  /// The Realtime stream dies permanently after an error (timeouts,
  /// dropped websockets on mobile networks). Drop the dead subscription
  /// and re-subscribe with a linear backoff so live dataset updates
  /// resume without an app restart.
  void _scheduleRealtimeRetry() {
    unawaited(_gestureSub?.cancel());
    _gestureSub = null;
    if (!canSync) return;
    _realtimeAttempts++;
    _realtimeRetry?.cancel();
    _realtimeRetry = Timer(
      Duration(seconds: (5 * _realtimeAttempts).clamp(5, 60)),
      _updateRealtime,
    );
  }

  bool _reconciling = false;
  List<Map<String, dynamic>>? _pendingRemoteRows;

  /// Every emission carries the full table — fold bursts so one pass
  /// applies the newest snapshot instead of queuing several
  /// full-table reconciles back to back.
  Future<void> _onRemoteGestures(List<Map<String, dynamic>> rows) async {
    _pendingRemoteRows = rows;
    if (_reconciling) return;
    _reconciling = true;
    try {
      while (_pendingRemoteRows != null) {
        final batch = _pendingRemoteRows!;
        _pendingRemoteRows = null;
        try {
          await db.applyRemoteGestures(batch);
          _realtimeAttempts = 0;
          lastRemoteChangeAt = DateTime.now();
          notifyListeners();
        } catch (e) {
          debugPrint('Realtime reconcile failed: $e');
          _pendingRemoteRows = null;
        }
      }
    } finally {
      _reconciling = false;
    }
  }

  @override
  void dispose() {
    _gestureSub?.cancel();
    _realtimeRetry?.cancel();
    connectivity.removeListener(_onConnectivityChanged);
    settings.removeListener(_onSettingsChanged);
    _auth?.removeListener(_onAuthChanged);
    super.dispose();
  }
}
