import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:dbcrypt/dbcrypt.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import '../ml/hand_sign_classifier.dart';
import '../models/user.dart';
import '../models/translation_record.dart';
import '../models/gesture_item.dart';

class DbService {
  /// Default is the production file; tests pass unique names since
  /// `flutter test` runs suites in parallel isolates on one filesystem.
  DbService({this._dbName = 'thando_sign.db'});

  final String _dbName;
  static const _dbVersion = 5;
  static const _uuid = Uuid();

  final _bcrypt = DBCrypt();
  Database? _db;

  /// Serializes every read-check-write on `gestures` — seeding, remote
  /// upserts, reconcile deletes, resets and UI edits all pass through it,
  /// so two overlapping passes can't double-insert the same label.
  /// Reentrant: callers may nest (e.g. reset → seed) without deadlocking.
  final _gestureLock = Lock(reentrant: true);

  /// Stored as `password_hash` for profiles pulled from Supabase that
  /// never existed locally — the account shows in Users and can be
  /// (de)activated, but gets a real hash only on its first cloud sign-in.
  static const remoteOnlyPasswordHash = '!remote-only';

  Future<Database> get database async {
    _db ??= await _initDB();
    return _db!;
  }

  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, _dbName);

    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            uuid TEXT,
            remote_id TEXT,
            name TEXT NOT NULL,
            email TEXT NOT NULL UNIQUE,
            password_hash TEXT NOT NULL,
            role TEXT NOT NULL DEFAULT 'user',
            is_active INTEGER NOT NULL DEFAULT 1,
            must_change_password INTEGER NOT NULL DEFAULT 0,
            reset_code TEXT,
            reset_expires TEXT,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE gestures (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            uuid TEXT,
            label TEXT NOT NULL,
            meaning TEXT NOT NULL,
            category TEXT NOT NULL,
            image_url TEXT NOT NULL DEFAULT '',
            is_active INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL,
            updated_at TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE translations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            uuid TEXT,
            user_id INTEGER NOT NULL,
            input_type TEXT NOT NULL,
            input_label TEXT NOT NULL,
            translated_text TEXT NOT NULL,
            confidence REAL NOT NULL DEFAULT 0.0,
            source TEXT NOT NULL DEFAULT 'gemini',
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE system_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            uuid TEXT,
            user_id INTEGER,
            action TEXT NOT NULL,
            details TEXT NOT NULL,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE gesture_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            uuid TEXT,
            label TEXT NOT NULL,
            landmarks TEXT NOT NULL,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE pending_sync (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            entity TEXT NOT NULL,
            entity_key TEXT NOT NULL,
            op TEXT NOT NULL,
            payload TEXT NOT NULL,
            created_at TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0
          )
        ''');

        await _seedData(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE users ADD COLUMN is_active INTEGER NOT NULL DEFAULT 1',
          );
          await db.execute(
            'ALTER TABLE users ADD COLUMN must_change_password INTEGER NOT NULL DEFAULT 0',
          );
          // Force existing admin accounts to rotate the shipped password.
          await db.update(
            'users',
            {'must_change_password': 1},
            where: 'role = ?',
            whereArgs: ['admin'],
          );
        }
        if (oldVersion < 3) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS gesture_samples (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              label TEXT NOT NULL,
              landmarks TEXT NOT NULL,
              created_at TEXT NOT NULL
            )
          ''');
        }
        if (oldVersion < 4) {
          await db.execute('ALTER TABLE users ADD COLUMN reset_code TEXT');
          await db.execute('ALTER TABLE users ADD COLUMN reset_expires TEXT');
        }
        if (oldVersion < 5) {
          await db.execute('ALTER TABLE users ADD COLUMN uuid TEXT');
          await db.execute('ALTER TABLE users ADD COLUMN remote_id TEXT');
          await db.execute('ALTER TABLE gestures ADD COLUMN uuid TEXT');
          await db.execute('ALTER TABLE gestures ADD COLUMN updated_at TEXT');
          await db.execute('ALTER TABLE translations ADD COLUMN uuid TEXT');
          await db.execute('ALTER TABLE system_logs ADD COLUMN uuid TEXT');
          await db.execute('ALTER TABLE gesture_samples ADD COLUMN uuid TEXT');
          await db.execute('''
            CREATE TABLE IF NOT EXISTS pending_sync (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              entity TEXT NOT NULL,
              entity_key TEXT NOT NULL,
              op TEXT NOT NULL,
              payload TEXT NOT NULL,
              created_at TEXT NOT NULL,
              attempts INTEGER NOT NULL DEFAULT 0
            )
          ''');
        }
      },
      onOpen: (db) async {
        await _ensureColumn(
          db,
          'gestures',
          'image_url',
          "ALTER TABLE gestures ADD COLUMN image_url TEXT NOT NULL DEFAULT ''",
        );
        await _backfillUuids(db);
        await _dedupeGestureLabels(db);
        try {
          await db.execute('''
            CREATE UNIQUE INDEX IF NOT EXISTS gestures_label_nocase
            ON gestures(label COLLATE NOCASE)
          ''');
        } catch (_) {
          // Index creation must never block startup — a failed index only
          // means the app-level dedupe above keeps doing the work.
        }
        await _seedAdminIfMissing(db);
        await _seedGestures(db);
        await _seedLetterSamples(db);
      },
    );
  }

  Future<void> _seedData(Database db) async {
    await _seedAdminIfMissing(db);
    await _seedGestures(db);
    await _seedLetterSamples(db);
  }

  /// Fills in `uuid` for rows written before sync support existed so the
  /// outbox has a stable key to push under.
  Future<void> _backfillUuids(Database db) async {
    for (final table in [
      'users',
      'gestures',
      'translations',
      'system_logs',
      'gesture_samples',
    ]) {
      final rows = await db.query(
        table,
        columns: ['id'],
        where: 'uuid IS NULL',
      );
      for (final r in rows) {
        await db.update(
          table,
          {'uuid': _uuid.v4()},
          where: 'id = ?',
          whereArgs: [r['id']],
        );
      }
    }
  }

  /// Merges gesture rows sharing a label (case-insensitive) into one.
  /// Older builds could double-insert when a remote case-variant existed
  /// or when concurrent pull/seed passes raced a second row in — this
  /// repairs the damage on open and after each remote reconcile. The
  /// survivor prefers a row a pending outbox op points at, then one with
  /// an image, then the most recently updated; loser uuids get remote
  /// 'delete' ops so the server converges too.
  Future<void> _dedupeGestureLabels(Database db) async {
    final rows = await db.query('gestures');
    final byLabel = <String, List<Map<String, Object?>>>{};
    for (final r in rows) {
      final key = (r['label'] as String).trim().toLowerCase();
      byLabel.putIfAbsent(key, () => []).add(r);
    }
    if (!byLabel.values.any((g) => g.length > 1)) return;

    final pending = await db.query(
      'pending_sync',
      columns: ['entity_key'],
      where: 'entity = ?',
      whereArgs: ['gestures'],
    );
    final pendingKeys = pending
        .map((r) => r['entity_key'] as String)
        .toSet();

    for (final group in byLabel.values) {
      if (group.length < 2) continue;
      group.sort((a, b) {
        int score(Map<String, Object?> r) {
          var s = 0;
          if (pendingKeys.contains(r['uuid'])) s += 100;
          if (((r['image_url'] as String?) ?? '').isNotEmpty) s += 10;
          return s;
        }

        final c = score(b).compareTo(score(a));
        if (c != 0) return c;
        final ua =
            (a['updated_at'] as String?) ??
            (a['created_at'] as String?) ??
            '';
        final ub =
            (b['updated_at'] as String?) ??
            (b['created_at'] as String?) ??
            '';
        final t = ub.compareTo(ua);
        if (t != 0) return t;
        return (a['id'] as int).compareTo(b['id'] as int);
      });

      final winner = group.first;
      var imageUrl = (winner['image_url'] as String?) ?? '';
      for (final loser in group.skip(1)) {
        if (imageUrl.isEmpty) {
          imageUrl = (loser['image_url'] as String?) ?? imageUrl;
        }
        await _removeGestureDuplicate(db, loser);
      }
      if (imageUrl.isNotEmpty && imageUrl != winner['image_url']) {
        await db.update(
          'gestures',
          {'image_url': imageUrl},
          where: 'id = ?',
          whereArgs: [winner['id']],
        );
      }
    }
  }

  /// Deletes one duplicate gesture row: drops its queued writes so they
  /// can't resurrect it, then queues a remote delete for convergence.
  Future<void> _removeGestureDuplicate(
    Database db,
    Map<String, Object?> row,
  ) async {
    await db.delete('gestures', where: 'id = ?', whereArgs: [row['id']]);
    final uuid = row['uuid'] as String?;
    if (uuid == null) return;
    await db.delete(
      'pending_sync',
      where: 'entity = ? AND entity_key = ?',
      whereArgs: ['gestures', uuid],
    );
    await _enqueueIn(db, 'gestures', uuid, 'delete', {'uuid': uuid});
  }

  // ----------------------------------------------------------- sync outbox

  /// Queues a mutation for upload. [entity] matches a Supabase table
  /// ('profiles', 'gestures', 'translations', 'system_logs',
  /// 'gesture_samples'); [op] is 'upsert', 'insert', 'delete' or 'clear'.
  Future<void> _enqueue(
    String entity,
    String entityKey,
    String op,
    Map<String, Object?> payload,
  ) async =>
      _enqueueIn(await database, entity, entityKey, op, payload);

  /// Same as [_enqueue] but on an explicit handle — required inside
  /// [openDatabase] callbacks where `database` isn't assigned yet.
  Future<void> _enqueueIn(
    Database db,
    String entity,
    String entityKey,
    String op,
    Map<String, Object?> payload,
  ) async {
    // Repeated upserts to the same row collapse — only the newest payload
    // needs uploading.
    if (op == 'upsert') {
      await db.delete(
        'pending_sync',
        where: 'entity = ? AND entity_key = ? AND op = ?',
        whereArgs: [entity, entityKey, op],
      );
    }
    await db.insert('pending_sync', {
      'entity': entity,
      'entity_key': entityKey,
      'op': op,
      'payload': jsonEncode(payload),
      'created_at': DateTime.now().toIso8601String(),
      'attempts': 0,
    });
  }

  /// Re-reads a gesture row and queues the full upsert — payloads always
  /// carry complete state so the server copy can't drift from local edits.
  Future<void> _enqueueGesture(int id) async {
    final db = await database;
    final rows = await db.query('gestures', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return;
    final r = rows.first;
    await _enqueue('gestures', r['uuid'] as String, 'upsert', {
      'uuid': r['uuid'],
      'label': r['label'],
      'meaning': r['meaning'],
      'category': r['category'],
      'image_url': r['image_url'] ?? '',
      'is_active': (r['is_active'] as int? ?? 1) == 1,
      'updated_at': r['updated_at'],
    });
  }

  Future<void> _enqueueUser(int id) async {
    final db = await database;
    final rows = await db.query('users', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return;
    final r = rows.first;
    await _enqueue('profiles', r['email'] as String, 'upsert', {
      'email': r['email'],
      'name': r['name'],
      'role': r['role'],
      'is_active': (r['is_active'] as int? ?? 1) == 1,
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, Object?>>> pendingSyncRows({int limit = 200}) async {
    final db = await database;
    return db.query('pending_sync', orderBy: 'id ASC', limit: limit);
  }

  Future<int> pendingSyncCount() async {
    final db = await database;
    return Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM pending_sync'),
        ) ??
        0;
  }

  Future<void> markSynced(int id) async {
    final db = await database;
    await db.delete('pending_sync', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> bumpSyncAttempt(int id) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE pending_sync SET attempts = attempts + 1 WHERE id = ?',
      [id],
    );
  }

  // ---------------------------------------------------- gesture samples

  /// Stores a normalized 21×3 landmark vector recorded for [label].
  /// These samples train the on-device k-NN recogniser.
  Future<void> saveGestureSample(String label, List<double> landmarks) async {
    final db = await database;
    final row = {
      'uuid': _uuid.v4(),
      'label': label,
      'landmarks': jsonEncode(landmarks),
      'created_at': DateTime.now().toIso8601String(),
    };
    await db.insert('gesture_samples', row);
    await _enqueue('gesture_samples', row['uuid'] as String, 'insert', {
      'uuid': row['uuid'],
      'label': label,
      'landmarks': landmarks,
      'created_at': row['created_at'],
    });
  }

  /// All recorded samples grouped by gesture label, normalized for the
  /// k-NN recogniser. Seeded reference data is stored RAW (so tiles can
  /// draw the real skeleton), while captured samples are already
  /// normalized — [HandSignClassifier.normalizeLandmarks] is idempotent,
  /// so normalizing here repairs the seeded vectors without touching
  /// captured ones.
  Future<Map<String, List<List<double>>>> getGestureSamples() async {
    final db = await database;
    final rows = await db.query('gesture_samples');
    final out = <String, List<List<double>>>{};
    for (final r in rows) {
      final label = r['label'] as String;
      final raw = (jsonDecode(r['landmarks'] as String) as List)
          .map((e) => (e as num).toDouble())
          .toList();
      out
          .putIfAbsent(label, () => [])
          .add(HandSignClassifier.normalizeLandmarks(raw));
    }
    return out;
  }

  /// One recorded landmark vector (63 floats) for [label], if training
  /// samples exist — lets the UI draw the hand skeleton for a sign when
  /// no illustration is available (fully offline).
  Future<List<double>?> getSampleLandmarks(String label) async {
    final db = await database;
    final rows = await db.query(
      'gesture_samples',
      columns: ['landmarks'],
      where: 'label = ?',
      whereArgs: [label],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (jsonDecode(rows.first['landmarks'] as String) as List)
        .map((e) => (e as num).toDouble())
        .toList();
  }

  Future<int> getSampleCount(String label) async {
    final db = await database;
    return Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM gesture_samples WHERE label = ?',
            [label],
          ),
        ) ??
        0;
  }

  /// Idempotent column add — safer than a version bump for columns that
  /// may or may not exist on long-lived device databases.
  Future<void> _ensureColumn(
    Database db,
    String table,
    String column,
    String ddl,
  ) async {
    final cols = await db.rawQuery('PRAGMA table_info($table)');
    if (!cols.any((c) => c['name'] == column)) {
      await db.execute(ddl);
    }
  }

  Future<void> _seedAdminIfMissing(Database db) async {
    final existing = await db.query(
      'users',
      where: 'email = ?',
      whereArgs: ['ngwenyathando@gmail.com'],
    );
    if (existing.isEmpty) {
      await db.insert('users', {
        'uuid': _uuid.v4(),
        'name': 'Thando Ngwenya',
        'email': 'ngwenyathando@gmail.com',
        'password_hash': _hashPassword('Admin123'),
        'role': 'admin',
        'is_active': 1,
        'must_change_password': 0,
        'created_at': DateTime.now().toIso8601String(),
      });
      // Queue the admin profile for upload — the server-side is_admin()
      // gate needs this row before any dataset write passes RLS.
      await _enqueueIn(db, 'profiles', 'ngwenyathando@gmail.com', 'upsert', {
        'email': 'ngwenyathando@gmail.com',
        'name': 'Thando Ngwenya',
        'role': 'admin',
        'is_active': true,
        'updated_at': DateTime.now().toIso8601String(),
      });
    }
  }

  /// Curated ZSL / International-sign reference vocabulary.
  /// Gemini is constrained to these labels so recognition stays consistent.
  /// Runs on every open — inserts any labels that are missing so existing
  /// installs pick up vocabulary additions while keeping admin edits.
  Future<void> _seedGestures(Database db) async {
    final rows = await db.query('gestures', columns: ['label']);
    // Case-insensitive: a pulled 'father' row must stop a 'Father' seed —
    // the unique index and every other dedupe path agree on this.
    final existing = rows
        .map((r) => (r['label'] as String).toLowerCase())
        .toSet();

    const defaults = [
      // Fingerspelling
      ('Letter A', 'Fingerspell the letter A', 'Alphabet'),
      ('Letter B', 'Fingerspell the letter B', 'Alphabet'),
      ('Letter C', 'Fingerspell the letter C', 'Alphabet'),
      ('Letter D', 'Fingerspell the letter D', 'Alphabet'),
      ('Letter E', 'Fingerspell the letter E', 'Alphabet'),
      ('Letter F', 'Fingerspell the letter F', 'Alphabet'),
      ('Letter G', 'Fingerspell the letter G', 'Alphabet'),
      ('Letter H', 'Fingerspell the letter H', 'Alphabet'),
      ('Letter I', 'Fingerspell the letter I', 'Alphabet'),
      ('Letter J', 'Fingerspell the letter J', 'Alphabet'),
      ('Letter K', 'Fingerspell the letter K', 'Alphabet'),
      ('Letter L', 'Fingerspell the letter L', 'Alphabet'),
      ('Letter M', 'Fingerspell the letter M', 'Alphabet'),
      ('Letter N', 'Fingerspell the letter N', 'Alphabet'),
      ('Letter O', 'Fingerspell the letter O', 'Alphabet'),
      ('Letter P', 'Fingerspell the letter P', 'Alphabet'),
      ('Letter Q', 'Fingerspell the letter Q', 'Alphabet'),
      ('Letter R', 'Fingerspell the letter R', 'Alphabet'),
      ('Letter S', 'Fingerspell the letter S', 'Alphabet'),
      ('Letter T', 'Fingerspell the letter T', 'Alphabet'),
      ('Letter U', 'Fingerspell the letter U', 'Alphabet'),
      ('Letter V', 'Fingerspell the letter V', 'Alphabet'),
      ('Letter W', 'Fingerspell the letter W', 'Alphabet'),
      ('Letter X', 'Fingerspell the letter X', 'Alphabet'),
      ('Letter Y', 'Fingerspell the letter Y', 'Alphabet'),
      ('Letter Z', 'Fingerspell the letter Z', 'Alphabet'),
      // Greetings & responses
      ('Hello', 'A friendly greeting', 'Greetings'),
      ('Goodbye', 'Farewell sign', 'Greetings'),
      ('Thank You', 'Expression of gratitude', 'Greetings'),
      ('Please', 'Polite request', 'Greetings'),
      ('Welcome', 'Welcoming a person', 'Greetings'),
      ('Good Morning', 'Morning greeting', 'Greetings'),
      ('Good Afternoon', 'Afternoon greeting', 'Greetings'),
      ('Good Evening', 'Evening greeting', 'Greetings'),
      ('Excuse Me', 'Getting attention politely', 'Greetings'),
      ('See You Later', 'Parting phrase', 'Greetings'),
      ('Welcome Back', 'Greeting a return', 'Greetings'),
      ('God Bless You', 'Blessing', 'Greetings'),
      ('Yes', 'Affirmative response', 'Responses'),
      ('No', 'Negative response', 'Responses'),
      ('Good', 'Positive affirmation', 'Responses'),
      ('Bad', 'Negative affirmation', 'Responses'),
      ('Sorry', 'Apology expression', 'Responses'),
      ('Fine', 'I am okay', 'Responses'),
      ('Maybe', 'Uncertainty', 'Responses'),
      ('Okay', 'Agreement', 'Responses'),
      ('Understand', 'I understand', 'Responses'),
      ('I Do Not Understand', 'Confusion or need to repeat', 'Responses'),
      // Common phrases
      ('How Are You', 'Asking about wellbeing', 'Phrases'),
      ('I Am Fine', 'Responding that you are well', 'Phrases'),
      ('What Is Your Name', 'Asking a name', 'Phrases'),
      ('My Name Is', 'Stating your name', 'Phrases'),
      ('I Love You', 'ILY handshape expression', 'Phrases'),
      ('How Much', 'Asking the price', 'Phrases'),
      ('I Need Help', 'Requesting assistance', 'Phrases'),
      // Questions
      ('Name', 'Asking for or stating a name', 'Questions'),
      ('Where', 'Asking for a location', 'Questions'),
      ('What', 'Asking for information', 'Questions'),
      ('Who', 'Asking about a person', 'Questions'),
      ('When', 'Asking about time', 'Questions'),
      ('Why', 'Asking for a reason', 'Questions'),
      ('How', 'Asking about manner', 'Questions'),
      // Numbers
      ('Zero', 'The number 0', 'Numbers'),
      ('One', 'The number 1', 'Numbers'),
      ('Two', 'The number 2', 'Numbers'),
      ('Three', 'The number 3', 'Numbers'),
      ('Four', 'The number 4', 'Numbers'),
      ('Five', 'The number 5', 'Numbers'),
      ('Six', 'The number 6', 'Numbers'),
      ('Seven', 'The number 7', 'Numbers'),
      ('Eight', 'The number 8', 'Numbers'),
      ('Nine', 'The number 9', 'Numbers'),
      ('Ten', 'The number 10', 'Numbers'),
      // Time & days
      ('Today', 'This day', 'Time'),
      ('Tomorrow', 'The next day', 'Time'),
      ('Yesterday', 'The day before', 'Time'),
      ('Morning', 'Early part of the day', 'Time'),
      ('Afternoon', 'Middle part of the day', 'Time'),
      ('Evening', 'Later part of the day', 'Time'),
      ('Night', 'Night time', 'Time'),
      ('Week', 'A week', 'Time'),
      ('Month', 'A month', 'Time'),
      ('Year', 'A year', 'Time'),
      ('Monday', 'Day of the week', 'Days'),
      ('Tuesday', 'Day of the week', 'Days'),
      ('Wednesday', 'Day of the week', 'Days'),
      ('Thursday', 'Day of the week', 'Days'),
      ('Friday', 'Day of the week', 'Days'),
      ('Saturday', 'Day of the week', 'Days'),
      ('Sunday', 'Day of the week', 'Days'),
      // Daily life
      ('Help', 'Request for assistance', 'Emergency'),
      ('Water', 'Request for water', 'Daily Life'),
      ('Eat', 'Food or meal', 'Daily Life'),
      ('Drink', 'To drink', 'Daily Life'),
      ('Sleep', 'Sleep or rest', 'Daily Life'),
      ('Money', 'Financial or payment', 'Daily Life'),
      ('Home', 'House or home', 'Daily Life'),
      ('Work', 'Job or work', 'Daily Life'),
      ('Time', 'Time or hour', 'Daily Life'),
      ('Toilet', 'Bathroom request', 'Daily Life'),
      ('Phone', 'Telephone', 'Daily Life'),
      // Food (incl. Zimbabwe staples)
      ('Food', 'Food in general', 'Food'),
      ('Sadza', 'Zimbabwean maize-meal staple', 'Food'),
      ('Bread', 'Bread', 'Food'),
      ('Rice', 'Rice', 'Food'),
      ('Meat', 'Meat', 'Food'),
      ('Chicken', 'Chicken', 'Food'),
      ('Fish', 'Fish', 'Food'),
      ('Fruit', 'Fruit', 'Food'),
      ('Vegetables', 'Vegetables', 'Food'),
      ('Sugar', 'Sugar or sweet', 'Food'),
      ('Salt', 'Salt', 'Food'),
      ('Breakfast', 'Morning meal', 'Food'),
      ('Lunch', 'Midday meal', 'Food'),
      ('Supper', 'Evening meal', 'Food'),
      ('Hungry', 'Needing food', 'Food'),
      ('Thirsty', 'Needing a drink', 'Food'),
      // Actions
      ('Wait', 'Ask to wait', 'Actions'),
      ('Come', 'Motion or invitation', 'Actions'),
      ('Go', 'Motion to leave', 'Actions'),
      ('Stop', 'Request to stop', 'Actions'),
      ('Look', 'Look or watch', 'Actions'),
      ('Give', 'Give something', 'Actions'),
      ('Want', 'Want or need', 'Actions'),
      ('Finish', 'Done or finished', 'Actions'),
      ('Sit', 'Sit down', 'Actions'),
      ('Stand', 'Stand up', 'Actions'),
      ('Walk', 'To walk', 'Actions'),
      ('Run', 'To run', 'Actions'),
      ('Call', 'Make a phone call', 'Actions'),
      ('Write', 'To write', 'Actions'),
      ('Read', 'To read', 'Actions'),
      // People & family
      ('Family', 'Family', 'Social'),
      ('Friend', 'Companion or friend', 'Social'),
      ('Mother', 'Mother', 'Social'),
      ('Father', 'Father', 'Social'),
      ('Child', 'Child', 'Social'),
      ('Baby', 'A baby', 'Social'),
      ('Brother', 'Male sibling', 'Social'),
      ('Sister', 'Female sibling', 'Social'),
      ('Grandmother', 'Grandmother (Mbuya)', 'Social'),
      ('Grandfather', 'Grandfather (Sekuru)', 'Social'),
      ('Husband', 'Husband', 'Social'),
      ('Wife', 'Wife', 'Social'),
      ('Uncle', 'Uncle', 'Social'),
      ('Aunt', 'Aunt', 'Social'),
      ('Love', 'Expression of affection', 'Social'),
      ('You', 'Pointing to person', 'Social'),
      ('Me', 'Referring to self', 'Social'),
      ('Deaf', 'A deaf person', 'Social'),
      ('Sign Language', 'Signing itself', 'Social'),
      ('Interpreter', 'Sign language interpreter', 'Social'),
      // Emotions
      ('Happy', 'Feeling happy', 'Emotions'),
      ('Sad', 'Feeling sad', 'Emotions'),
      ('Angry', 'Feeling angry', 'Emotions'),
      ('Cry', 'Crying', 'Emotions'),
      ('Afraid', 'Feeling scared', 'Emotions'),
      // Health & services
      ('Doctor', 'Medical assistance', 'Health'),
      ('Nurse', 'Nurse', 'Health'),
      ('Hospital', 'Hospital', 'Health'),
      ('Clinic', 'Local clinic', 'Health'),
      ('Ambulance', 'Emergency vehicle', 'Health'),
      ('Medicine', 'Medicine or tablets', 'Health'),
      ('Sick', 'Feeling unwell', 'Health'),
      ('Pain', 'Physical pain', 'Health'),
      ('Fever', 'High temperature', 'Health'),
      ('Headache', 'Head pain', 'Health'),
      ('Cough', 'Coughing', 'Health'),
      ('Pregnant', 'Pregnancy', 'Health'),
      // Education
      ('School', 'Education related', 'Education'),
      ('Teacher', 'Teacher', 'Education'),
      ('Student', 'Student', 'Education'),
      ('Learn', 'To learn', 'Education'),
      ('Book', 'A book', 'Education'),
      ('Class', 'A class or lesson', 'Education'),
      // Travel & places (incl. Zimbabwe context)
      ('Kombi', 'Zimbabwean minibus taxi', 'Travel'),
      ('Bus', 'A bus', 'Travel'),
      ('Car', 'A car', 'Travel'),
      ('Road', 'A road', 'Travel'),
      ('Village', 'Rural village', 'Travel'),
      ('Town', 'A town', 'Travel'),
      ('City', 'A city', 'Travel'),
      ('Market', 'Marketplace', 'Travel'),
      ('Church', 'Place of worship', 'Travel'),
      // Commerce
      ('Sale', 'Selling or a discounted offer', 'Shopping'),
      ('Discount', 'Reduced price', 'Shopping'),
      ('Wallet', 'Money wallet or purse', 'Shopping'),
      ('Cart', 'Shopping cart', 'Shopping'),
      ('Pay', 'Paying for goods', 'Shopping'),
      ('Cashier', 'Shop cashier or till', 'Shopping'),
      // Emergency & weather
      ('Police', 'Police assistance', 'Emergency'),
      ('Fire', 'Fire emergency', 'Emergency'),
      ('Accident', 'An accident', 'Emergency'),
      ('Danger', 'Danger or warning', 'Emergency'),
      ('Rain', 'Raining weather', 'Weather'),
      ('Sun', 'Sunny weather', 'Weather'),
      ('Hot', 'Hot temperature', 'Weather'),
      ('Cold', 'Cold temperature', 'Weather'),
    ];

    final now = DateTime.now().toIso8601String();
    for (final (label, meaning, category) in defaults) {
      if (existing.contains(label.toLowerCase())) continue;
      await db.insert('gestures', {
        'uuid': _uuid.v4(),
        'label': label,
        'meaning': meaning,
        'category': category,
        'image_url': '',
        'is_active': 1,
        'created_at': now,
        'updated_at': now,
      });
    }
  }

  /// Bundled MediaPipe hand-landmark samples for every alphabet letter
  /// (source: public ASL-landmark dataset). Seeded so sign tiles can draw
  /// the real hand skeleton fully offline — only labels with no captured
  /// samples are filled, so admin training data always wins. Reference
  /// data only: not enqueued for sync.
  Future<void> _seedLetterSamples(Database db) async {
    Map<String, dynamic> data;
    try {
      data = jsonDecode(
        await rootBundle.loadString('assets/sign_landmarks.json'),
      ) as Map<String, dynamic>;
    } catch (_) {
      return; // asset missing — skeletons simply won't render
    }
    for (final e in data.entries) {
      final has =
          Sqflite.firstIntValue(
            await db.rawQuery(
              'SELECT COUNT(*) FROM gesture_samples WHERE label = ?',
              [e.key],
            ),
          ) ??
          0;
      if (has > 0) continue;
      for (final lm in e.value as List) {
        await db.insert('gesture_samples', {
          'uuid': _uuid.v4(),
          'label': e.key,
          'landmarks': jsonEncode(lm),
          'created_at': DateTime.now().toIso8601String(),
        });
      }
    }
  }

  // ------------------------------------------------------------------ auth

  String _hashPassword(String password) =>
      _bcrypt.hashpw(password, _bcrypt.gensalt());

  String _legacyHash(String password) =>
      sha256.convert(utf8.encode('thando_zsl_salt:$password')).toString();

  bool _isBcrypt(String hash) => hash.startsWith(r'$2');

  Future<User?> findUserByEmail(String email) async {
    final db = await database;
    final result = await db.query(
      'users',
      where: 'email = ?',
      whereArgs: [email.trim().toLowerCase()],
    );
    if (result.isEmpty) return null;
    return User.fromMap(result.first);
  }

  Future<User> registerUser(
    String name,
    String email,
    String password, {
    String role = 'user',
  }) async {
    final db = await database;
    final normalized = email.trim().toLowerCase();
    final existing = await db.query(
      'users',
      where: 'email = ?',
      whereArgs: [normalized],
    );
    if (existing.isNotEmpty) {
      throw StateError('An account with this email already exists.');
    }

    final user = <String, Object?>{
      'uuid': _uuid.v4(),
      'name': name.trim(),
      'email': normalized,
      'password_hash': _hashPassword(password),
      'role': role,
      'is_active': 1,
      'must_change_password': 0,
      'created_at': DateTime.now().toIso8601String(),
    };
    final id = await db.insert('users', user);
    user['id'] = id;
    // Minimal payload — must not overwrite role/is_active on an existing
    // server profile (an admin could have promoted this email already).
    await _enqueue('profiles', normalized, 'upsert', {
      'email': normalized,
      'name': user['name'],
      'updated_at': user['created_at'],
    });
    return User.fromMap(user);
  }

  Future<User?> login(String email, String password) async {
    final user = await findUserByEmail(email);
    if (user == null) return null;
    // Profiles pulled from the cloud that never signed in here carry a
    // sentinel hash — there is no local password to verify against.
    if (user.passwordHash.startsWith('!')) return null;

    final ok = _isBcrypt(user.passwordHash)
        ? _bcrypt.checkpw(password, user.passwordHash)
        : _legacyHash(password) == user.passwordHash;
    if (!ok) return null;
    if (!user.isActive) {
      throw StateError('This account has been deactivated. Contact an admin.');
    }

    // Upgrade legacy SHA-256 hashes to bcrypt transparently.
    if (!_isBcrypt(user.passwordHash)) {
      await changePasswordHash(user.id!, _hashPassword(password));
    }

    await logActivity(user.id, 'login', 'User signed in');
    return user;
  }

  Future<void> changePasswordHash(int userId, String newHash) async {
    final db = await database;
    await db.update(
      'users',
      {'password_hash': newHash, 'must_change_password': 0},
      where: 'id = ?',
      whereArgs: [userId],
    );
  }

  Future<void> changePassword(int userId, String newPassword) async {
    await changePasswordHash(userId, _hashPassword(newPassword));
    await logActivity(userId, 'password_change', 'User changed password');
  }

  /// Re-stamps the local hash after a successful remote sign-in — keeps
  /// offline login working when the password was set or changed elsewhere.
  /// Unlike [changePassword] it does not clear a pending forced-rotation
  /// flag or write an audit row.
  Future<void> cacheLocalPassword(int userId, String password) async {
    final db = await database;
    await db.update(
      'users',
      {'password_hash': _hashPassword(password)},
      where: 'id = ?',
      whereArgs: [userId],
    );
  }

  /// Generates a temporary password for [userId] and flags the account for
  /// a forced change at next sign-in. The plain-text value is returned so
  /// the admin can relay it — only the hash is ever stored.
  Future<String> resetUserPassword(int userId) async {
    const chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final rand = math.Random.secure();
    final temp = List.generate(
      10,
      (_) => chars[rand.nextInt(chars.length)],
    ).join();

    final db = await database;
    await db.update(
      'users',
      {'password_hash': _hashPassword(temp), 'must_change_password': 1},
      where: 'id = ?',
      whereArgs: [userId],
    );
    await logActivity(userId, 'password_reset', 'Admin reset user password');
    return temp;
  }

  // --------------------------------------------------------- self-serve reset

  /// Issues a 6-digit reset code for [email], valid for 10 minutes.
  /// Returns the code so the caller can display it — there is no mail
  /// backend, so the app itself shows the code to the user. Returns null
  /// when no account matches the address.
  Future<String?> createPasswordReset(String email) async {
    final user = await findUserByEmail(email);
    if (user == null) return null;

    final rand = math.Random.secure();
    final code = (100000 + rand.nextInt(900000)).toString();
    final db = await database;
    await db.update(
      'users',
      {
        'reset_code': code,
        'reset_expires': DateTime.now()
            .add(const Duration(minutes: 10))
            .toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [user.id],
    );
    await logActivity(user.id, 'password_reset', 'Reset code issued');
    return code;
  }

  /// Verifies the reset [code] for [email] and applies [newPassword].
  /// Returns false on an unknown account, wrong code, or expired code.
  Future<bool> resetPasswordWithCode(
    String email,
    String code,
    String newPassword,
  ) async {
    final user = await findUserByEmail(email);
    if (user == null) return false;

    final db = await database;
    final rows = await db.query(
      'users',
      columns: ['reset_code', 'reset_expires'],
      where: 'id = ?',
      whereArgs: [user.id],
    );
    final stored = rows.first['reset_code'] as String?;
    final expires = DateTime.tryParse(
      rows.first['reset_expires'] as String? ?? '',
    );
    final valid =
        stored != null &&
        stored == code.trim() &&
        expires != null &&
        DateTime.now().isBefore(expires);
    if (!valid) return false;

    await changePassword(user.id!, newPassword);
    await db.update(
      'users',
      {'reset_code': null, 'reset_expires': null},
      where: 'id = ?',
      whereArgs: [user.id],
    );
    await logActivity(
      user.id,
      'password_reset',
      'Password reset via self-serve code',
    );
    return true;
  }

  // ----------------------------------------------------------------- users

  Future<List<User>> getUsers() async {
    final db = await database;
    final result = await db.query('users', orderBy: 'created_at DESC');
    return result.map(User.fromMap).toList();
  }

  /// Caches the Supabase profile/auth id on the local user row and mirrors
  /// remote role/activation state for offline sign-in.
  Future<void> linkRemoteUser(
    String email, {
    String? remoteId,
    String? role,
    bool? isActive,
    String? name,
  }) async {
    final db = await database;
    final values = <String, Object?>{};
    if (remoteId != null) values['remote_id'] = remoteId;
    if (role != null) values['role'] = role;
    if (isActive != null) values['is_active'] = isActive ? 1 : 0;
    if (name != null && name.isNotEmpty) values['name'] = name;
    if (values.isEmpty) return;
    await db.update(
      'users',
      values,
      where: 'email = ?',
      whereArgs: [email.trim().toLowerCase()],
    );
  }

  /// Upserts a profile pushed down from Supabase. A remote-only user gets
  /// a local stub row — the account shows in Users on every device and
  /// stays until an admin removes it; a real password hash is written by
  /// the first cloud sign-in on this device.
  Future<void> upsertProfileFromRemote(Map<String, Object?> profile) async {
    final email = (profile['email'] as String? ?? '').trim().toLowerCase();
    if (email.isEmpty) return;
    final db = await database;
    final existing = await db.query(
      'users',
      columns: ['id'],
      where: 'email = ?',
      whereArgs: [email],
    );
    if (existing.isNotEmpty) {
      await linkRemoteUser(
        email,
        remoteId: profile['id'] as String?,
        name: profile['name'] as String?,
        role: profile['role'] as String?,
        isActive: profile['is_active'] as bool?,
      );
      return;
    }
    await db.insert('users', {
      'uuid': _uuid.v4(),
      'remote_id': profile['id'],
      'name': (profile['name'] as String?)?.isNotEmpty == true
          ? profile['name']
          : email.split('@').first,
      'email': email,
      'password_hash': remoteOnlyPasswordHash,
      'role': profile['role'] ?? 'user',
      'is_active': (profile['is_active'] as bool? ?? true) ? 1 : 0,
      'must_change_password': 0,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> updateUserStatus(int userId, bool isActive) async {
    final db = await database;
    await db.update(
      'users',
      {'is_active': isActive ? 1 : 0},
      where: 'id = ?',
      whereArgs: [userId],
    );
    await _enqueueUser(userId);
    await logActivity(null, 'user_status', 'User $userId active=$isActive');
  }

  Future<void> updateUserRole(int userId, String role) async {
    final db = await database;
    await db.update(
      'users',
      {'role': role},
      where: 'id = ?',
      whereArgs: [userId],
    );
    await _enqueueUser(userId);
    await logActivity(null, 'user_role', 'User $userId role=$role');
  }

  Future<void> deleteUser(int userId) async {
    final db = await database;
    final rows = await db.query(
      'users',
      columns: ['email'],
      where: 'id = ?',
      whereArgs: [userId],
    );
    final email = rows.isEmpty ? '' : rows.first['email'] as String;
    await db.delete('users', where: 'id = ?', whereArgs: [userId]);
    if (email.isNotEmpty) {
      await _enqueue('profiles', email, 'delete', {'email': email});
    }
    await logActivity(null, 'user_delete', 'User $userId deleted');
  }

  // -------------------------------------------------------------- gestures

  Future<List<GestureItem>> getGestures({bool activeOnly = true}) async {
    final db = await database;
    final result = await db.query(
      'gestures',
      where: activeOnly ? 'is_active = 1' : null,
      orderBy: 'label ASC',
    );
    return result.map(GestureItem.fromMap).toList();
  }

  Future<List<String>> getActiveGestureLabels() async {
    final db = await database;
    final result = await db.query(
      'gestures',
      columns: ['label'],
      where: 'is_active = 1',
      orderBy: 'label ASC',
    );
    return result.map((r) => r['label'] as String).toList();
  }

  Future<int> addGesture(String label, String meaning, String category) =>
      _gestureLock.synchronized(() => _addGesture(label, meaning, category));

  Future<int> _addGesture(
    String label,
    String meaning,
    String category,
  ) async {
    final db = await database;
    final trimmed = label.trim();
    final dup = await db.query(
      'gestures',
      columns: ['id'],
      where: 'LOWER(label) = LOWER(?)',
      whereArgs: [trimmed],
    );
    if (dup.isNotEmpty) {
      throw StateError('A gesture with this label already exists.');
    }
    final now = DateTime.now().toIso8601String();
    final id = await db.insert('gestures', {
      'uuid': _uuid.v4(),
      'label': trimmed,
      'meaning': meaning.trim(),
      'category': category.trim().isEmpty ? 'General' : category.trim(),
      'image_url': '',
      'is_active': 1,
      'created_at': now,
      'updated_at': now,
    });
    await _enqueueGesture(id);
    return id;
  }

  /// Edits an existing gesture's text fields. Renaming keeps the same uuid
  /// so the change propagates to the server copy.
  Future<void> updateGesture(
    int id,
    String label,
    String meaning,
    String category,
  ) =>
      _gestureLock.synchronized(
        () => _updateGesture(id, label, meaning, category),
      );

  Future<void> _updateGesture(
    int id,
    String label,
    String meaning,
    String category,
  ) async {
    final db = await database;
    final trimmed = label.trim();
    if (trimmed.isEmpty || meaning.trim().isEmpty) {
      throw StateError('Label and meaning are required.');
    }
    final dup = await db.query(
      'gestures',
      columns: ['id'],
      where: 'LOWER(label) = LOWER(?) AND id != ?',
      whereArgs: [trimmed, id],
    );
    if (dup.isNotEmpty) {
      throw StateError('A gesture with this label already exists.');
    }
    await db.update(
      'gestures',
      {
        'label': trimmed,
        'meaning': meaning.trim(),
        'category': category.trim().isEmpty ? 'General' : category.trim(),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    await _enqueueGesture(id);
  }

  /// Applies a full remote gesture snapshot atomically under the gesture
  /// lock — the single entry point for pull and realtime reconcile:
  /// upserts each row (oldest first so the newest remote state lands
  /// last), propagates upstream deletes, then collapses label dupes.
  Future<void> applyRemoteGestures(
    List<Map<String, dynamic>> remoteGestures,
  ) {
    return _gestureLock.synchronized(() async {
      final db = await database;
      final sorted = List<Map<String, dynamic>>.of(remoteGestures)
        ..sort(
          (a, b) => (a['updated_at'] as String? ?? '').compareTo(
            b['updated_at'] as String? ?? '',
          ),
        );
      final remoteUuids = <String>{};
      for (final g in sorted) {
        remoteUuids.add(g['uuid'] as String? ?? '');
        await _upsertGestureFromRemote(db, g);
      }

      // Propagate remote deletes: a local gesture whose uuid is absent
      // upstream and isn't awaiting upload is removed locally.
      final pending = await db.query(
        'pending_sync',
        columns: ['entity_key'],
        where: 'entity = ?',
        whereArgs: ['gestures'],
      );
      final pendingKeys = pending
          .map((r) => r['entity_key'] as String)
          .toSet();
      final local = await db.query('gestures');
      for (final g in local) {
        final uuid = g['uuid'] as String?;
        if (uuid != null &&
            !remoteUuids.contains(uuid) &&
            !pendingKeys.contains(uuid) &&
            remoteGestures.isNotEmpty) {
          await db.delete('gestures', where: 'id = ?', whereArgs: [g['id']]);
        }
      }
      await _dedupeGestureLabels(db);
    });
  }

  /// Applies a gesture pushed down from Supabase — keyed on label so an
  /// admin edit on another device lands on the existing local row.
  Future<void> upsertGestureFromRemote(Map<String, Object?> g) =>
      _gestureLock.synchronized(
        () async => _upsertGestureFromRemote(await database, g),
      );

  /// A gesture upsert still queued for upload — remote snapshots must not
  /// clobber the row until the local edit lands.
  Future<bool> _hasPendingGestureOp(Database db, String? uuid) async {
    if (uuid == null) return false;
    final rows = await db.query(
      'pending_sync',
      columns: ['id'],
      where: 'entity = ? AND entity_key = ?',
      whereArgs: ['gestures', uuid],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> _upsertGestureFromRemote(
    Database db,
    Map<String, Object?> g,
  ) async {
    final label = (g['label'] as String? ?? '').trim();
    if (label.isEmpty) return;
    final matches = await db.query(
      'gestures',
      where: 'LOWER(label) = LOWER(?)',
      whereArgs: [label],
    );
    final remoteUpdated =
        DateTime.tryParse(g['updated_at'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final values = <String, Object?>{
      'uuid': g['uuid'],
      'meaning': g['meaning'] ?? '',
      'category': g['category'] ?? 'General',
      'image_url': g['image_url'] ?? '',
      'is_active': (g['is_active'] as bool? ?? true) ? 1 : 0,
      'updated_at': g['updated_at'],
    };
    if (matches.isEmpty) {
      await db.insert('gestures', {
        ...values,
        'label': label,
        'created_at': g['created_at'] ?? DateTime.now().toIso8601String(),
      });
      return;
    }
    // A local edit still queued for upload wins over remote state —
    // without this a stale snapshot reverts fresh toggles (the on/off
    // flicker). The remote update lands on the next reconcile after the
    // push, once the local row is no longer in flight.
    for (final m in matches) {
      if (await _hasPendingGestureOp(db, m['uuid'] as String?)) return;
    }
    for (final extra in matches.skip(1)) {
      await _removeGestureDuplicate(db, extra);
    }
    final localUpdated =
        DateTime.tryParse(matches.first['updated_at'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    // Last write wins — a newer local edit stays until its own push lands.
    if (remoteUpdated.isAfter(localUpdated)) {
      await db.update(
        'gestures',
        values,
        where: 'id = ?',
        whereArgs: [matches.first['id']],
      );
    }
  }

  Future<void> updateGestureStatus(int id, bool isActive) =>
      _gestureLock.synchronized(() async {
        final db = await database;
        await db.update(
          'gestures',
          {
            'is_active': isActive ? 1 : 0,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [id],
        );
        await _enqueueGesture(id);
      });

  /// Points the gesture at its illustration — a Supabase Storage object
  /// path for cloud-shared images, or empty to clear.
  Future<void> setGestureImageUrl(int id, String imageUrl) =>
      _gestureLock.synchronized(() async {
        final db = await database;
        await db.update(
          'gestures',
          {
            'image_url': imageUrl,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [id],
        );
        await _enqueueGesture(id);
      });

  Future<void> deleteGesture(int id) =>
      _gestureLock.synchronized(() async {
        final db = await database;
        final rows = await db.query(
          'gestures',
          columns: ['uuid'],
          where: 'id = ?',
          whereArgs: [id],
        );
        await db.delete('gestures', where: 'id = ?', whereArgs: [id]);
        final uuid = rows.isEmpty ? null : rows.first['uuid'] as String?;
        if (uuid != null) {
          await _enqueue('gestures', uuid, 'delete', {'uuid': uuid});
        }
      });

  /// Removes a gesture locally without queueing a server delete — used
  /// when the row was deleted upstream and the pull is just following it.
  Future<void> removeGestureLocal(int id) =>
      _gestureLock.synchronized(() async {
        final db = await database;
        await db.delete('gestures', where: 'id = ?', whereArgs: [id]);
      });

  /// Wipes the gesture table and re-seeds the bundled vocabulary — the
  /// admin "reset dataset" action. Server side gets a 'clear' op followed
  /// by upserts for every seeded row.
  Future<void> resetGestureDataset() =>
      _gestureLock.synchronized(_resetGestureDataset);

  Future<void> _resetGestureDataset() async {
    final db = await database;
    final rows = await db.query('gestures', columns: ['uuid']);
    await db.delete('gestures');
    await _enqueue('gestures', '*', 'clear', {});
    await _seedGestures(db);
    final seeded = await db.query('gestures', columns: ['id']);
    for (final r in seeded) {
      await _enqueueGesture(r['id'] as int);
    }
    for (final r in rows) {
      // Deleted gestures not re-seeded get explicit delete ops so the
      // server doesn't keep stale rows the clear already removed.
      final uuid = r['uuid'] as String?;
      if (uuid != null) {
        await _enqueue('gestures', uuid, 'delete', {'uuid': uuid});
      }
    }
    await logActivity(
      null,
      'dataset_reset',
      'Gesture dataset reset to defaults',
    );
  }

  // ---------------------------------------------------------- translations

  Future<int> saveTranslation(TranslationRecord record) async {
    final db = await database;
    final rowUuid = _uuid.v4();
    final id = await db.insert('translations', {
      ...record.toMap(),
      'uuid': rowUuid,
    });
    final userRows = await db.query(
      'users',
      columns: ['email'],
      where: 'id = ?',
      whereArgs: [record.userId],
    );
    await _enqueue('translations', rowUuid, 'insert', {
      'uuid': rowUuid,
      'user_email': userRows.isEmpty ? null : userRows.first['email'],
      'input_type': record.inputType,
      'input_label': record.inputLabel,
      'translated_text': record.translatedText,
      'confidence': record.confidence,
      'source': record.source,
      'created_at': record.createdAt.toIso8601String(),
    });
    return id;
  }

  Future<List<TranslationRecord>> getTranslationsForUser(
    int userId, {
    int limit = 50,
  }) async {
    final db = await database;
    final result = await db.query(
      'translations',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return result.map(TranslationRecord.fromMap).toList();
  }

  Future<List<TranslationRecord>> getAllTranslations({int limit = 500}) async {
    final db = await database;
    final result = await db.query(
      'translations',
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return result.map(TranslationRecord.fromMap).toList();
  }

  Future<List<TranslationRecord>> getRecentTranslations({
    int limit = 50,
  }) async {
    final db = await database;
    final result = await db.query(
      'translations',
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return result.map(TranslationRecord.fromMap).toList();
  }

  Future<Map<String, int>> getTranslationStats() async {
    final db = await database;
    final total =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM translations'),
        ) ??
        0;
    final users =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM users'),
        ) ??
        0;
    final gestures =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM gestures'),
        ) ??
        0;
    final today = await db.rawQuery(
      'SELECT COUNT(*) as c FROM translations WHERE date(created_at) = date(\'now\', \'localtime\')',
    );
    return {
      'total': total,
      'users': users,
      'gestures': gestures,
      'today': Sqflite.firstIntValue(today) ?? 0,
    };
  }

  // -------------------------------------------------------------- reporting

  String _cutoffIso(int days) =>
      DateTime.now().subtract(Duration(days: days)).toIso8601String();

  /// Translations per calendar day within the last [days] days.
  /// Keys are 'YYYY-MM-DD' strings.
  Future<Map<String, int>> getTranslationsByDay(int days) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT date(created_at) AS d, COUNT(*) AS c FROM translations '
      'WHERE created_at >= ? GROUP BY d',
      [_cutoffIso(days)],
    );
    return {for (final r in rows) r['d'] as String: (r['c'] as num).toInt()};
  }

  /// New user registrations per calendar day within the last [days] days.
  Future<Map<String, int>> getSignupsByDay(int days) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT date(created_at) AS d, COUNT(*) AS c FROM users '
      'WHERE created_at >= ? GROUP BY d',
      [_cutoffIso(days)],
    );
    return {for (final r in rows) r['d'] as String: (r['c'] as num).toInt()};
  }

  /// Recognition source breakdown ('on-device', 'gemini', …) in the period.
  Future<Map<String, int>> getTranslationsBySource(int days) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT source, COUNT(*) AS c FROM translations '
      'WHERE created_at >= ? GROUP BY source ORDER BY c DESC',
      [_cutoffIso(days)],
    );
    return {
      for (final r in rows)
        (r['source'] as String? ?? 'unknown'): (r['c'] as num).toInt(),
    };
  }

  /// Input type breakdown ('gesture', 'batch', 'speech') in the period.
  Future<Map<String, int>> getTranslationsByType(int days) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT input_type, COUNT(*) AS c FROM translations '
      'WHERE created_at >= ? GROUP BY input_type ORDER BY c DESC',
      [_cutoffIso(days)],
    );
    return {
      for (final r in rows)
        (r['input_type'] as String? ?? 'unknown'): (r['c'] as num).toInt(),
    };
  }

  /// Most translated signs/inputs in the period, most frequent first.
  Future<List<Map<String, Object?>>> getTopSigns(
    int days, {
    int limit = 8,
  }) async {
    final db = await database;
    return db.rawQuery(
      'SELECT input_label AS label, COUNT(*) AS c FROM translations '
      "WHERE created_at >= ? AND input_label != '' "
      'GROUP BY input_label ORDER BY c DESC LIMIT ?',
      [_cutoffIso(days), limit],
    );
  }

  /// Per-user engagement in the period: translation count, last active
  /// timestamp and sign-in count (from system_logs 'login' actions).
  Future<List<Map<String, Object?>>> getUserEngagement(int days) async {
    final db = await database;
    return db.rawQuery(
      '''
      SELECT u.id, u.name, u.email, u.role, u.is_active, u.created_at,
             COALESCE(t.cnt, 0) AS translations,
             t.last_active,
             COALESCE(l.cnt, 0) AS logins
      FROM users u
      LEFT JOIN (
        SELECT user_id, COUNT(*) AS cnt, MAX(created_at) AS last_active
        FROM translations WHERE created_at >= ? GROUP BY user_id
      ) t ON t.user_id = u.id
      LEFT JOIN (
        SELECT user_id, COUNT(*) AS cnt FROM system_logs
        WHERE action = 'login' AND created_at >= ? GROUP BY user_id
      ) l ON l.user_id = u.id
      ORDER BY translations DESC, u.created_at DESC
      ''',
      [_cutoffIso(days), _cutoffIso(days)],
    );
  }

  /// Headline engagement numbers for the period.
  Future<Map<String, int>> getEngagementSummary(int days) async {
    final db = await database;
    final cutoff = _cutoffIso(days);
    Future<int> count(String sql) async =>
        Sqflite.firstIntValue(await db.rawQuery(sql, [cutoff])) ?? 0;
    return {
      'activeUsers': await count(
        'SELECT COUNT(DISTINCT user_id) FROM translations WHERE created_at >= ?',
      ),
      'logins': await count(
        "SELECT COUNT(*) FROM system_logs WHERE action = 'login' AND created_at >= ?",
      ),
      'newUsers': await count(
        'SELECT COUNT(*) FROM users WHERE created_at >= ?',
      ),
      'translations': await count(
        'SELECT COUNT(*) FROM translations WHERE created_at >= ?',
      ),
      'totalUsers':
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM users'),
          ) ??
          0,
      'inactiveUsers':
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM users WHERE is_active = 0'),
          ) ??
          0,
    };
  }

  /// Deletes translation history older than [cutoff]. Returns the number
  /// of rows removed. Local only — server history is managed separately.
  Future<int> purgeTranslationsOlderThan(DateTime cutoff) async {
    final db = await database;
    final removed = await db.delete(
      'translations',
      where: 'created_at < ?',
      whereArgs: [cutoff.toIso8601String()],
    );
    if (removed > 0) {
      await logActivity(
        null,
        'data_purge',
        'Purged $removed translations older than ${cutoff.toIso8601String()}',
      );
    }
    return removed;
  }

  /// Removes every translation row belonging to [userId] on this device.
  Future<int> deleteTranslationsForUser(int userId) async {
    final db = await database;
    return db.delete('translations', where: 'user_id = ?', whereArgs: [userId]);
  }

  // ------------------------------------------------------------------ logs

  Future<void> logActivity(int? userId, String action, String details) async {
    final db = await database;
    final rowUuid = _uuid.v4();
    final now = DateTime.now().toIso8601String();
    await db.insert('system_logs', {
      'uuid': rowUuid,
      'user_id': userId,
      'action': action,
      'details': details,
      'created_at': now,
    });
    String? email;
    if (userId != null) {
      final rows = await db.query(
        'users',
        columns: ['email'],
        where: 'id = ?',
        whereArgs: [userId],
      );
      if (rows.isNotEmpty) email = rows.first['email'] as String?;
    }
    await _enqueue('system_logs', rowUuid, 'insert', {
      'uuid': rowUuid,
      'user_email': email,
      'action': action,
      'details': details,
      'created_at': now,
    });
  }

  Future<void> clearSystemLogs() async {
    final db = await database;
    await db.delete('system_logs');
    await _enqueue('system_logs', '*', 'clear', {});
  }

  Future<List<Map<String, Object?>>> getSystemLogs({int limit = 100}) async {
    final db = await database;
    return db.query('system_logs', orderBy: 'created_at DESC', limit: limit);
  }

  /// Absolute path to the live SQLite file — used by backup export/restore.
  Future<String> databasePath() async {
    final dbPath = await getDatabasesPath();
    return p.join(dbPath, _dbName);
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
