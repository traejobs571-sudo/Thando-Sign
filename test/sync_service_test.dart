import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:thando_sign_app/models/translation_record.dart';
import 'package:thando_sign_app/services/auth_service.dart';
import 'package:thando_sign_app/services/connectivity_service.dart';
import 'package:thando_sign_app/services/db_service.dart';
import 'package:thando_sign_app/services/settings_service.dart';
import 'package:thando_sign_app/services/sync_service.dart';

import 'test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DbService db;
  late FakeSupabaseService supa;
  late ConnectivityService conn;
  late AppSettings settings;
  late SyncService sync;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = await freshDb();
    supa = FakeSupabaseService();
    conn = ConnectivityService.testing(online: true);
    settings = AppSettings();
    await settings.init();
    sync = SyncService(
      db: db,
      supabase: supa,
      connectivity: conn,
      settings: settings,
    );
  });
  tearDown(() async {
    sync.dispose();
    settings.dispose();
    conn.dispose();
    await disposeDb(db);
  });

  Future<void> clearOutbox() async =>
      (await db.database).delete('pending_sync');

  group('blocker', () {
    test('names each unmet precondition in order', () async {
      supa.configured = false;
      expect(sync.blocker, contains('not configured'));

      supa.configured = true;
      await settings.setCloudSyncEnabled(false);
      expect(sync.blocker, contains('Cloud sync is off'));

      await settings.setCloudSyncEnabled(true);
      conn.setOnline(false);
      expect(sync.blocker, contains('No network'));

      conn.setOnline(true); // kicks a background syncNow — let it settle
      expect(sync.blocker, contains('No cloud session'));
      await untilTrue(() => !sync.syncing);

      supa.authed = true;
      expect(sync.blocker, isNull);
    });
  });

  group('syncNow', () {
    test('records the blocker as lastError when blocked', () async {
      await clearOutbox();
      await sync.syncNow();
      expect(sync.lastError, contains('No cloud session'));
      expect(supa.pushes, isEmpty);
    });

    test('a stored refresh token can restore the session', () async {
      supa.refreshResult = true;
      await clearOutbox();
      await sync.syncNow();
      expect(supa.isAuthed, isTrue);
      expect(sync.lastError, isNull);
    });

    test('flushes the outbox in order when authed', () async {
      supa.authed = true;
      await clearOutbox();
      await db.logActivity(null, 'test', 'one');
      await db.logActivity(null, 'test', 'two');
      await sync.syncNow();
      expect(supa.pushes, hasLength(2));
      expect(
        supa.pushes.every((p) => p['entity'] == 'system_logs'),
        isTrue,
      );
      expect(await db.pendingSyncCount(), 0);
      expect(sync.lastError, isNull);
      expect(sync.lastSyncAt, isNotNull);
    });

    test(
      'translations owned by another account wait for that sign-in',
      () async {
        supa
          ..authed = true
          ..email = 'me@test.dev';
        final other = await db.registerUser(
          'Other',
          'other@test.dev',
          'pw12345',
        );
        await clearOutbox();
        await db.saveTranslation(
          TranslationRecord(
            userId: other.id!,
            inputType: 'sign',
            inputLabel: 'Hello',
            translatedText: 'Hello',
            createdAt: DateTime.now(),
          ),
        );
        await sync.syncNow();
        expect(await db.pendingSyncCount(), 1);
        expect(supa.pushes, isEmpty);
      },
    );

    test('push failure bumps attempts and surfaces the error', () async {
      supa
        ..authed = true
        ..pushError = Exception('boom');
      await clearOutbox();
      await db.logActivity(null, 'test', 'one');
      await sync.syncNow();
      expect(await db.pendingSyncCount(), 1);
      expect(sync.lastError, contains('boom'));
      expect((await db.pendingSyncRows()).first['attempts'], 1);
    });

    test('a row is dropped after max attempts and a drop log queued',
        () async {
      supa
        ..authed = true
        ..pushError = Exception('boom');
      await clearOutbox();
      await db.logActivity(null, 'test', 'one');
      for (var i = 0; i < 5; i++) {
        await sync.syncNow();
      }
      // Original row is gone; the sync_drop audit row is queued instead.
      final rows = await db.pendingSyncRows();
      expect(rows.single['entity'], 'system_logs');
      expect(rows.single['payload'], contains('Dropped'));
    });

    test('remote gesture pulls upsert into the local dataset', () async {
      supa
        ..authed = true
        ..gesturesToPull = [
          {
            'uuid': 'remote-new-1',
            'label': 'New Remote Sign',
            'meaning': 'Pushed down from the cloud',
            'category': 'Custom',
            'is_active': true,
          },
        ];
      await clearOutbox();
      await sync.syncNow();
      final gestures = await db.getGestures(activeOnly: false);
      expect(
        gestures.any((g) => g.label == 'New Remote Sign'),
        isTrue,
      );
    });

    test('a pull with case-variant labels dedupes to one row', () async {
      supa
        ..authed = true
        ..gesturesToPull = [
          {
            'uuid': 'remote-a',
            'label': 'Father',
            'meaning': 'Father',
            'category': 'Social',
            'is_active': true,
            'updated_at': '2030-01-01T00:00:00',
          },
          {
            'uuid': 'remote-b',
            'label': 'father',
            'meaning': 'variant',
            'category': 'Social',
            'is_active': false,
            'updated_at': '2030-01-02T00:00:00',
          },
        ];
      await clearOutbox();
      await sync.syncNow();
      final rows = await (await db.database).query(
        'gestures',
        where: "LOWER(label) = 'father'",
      );
      expect(rows, hasLength(1));
    });

    test('a remote-only profile materializes on pull', () async {
      supa
        ..authed = true
        ..profilesToPull = [
          {
            'id': 'r-ghost',
            'email': 'ghost@x.dev',
            'name': 'Ghost User',
            'role': 'user',
            'is_active': true,
          },
        ];
      await clearOutbox();
      await sync.syncNow();
      final user = await db.findUserByEmail('ghost@x.dev');
      expect(user, isNotNull);
      expect(user!.name, 'Ghost User');
      expect(user.passwordHash, DbService.remoteOnlyPasswordHash);
    });
  });

  group('attachAuth', () {
    test('a sign-in notification kicks a sync', () async {
      supa.authed = true;
      final auth = AuthService(db, supa, conn);
      sync.attachAuth(auth);
      await clearOutbox();
      await db.logActivity(null, 'test', 'queued before login');
      await auth.login('login@test.dev', 'pw12345');
      await untilTrue(
        () =>
            supa.pushes.any((p) => p['entity'] == 'system_logs') &&
            !sync.syncing,
      );
      auth.dispose();
    });
  });
}
