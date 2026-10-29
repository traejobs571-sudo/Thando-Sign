import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Thin wrapper around the Supabase client. The app is fully functional
/// without a backend — when SUPABASE_URL / SUPABASE_ANON_KEY are absent
/// from assets/.env, [enabled] is false and every method no-ops.
class SupabaseService {
  bool _initialized = false;

  bool get enabled => _initialized;

  SupabaseClient get _client => Supabase.instance.client;

  String? get currentEmail => _client.auth.currentUser?.email;
  String? get currentUserId => _client.auth.currentUser?.id;
  bool get isAuthed => _initialized && _client.auth.currentSession != null;

  /// Reads the env config and starts the client. Safe to call without
  /// credentials — sync just stays off.
  Future<void> init() async {
    final url = dotenv.env['SUPABASE_URL']?.trim() ?? '';
    final key = dotenv.env['SUPABASE_ANON_KEY']?.trim() ?? '';
    if (url.isEmpty || key.isEmpty) {
      debugPrint('Supabase not configured — running local-only.');
      return;
    }
    try {
      await Supabase.initialize(url: url, publishableKey: key);
      _initialized = true;
    } catch (e) {
      debugPrint('Supabase init failed: $e');
    }
  }

  // ------------------------------------------------------------------ auth

  /// Creates the auth account and its public profile row. Returns the new
  /// auth user id, or null when email confirmation is still pending.
  Future<String?> signUp(String email, String password, String name) async {
    final res = await _client.auth.signUp(
      email: email,
      password: password,
      data: {'name': name},
    );
    if (res.user != null) {
      try {
        await _client.from('profiles').upsert({
          'id': res.user!.id,
          'email': email,
          'name': name,
        }, onConflict: 'email');
      } catch (e) {
        debugPrint('Profile upsert after signUp failed: $e');
      }
    }
    return res.user?.id;
  }

  Future<void> signIn(String email, String password) async {
    await _client.auth.signInWithPassword(email: email, password: password);
  }

  /// Creates a cloud account for a user that only existed locally. Silently
  /// ignores "already registered" — the remote password is authoritative.
  Future<String?> provisionIfMissing(
    String email,
    String password,
    String name,
  ) async {
    try {
      return await signUp(email, password, name);
    } on AuthException catch (e) {
      if (e.message.toLowerCase().contains('already')) return null;
      rethrow;
    }
  }

  /// Fetches the profile row for [email] (RLS limits non-admins to their
  /// own row). Null when absent or unreachable.
  Future<Map<String, Object?>?> fetchProfile(String email) async {
    try {
      final row = await _client
          .from('profiles')
          .select()
          .eq('email', email)
          .maybeSingle();
      return row;
    } catch (e) {
      debugPrint('fetchProfile failed: $e');
      return null;
    }
  }

  /// Pushes a password change made locally up to the cloud account.
  Future<void> updateRemotePassword(String newPassword) async {
    await _client.auth.updateUser(UserAttributes(password: newPassword));
  }

  Future<void> signOut() async {
    try {
      await _client.auth.signOut();
    } catch (_) {}
  }

  /// Attempts to restore or refresh the auth session — the stored refresh
  /// token may still be valid even when `currentSession` is null/expired.
  /// Returns true when a live session exists afterwards.
  Future<bool> refreshSession() async {
    if (!_initialized) return false;
    try {
      final res = await _client.auth.refreshSession();
      return res.session != null;
    } catch (e) {
      debugPrint('Session refresh failed: $e');
      return _client.auth.currentSession != null;
    }
  }

  // ------------------------------------------------------------ data push

  /// Executes one outbox operation. Returns the upserted row for
  /// 'profiles' so the caller can capture its server id. Throws on
  /// failure — the sync layer retries.
  Future<Map<String, dynamic>?> pushRow(
    String entity,
    String entityKey,
    String op,
    Map<String, dynamic> payload,
  ) async {
    final table = _client.from(entity);
    switch (op) {
      case 'insert':
        // upsert keeps retries idempotent (uuid PK dedupes).
        await table.upsert(payload);
        return null;
      case 'upsert':
        if (entity == 'profiles') {
          return await table
              .upsert(payload, onConflict: 'email')
              .select('id')
              .single();
        }
        if (entity == 'gestures') {
          try {
            await table.upsert(payload, onConflict: 'uuid');
          } on PostgrestException catch (e) {
            // Same label created on another device with a different uuid —
            // converge on the label instead of failing forever.
            if (!e.message.contains('duplicate') && e.code != '23505') {
              rethrow;
            }
            await table.update(payload).eq('label', payload['label']);
          }
          return null;
        }
        await table.upsert(payload);
        return null;
      case 'delete':
        final col = entity == 'profiles' ? 'email' : 'uuid';
        await table.delete().eq(col, entityKey);
        return null;
      case 'clear':
        // PostgREST refuses unfiltered deletes — match every uuid.
        await table.delete().neq(
          'uuid',
          '00000000-0000-0000-0000-000000000000',
        );
        return null;
      default:
        throw ArgumentError('Unknown sync op: $op');
    }
  }

  // ------------------------------------------------------------ data pull

  Future<List<Map<String, dynamic>>> pullGestures() async {
    return _client.from('gestures').select();
  }

  /// Live feed of the shared gesture dataset — emits the full row set on
  /// every remote insert/update/delete. Requires Realtime to be enabled
  /// for the table (the publication block at the end of schema.pgsql).
  Stream<List<Map<String, dynamic>>> gesturesStream() {
    return _client.from('gestures').stream(primaryKey: ['uuid']);
  }

  Future<List<Map<String, dynamic>>> pullProfiles() async {
    return _client.from('profiles').select();
  }

  // ------------------------------------------------------------ storage

  static const _imageBucket = 'gesture-images';

  /// Uploads (or replaces) a gesture illustration. Admin-only via the
  /// bucket's storage policies — callers should check the local user is
  /// an admin before calling.
  Future<void> uploadGestureImage(String uuid, Uint8List bytes) async {
    await _client.storage
        .from(_imageBucket)
        .uploadBinary(
          '$uuid.jpg',
          bytes,
          fileOptions: const FileOptions(
            upsert: true,
            contentType: 'image/jpeg',
          ),
        );
  }

  /// Downloads a gesture illustration; null when the object is missing.
  Future<Uint8List?> downloadGestureImage(String uuid) async {
    try {
      return await _client.storage.from(_imageBucket).download('$uuid.jpg');
    } catch (_) {
      return null;
    }
  }

  /// Public URL for the object — bucket is public-read so any device can
  /// fetch without credentials.
  String gestureImagePublicUrl(String uuid) {
    return _client.storage.from(_imageBucket).getPublicUrl('$uuid.jpg');
  }
}
