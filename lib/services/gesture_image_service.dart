import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/gesture_item.dart';
import 'auth_service.dart';
import 'db_service.dart';
import 'gemini_service.dart';
import 'supabase_service.dart';

/// Resolves gesture illustrations on demand so callers never think about
/// where images come from:
///
///   local file  →  download from the gesture-images bucket  →
///   AI-generate with Gemini  →  (admin only) upload so other
///   devices can pull it.
///
/// Every path degrades silently — a gesture without an image simply
/// shows a placeholder in the UI.
class GestureImageService {
  GestureImageService({
    required this.db,
    required this.supabase,
    required this.gemini,
    required this.auth,
  });

  final DbService db;
  final SupabaseService supabase;
  final GeminiService gemini;
  final AuthService auth;

  // One resolution per gesture at a time — dedupes simultaneous UI
  // requests and serialises quota spend during bulk generation.
  final Map<String, Future<File?>> _inFlight = {};

  // Serial mutex for generation — when the dataset list first opens and
  // 30 thumbnails all need images, requests run one-by-one instead of
  // bursting against the API quota.
  Future _genLock = Future.value();

  Future<Uint8List?> _generateSerialized(String label, String meaning) {
    final task = _genLock.then(
      (_) => gemini.generateGestureImage(label, meaning),
    );
    _genLock = task.then((_) {}, onError: (_) {});
    return task;
  }

  /// Ensures an image exists for [g] and returns the local file, or null.
  /// Safe to call from every build — results are cached on disk and
  /// concurrent calls share one in-flight resolution.
  Future<File?> ensureImage(GestureItem g) {
    final uuid = g.uuid;
    if (uuid == null) return Future.value(null);
    return _inFlight.putIfAbsent(uuid, () {
      return _resolve(g).whenComplete(() => _inFlight.remove(uuid));
    });
  }

  /// Local file if it already exists — synchronous check for the common
  /// case (images persist across restarts).
  Future<File?> cachedFile(String uuid) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'gesture_images', '$uuid.jpg'));
    return file.existsSync() ? file : null;
  }

  /// Attaches an image picked on-device (photo / downloaded illustration)
  /// to [g]: writes the local file immediately, and for admins uploads to
  /// the gesture-images bucket + records `image_url` so every device can
  /// pull it on sync.
  Future<File?> setImage(GestureItem g, Uint8List raw) async {
    final uuid = g.uuid;
    if (uuid == null) return null;
    final bytes = _compress(raw);
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'gesture_images', '$uuid.jpg'));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    if (supabase.enabled && supabase.isAuthed && auth.isAdmin) {
      try {
        await supabase.uploadGestureImage(uuid, bytes);
        if (g.id != null) await db.setGestureImageUrl(g.id!, '$uuid.jpg');
      } catch (e) {
        debugPrint('Gesture image upload failed: $e');
      }
    }
    return file;
  }

  /// Deletes the local file and clears the remote pointer so the next
  /// [ensureImage] regenerates — the admin "regenerate" action.
  Future<void> regenerate(GestureItem g) async {
    final uuid = g.uuid;
    if (uuid == null) return;
    final file = await cachedFile(uuid);
    if (await file?.exists() ?? false) await file!.delete();
    if (g.id != null) await db.setGestureImageUrl(g.id!, '');
    await ensureImage(g);
  }

  Future<File?> _resolve(GestureItem g) async {
    final uuid = g.uuid!;
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'gesture_images', '$uuid.jpg'));
    if (file.existsSync()) return file;

    // Another device (or an earlier session) already produced one.
    if (g.imageUrl.isNotEmpty && supabase.enabled) {
      final bytes = await supabase.downloadGestureImage(uuid);
      if (bytes != null) {
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
        return file;
      }
    }

    // Generate — the AI facilitation path. Serialized so a burst of
    // misses can't hammer the API quota.
    final raw = await _generateSerialized(g.label, g.meaning);
    if (raw == null) return null;
    final bytes = _compress(raw);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);

    // Share it: only admins can write gestures/storage, so non-admin
    // devices keep their local copy without marking the shared row.
    if (supabase.enabled && supabase.isAuthed && auth.isAdmin) {
      try {
        await supabase.uploadGestureImage(uuid, bytes);
        if (g.id != null) await db.setGestureImageUrl(g.id!, '$uuid.jpg');
      } catch (e) {
        debugPrint('Gesture image upload failed: $e');
      }
    }
    return file;
  }

  /// Normalises whatever the image model returned — decode + bound to
  /// 512px + JPEG q80 so files stay small for storage and sync.
  Uint8List _compress(Uint8List raw) {
    try {
      final decoded = img.decodeImage(raw);
      if (decoded == null) return raw;
      final resized = decoded.width > 512
          ? img.copyResize(decoded, width: 512)
          : decoded;
      return Uint8List.fromList(img.encodeJpg(resized, quality: 80));
    } catch (_) {
      return raw;
    }
  }

  /// Ensures every gesture with a known remote image has it cached — the
  /// background trickle-down after a dataset pull. Serialized through
  /// [_inFlight] so it never races the UI.
  Future<void> primeFromDb() async {
    try {
      final gestures = await db.getGestures(activeOnly: false);
      for (final g in gestures) {
        if (g.imageUrl.isNotEmpty) unawaited(ensureImage(g));
      }
    } catch (_) {}
  }
}
