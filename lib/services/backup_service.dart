import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

import 'db_service.dart';

/// Full-database backup and restore. The backup is the raw SQLite file —
/// it contains users, the gesture dataset, history, logs and samples, so
/// a restore brings back the complete app state.
class BackupService {
  BackupService(this._db);

  final DbService _db;

  /// Copies the live database to a timestamped file in the temp dir.
  /// A WAL checkpoint first makes the single file self-contained.
  Future<File> exportBackup() async {
    final db = await _db.database;
    // rawQuery, not execute — wal_checkpoint returns a row, and Android's
    // execSQL throws "unknown error (code 0)" for statements that do.
    await db.rawQuery('PRAGMA wal_checkpoint(FULL)');
    final stamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
    final dir = await getTemporaryDirectory();
    final out = File(p.join(dir.path, 'thandosign_backup_$stamp.db'));
    return File(await _db.databasePath()).copy(out.path);
  }

  /// Creates a backup and opens the platform share sheet.
  Future<void> shareBackup() async {
    final file = await exportBackup();
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        subject: 'ThandoSign database backup',
      ),
    );
  }

  /// Lets the user pick a .db file and verifies it looks like a ThandoSign
  /// backup before touching anything. Returns null when cancelled.
  Future<File?> pickAndValidateBackup() async {
    final picked = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'ThandoSign backup', extensions: ['db']),
      ],
      confirmButtonText: 'Restore',
    );
    final path = picked?.path;
    if (path == null) return null;

    Database? probe;
    try {
      probe = await openReadOnlyDatabase(path);
      final tables = await probe.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      );
      final names = tables.map((t) => t['name']).toSet();
      if (!names.contains('users') || !names.contains('gestures')) {
        throw StateError('That file is not a ThandoSign backup.');
      }
    } on StateError {
      rethrow;
    } catch (e) {
      throw StateError('Could not read that file as a database.');
    } finally {
      await probe?.close();
    }
    return File(path);
  }

  /// Replaces the live database with [file]. The copy goes through a temp
  /// file first so a failed write can't corrupt the current install.
  /// Caller must re-run auth/session logic afterwards.
  Future<void> restoreFrom(File file) async {
    final dest = await _db.databasePath();
    final tmpPath = '$dest.restore_tmp';
    await file.copy(tmpPath);
    await _db.close();
    await File(tmpPath).rename(dest);
    // Reopen — runs migrations and reseeding on the restored file.
    await _db.database;
  }
}
