import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:thando_sign_app/services/db_service.dart';
import 'package:thando_sign_app/services/supabase_service.dart';

bool _ffiReady = false;

/// Real SQLite via the FFI backend — DbService otherwise needs a device.
void initFfi() {
  if (_ffiReady) return;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  _ffiReady = true;
}

var _dbSeq = 0;

/// A clean DbService on its own file — `flutter test` runs suites in
/// parallel isolates, so a shared filename deadlocks. Dispose with
/// [disposeDb] in tearDown.
Future<DbService> freshDb() async {
  initFfi();
  final seq = _dbSeq++;
  final stamp = DateTime.now().microsecondsSinceEpoch;
  return DbService(dbName: 'test_${seq}_$stamp.db');
}

Future<void> disposeDb(DbService db) async {
  final path = await db.databasePath();
  await db.close();
  await deleteDatabase(path);
}

/// Spins until [cond] holds — for assertions behind unawaited futures
/// like AuthService._provision.
Future<void> untilTrue(bool Function() cond, {int tries = 100}) async {
  for (var i = 0; i < tries && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  expect(cond(), isTrue, reason: 'condition not met in time');
}

/// Controllable stand-in — overrides everything that touches the real
/// Supabase client so tests never hit the network.
class FakeSupabaseService extends SupabaseService {
  bool configured = true;
  bool authed = false;
  String? email = 'admin@test.dev';
  String? userId = 'remote-1';
  bool refreshResult = false;

  /// If set, signIn/signUp throw this (e.g. AuthException).
  Object? signInError;
  Object? signUpError;

  /// Number of leading signIn calls that throw [signInError]; -1 = all.
  int signInFails = -1;
  int signInCalls = 0;
  String? signUpResult = 'remote-1';
  bool signUpCreatesSession = false;

  Map<String, Object?>? profile;
  List<Map<String, dynamic>> gesturesToPull = const [];
  List<Map<String, dynamic>> profilesToPull = const [];

  /// If set, pushRow throws after recording the call.
  Object? pushError;
  final pushes = <Map<String, Object?>>[];

  @override
  bool get enabled => configured;
  @override
  bool get isAuthed => authed;
  @override
  String? get currentEmail => email;
  @override
  String? get currentUserId => userId;

  @override
  Future<String?> signUp(String email, String password, String name) async {
    if (signUpError != null) throw signUpError!;
    if (signUpCreatesSession) {
      authed = true;
      this.email = email;
    }
    return signUpResult;
  }

  @override
  Future<void> signIn(String email, String password) async {
    signInCalls++;
    if (signInError != null &&
        (signInFails < 0 || signInCalls <= signInFails)) {
      throw signInError!;
    }
    authed = true;
    this.email = email;
  }

  @override
  Future<String?> provisionIfMissing(
    String email,
    String password,
    String name,
  ) async {
    try {
      return await signUp(email, password, name);
    } catch (e) {
      if (e.toString().toLowerCase().contains('already')) return null;
      rethrow;
    }
  }

  @override
  Future<Map<String, Object?>?> fetchProfile(String email) async => profile;

  @override
  Future<void> updateRemotePassword(String newPassword) async {}

  @override
  Future<void> signOut() async {
    authed = false;
  }

  @override
  Future<bool> refreshSession() async {
    if (refreshResult) authed = true;
    return refreshResult;
  }

  @override
  Future<Map<String, dynamic>?> pushRow(
    String entity,
    String entityKey,
    String op,
    Map<String, dynamic> payload,
  ) async {
    pushes.add({
      'entity': entity,
      'key': entityKey,
      'op': op,
      'payload': payload,
    });
    if (pushError != null) throw pushError!;
    return entity == 'profiles' ? {'id': userId} : null;
  }

  @override
  Future<List<Map<String, dynamic>>> pullGestures() async => gesturesToPull;

  @override
  Future<List<Map<String, dynamic>>> pullProfiles() async => profilesToPull;

  @override
  Stream<List<Map<String, dynamic>>> gesturesStream() =>
      Stream<List<Map<String, dynamic>>>.value(const []);
}
