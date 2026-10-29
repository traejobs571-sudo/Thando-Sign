import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import 'package:thando_sign_app/services/auth_service.dart';
import 'package:thando_sign_app/services/connectivity_service.dart';
import 'package:thando_sign_app/services/db_service.dart';

import 'test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DbService db;
  late FakeSupabaseService supa;
  late ConnectivityService conn;
  late AuthService auth;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = await freshDb();
    supa = FakeSupabaseService();
    conn = ConnectivityService.testing(online: true);
    auth = AuthService(db, supa, conn);
  });
  tearDown(() async {
    await disposeDb(db);
    conn.dispose();
    auth.dispose();
  });

  test('offline login uses the local account only', () async {
    conn.setOnline(false);
    await db.registerUser('Ada', 'ada@test.dev', 's3cret');
    final u = await auth.login('ada@test.dev', 's3cret');
    expect(u.email, 'ada@test.dev');
    expect(supa.isAuthed, isFalse);
    expect(auth.currentUser?.email, 'ada@test.dev');
  });

  test('bad password is rejected locally and remotely', () async {
    await db.registerUser('Ada', 'ada@test.dev', 's3cret');
    supa.signInError = AuthException(
      'Invalid login credentials',
      statusCode: '400',
    );
    expect(auth.login('ada@test.dev', 'nope'), throwsStateError);
    expect(auth.login('ghost@test.dev', 'x'), throwsStateError);
  });

  test('cloud sign-in mirrors the account with its remote role', () async {
    supa.profile = {
      'id': 'remote-1',
      'name': 'Boss One',
      'role': 'admin',
      'is_active': true,
    };
    final u = await auth.login('boss@test.dev', 'pw12345');
    expect(supa.isAuthed, isTrue);
    expect(u.role, 'admin');
    expect(auth.isAdmin, isTrue);
    // Mirrored locally for offline logins.
    final local = await db.findUserByEmail('boss@test.dev');
    expect(local?.name, 'Boss One');
  });

  test('deactivated remote profile is rejected and signs out', () async {
    supa.profile = {'id': 'r', 'name': 'X', 'role': 'user', 'is_active': false};
    expect(auth.login('off@test.dev', 'pw12345'), throwsStateError);
    await untilTrue(() => supa.isAuthed == false);
  });

  test(
    'local-only admin provisions a cloud account in the background',
    () async {
      await db.registerUser('Ada', 'ada@test.dev', 's3cret', role: 'admin');
      // First sign-in attempt fails → local login → provision kicks in.
      supa
        ..signInError = AuthException(
          'Invalid login credentials',
          statusCode: '400',
        )
        ..signInFails = 1;
      await auth.login('ada@test.dev', 's3cret');
      await untilTrue(() => supa.isAuthed);
      expect(auth.provisionError, isNull);
      // Admin role pushed to profiles so RLS admin ops pass.
      await untilTrue(() => supa.pushes.isNotEmpty);
      expect(supa.pushes.last['entity'], 'profiles');
      expect(supa.pushes.last['payload'], containsPair('role', 'admin'));
    },
  );

  test(
    'already-registered cloud email falls back to plain sign-in',
    () async {
      await db.registerUser('Ada', 'ada@test.dev', 's3cret');
      supa
        ..signUpError = AuthException(
          'User already registered',
          statusCode: '400',
        )
        ..signInError = AuthException(
          'Invalid login credentials',
          statusCode: '400',
        )
        ..signInFails = 1;
      await auth.login('ada@test.dev', 's3cret');
      await untilTrue(() => supa.isAuthed);
      expect(auth.provisionError, isNull);
    },
  );

  test(
    'email-confirmation projects surface a provision error',
    () async {
      await db.registerUser('Ada', 'ada@test.dev', 's3cret');
      supa.signInError = AuthException(
        'Email not confirmed',
        statusCode: '400',
      );
      await auth.login('ada@test.dev', 's3cret');
      // Still locally signed in — the user isn't locked out.
      expect(auth.currentUser?.email, 'ada@test.dev');
      await untilTrue(() => auth.provisionError != null);
      expect(auth.provisionError, contains('confirmation'));
      expect(supa.isAuthed, isFalse);
    },
  );
}
