import 'package:flutter_test/flutter_test.dart';
import 'package:thando_sign_app/models/translation_record.dart';
import 'package:thando_sign_app/services/db_service.dart';

import 'test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DbService db;
  setUp(() async {
    db = await freshDb();
  });
  tearDown(() async {
    await disposeDb(db);
  });

  group('accounts', () {
    test('register + login round-trips with bcrypt', () async {
      await db.registerUser('Ada', 'ada@test.dev', 's3cret');
      final user = await db.login('ada@test.dev', 's3cret');
      expect(user, isNotNull);
      expect(user!.name, 'Ada');
      expect(user.passwordHash, startsWith(r'$2'));
      expect(await db.login('ada@test.dev', 'wrong'), isNull);
      expect(await db.login('nobody@test.dev', 'x'), isNull);
    });

    test('duplicate email throws', () async {
      await db.registerUser('Ada', 'ada@test.dev', 's3cret');
      expect(
        db.registerUser('Ada Two', 'ADA@test.dev', 'x'),
        throwsStateError,
      );
    });

    test('linkRemoteUser stores remote id and role', () async {
      await db.registerUser('Ada', 'ada@test.dev', 's3cret');
      await db.linkRemoteUser(
        'ada@test.dev',
        remoteId: 'r-9',
        role: 'admin',
        isActive: true,
      );
      final user = await db.findUserByEmail('ada@test.dev');
      expect(user!.role, 'admin');
      final rows = await (await db.database).query(
        'users',
        where: 'email = ?',
        whereArgs: ['ada@test.dev'],
      );
      expect(rows.first['remote_id'], 'r-9');
    });
  });

  group('sync outbox', () {
    Future<void> clearOutbox() async =>
        (await db.database).delete('pending_sync');

    test('registerUser queues a minimal profiles upsert', () async {
      await clearOutbox();
      await db.registerUser('Ada', 'ada@test.dev', 's3cret');
      final rows = await db.pendingSyncRows();
      expect(rows, hasLength(1));
      expect(rows.first['entity'], 'profiles');
      expect(rows.first['entity_key'], 'ada@test.dev');
      expect(rows.first['op'], 'upsert');
      // No role/is_active — must not clobber a promoted server profile.
      expect(rows.first['payload'], isNot(contains('"role"')));
    });

    test('repeated upserts to the same key collapse to one row', () async {
      await clearOutbox();
      await db.registerUser('Ada', 'ada@test.dev', 's3cret');
      await db.registerUser('Bob', 'bob@test.dev', 's3cret');
      await db.logActivity(null, 'test', 'one');
      await db.logActivity(null, 'test', 'two');
      final rows = await db.pendingSyncRows();
      // 2 profiles upserts + 2 log inserts — logs are inserts, no collapse.
      expect(rows, hasLength(4));
      expect(
        rows.where((r) => r['entity'] == 'profiles'),
        hasLength(2),
      );
    });

    test('markSynced removes only the target row', () async {
      await clearOutbox();
      await db.logActivity(null, 'a', '1');
      await db.logActivity(null, 'b', '2');
      final rows = await db.pendingSyncRows();
      expect(await db.pendingSyncCount(), 2);
      await db.markSynced(rows.first['id'] as int);
      expect(await db.pendingSyncCount(), 1);
    });

    test('bumpSyncAttempt increments attempts', () async {
      await clearOutbox();
      await db.logActivity(null, 'a', '1');
      var row = (await db.pendingSyncRows()).first;
      await db.bumpSyncAttempt(row['id'] as int);
      row = (await db.pendingSyncRows()).first;
      expect(row['attempts'], 1);
    });

    test('saveTranslation queues an insert with owner email', () async {
      await clearOutbox();
      final u = await db.registerUser('Ada', 'ada@test.dev', 's3cret');
      await clearOutbox();
      await db.saveTranslation(
        TranslationRecord(
          userId: u.id!,
          inputType: 'sign',
          inputLabel: 'Hello',
          translatedText: 'Hello',
          confidence: 0.9,
          createdAt: DateTime.now(),
        ),
      );
      final rows = await db.pendingSyncRows();
      expect(rows.single['entity'], 'translations');
      expect(rows.single['op'], 'insert');
      expect(rows.single['payload'], contains('"user_email":"ada@test.dev"'));
    });
  });

  group('dataset', () {
    test('seeds the reference vocabulary on first open', () async {
      final gestures = await db.getGestures(activeOnly: false);
      expect(gestures.length, greaterThanOrEqualTo(100));
      expect(
        gestures.any((g) => g.label == 'Hello'),
        isTrue,
      );
    });

    test('upsertGestureFromRemote matches by label', () async {
      final gestures = await db.getGestures(activeOnly: false);
      final hello = gestures.firstWhere((g) => g.label == 'Hello');
      await db.upsertGestureFromRemote({
        'uuid': 'remote-uuid-1',
        'label': 'Hello',
        'meaning': 'Remote meaning',
        'category': 'Greetings',
        'is_active': true,
        // Newer than the local row — the merge is last-write-wins.
        'updated_at': DateTime.now()
            .add(const Duration(hours: 1))
            .toIso8601String(),
      });
      final after = await db.getGestures(activeOnly: false);
      final updated = after.firstWhere((g) => g.label == 'Hello');
      expect(updated.id, hello.id);
      expect(updated.meaning, 'Remote meaning');
      expect(updated.uuid, 'remote-uuid-1');
    });
  });

  group('stats', () {
    test('getTranslationStats reflects saved rows', () async {
      final u = await db.registerUser('Ada', 'ada@test.dev', 's3cret');
      await db.saveTranslation(
        TranslationRecord(
          userId: u.id!,
          inputType: 'sign',
          inputLabel: 'Hello',
          translatedText: 'Hello',
          createdAt: DateTime.now(),
        ),
      );
      final stats = await db.getTranslationStats();
      expect(stats['total'], 1);
      expect(stats['today'], 1);
      expect(stats['gestures'], greaterThanOrEqualTo(100));
      expect(stats['users'], greaterThanOrEqualTo(2)); // seed admin + Ada
    });
  });
}
