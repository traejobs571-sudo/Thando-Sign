import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:thando_sign_app/services/db_service.dart';

import 'test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DbService db;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = await freshDb();
  });
  tearDown(() async {
    await disposeDb(db);
  });

  Future<List<Map<String, Object?>>> rowsForLabel(String label) async =>
      (await db.database).query(
        'gestures',
        where: 'LOWER(label) = LOWER(?)',
        whereArgs: [label],
      );

  Future<void> clearOutbox() async =>
      (await db.database).delete('pending_sync');

  group('remote profile materialization', () {
    test('a remote-only user gets a local stub row', () async {
      await db.upsertProfileFromRemote({
        'email': 'new@x.dev',
        'id': 'remote-1',
        'name': 'New User',
        'role': 'admin',
        'is_active': true,
      });
      final user = await db.findUserByEmail('new@x.dev');
      expect(user, isNotNull);
      expect(user!.name, 'New User');
      expect(user.role, 'admin');
      expect(user.passwordHash, DbService.remoteOnlyPasswordHash);
    });

    test('a stub user cannot sign in offline', () async {
      await db.upsertProfileFromRemote({
        'email': 'new@x.dev',
        'id': 'remote-1',
        'name': 'New User',
      });
      expect(await db.login('new@x.dev', 'anything'), isNull);
    });

    test('an existing local user is updated, not duplicated', () async {
      await db.registerUser('Ada', 'ada@x.dev', 'pw12345');
      await db.upsertProfileFromRemote({
        'email': 'ada@x.dev',
        'id': 'remote-9',
        'name': 'Ada Renamed',
        'role': 'admin',
        'is_active': true,
      });
      final users = await db.getUsers();
      expect(users.where((u) => u.email == 'ada@x.dev'), hasLength(1));
      final user = await db.findUserByEmail('ada@x.dev');
      expect(user!.role, 'admin');
      expect(user.name, 'Ada Renamed');
    });

    test('the seeded admin queues its profile for upload', () async {
      final rows = await db.pendingSyncRows();
      expect(
        rows.any(
          (r) =>
              r['entity'] == 'profiles' &&
              r['entity_key'] == 'ngwenyathando@gmail.com',
        ),
        isTrue,
      );
    });
  });

  group('gesture dedupe', () {
    test('a remote case-variant pair collapses to one row', () async {
      await db.applyRemoteGestures([
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
      ]);
      expect(await rowsForLabel('father'), hasLength(1));
    });

    test('reopening merges pre-existing case-variant duplicates', () async {
      final direct = await db.database;
      // Simulate a pre-index database: drop the NOCASE unique index so a
      // legacy duplicate row can exist, then let onOpen rebuild it.
      await direct.execute(
        'DROP INDEX IF EXISTS gestures_label_nocase',
      );
      await direct.insert('gestures', {
        'uuid': 'dup-uuid-1',
        'label': 'father',
        'meaning': 'variant',
        'category': 'Social',
        'image_url': '',
        'is_active': 1,
        'created_at': '2020-01-01T00:00:00',
      });
      expect(await rowsForLabel('father'), hasLength(2));

      // Reopen the same file — onOpen dedupe + seed must leave exactly
      // one row for the label family and queue cleanup ops.
      final path = p.basename(await db.databasePath());
      await db.close();
      db = DbService(dbName: path);
      await db.database;

      expect(await rowsForLabel('father'), hasLength(1));
      final pending = await db.pendingSyncRows();
      expect(
        pending.any(
          (r) => r['entity'] == 'gestures' && r['entity_key'] == 'dup-uuid-1',
        ),
        isTrue,
      );
    });

    test('a pending local edit survives a newer remote snapshot', () async {
      final hello = (await rowsForLabel('Hello')).first;
      await db.updateGestureStatus(hello['id'] as int, false);

      // Remote says active with a much newer timestamp (clock skew) —
      // the queued local edit must still win.
      await db.upsertGestureFromRemote({
        'uuid': 'remote-x',
        'label': 'Hello',
        'meaning': 'x',
        'category': 'x',
        'is_active': true,
        'updated_at': '2099-01-01T00:00:00',
      });
      var rows = await rowsForLabel('Hello');
      expect(rows.single['is_active'], 0);

      // Once the outbox is flushed, the next snapshot applies normally.
      await clearOutbox();
      await db.upsertGestureFromRemote({
        'uuid': 'remote-x',
        'label': 'Hello',
        'meaning': 'x',
        'category': 'x',
        'is_active': true,
        'updated_at': '2099-01-01T00:00:00',
      });
      rows = await rowsForLabel('Hello');
      expect(rows.single['is_active'], 1);
      expect(rows.single['uuid'], 'remote-x');
    });

    test('local rows absent upstream are removed unless queued', () async {
      await clearOutbox();
      final custom = await db.addGesture('Custom Sign', 'mine', 'Custom');
      final customs = (await rowsForLabel('Custom Sign')).first;
      final keepUuid = customs['uuid'] as String;

      // Not in the remote set, but still queued → must survive.
      await db.applyRemoteGestures([
        {
          'uuid': 'remote-1',
          'label': 'Brand New',
          'meaning': 'x',
          'category': 'x',
          'is_active': true,
          'updated_at': '2030-01-01T00:00:00',
        },
      ]);
      expect((await rowsForLabel('Custom Sign')).single['uuid'], keepUuid);

      // After the push clears, it becomes eligible for upstream deletes.
      await clearOutbox();
      await db.applyRemoteGestures([
        {
          'uuid': 'remote-1',
          'label': 'Brand New',
          'meaning': 'x',
          'category': 'x',
          'is_active': true,
          'updated_at': '2030-01-01T00:00:00',
        },
      ]);
      expect(await rowsForLabel('Custom Sign'), isEmpty);
      expect(custom, isNonZero);
    });
  });
}
