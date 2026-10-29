import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../models/user.dart';
import 'connectivity_service.dart';
import 'db_service.dart';
import 'supabase_service.dart';

/// Hybrid auth: Supabase Auth is authoritative when reachable; the local
/// SQLite account stays as an offline cache so sign-in keeps working with
/// no connection. Accounts created offline are provisioned to the cloud
/// silently the next time the user signs in online.
class AuthService extends ChangeNotifier {
  AuthService(this._db, [this._supabase, this._connectivity]);

  final DbService _db;
  final SupabaseService? _supabase;
  final ConnectivityService? _connectivity;

  static const _sessionKey = 'current_user_id';
  static const _rememberKey = 'remember_me';

  User? _currentUser;
  bool _initialized = false;
  bool _rememberMe = true;

  User? get currentUser => _currentUser;
  bool get isInitialized => _initialized;
  bool get rememberMe => _rememberMe;
  bool get isAdmin => _currentUser?.role == 'admin';
  bool get requiresPasswordChange => _currentUser?.mustChangePassword ?? false;

  /// Last cloud-provisioning failure (e.g. email confirmation required),
  /// or null once a cloud session exists. Surfaced via SyncService.blocker
  /// so a silent local sign-in can't hide why sync is dead.
  String? get provisionError => _provisionError;
  String? _provisionError;

  bool get _cloudReady =>
      (_supabase?.enabled ?? false) && (_connectivity?.isOnline ?? false);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _rememberMe = prefs.getBool(_rememberKey) ?? true;

    final id = prefs.getInt(_sessionKey);
    if (id != null) {
      final db = await _db.database;
      final result = await db.query('users', where: 'id = ?', whereArgs: [id]);
      if (result.isNotEmpty) {
        final user = User.fromMap(result.first);
        if (user.isActive) {
          _currentUser = user;
        } else {
          await prefs.remove(_sessionKey);
        }
      } else {
        // The account was deleted — drop the stale session id.
        await prefs.remove(_sessionKey);
      }
    }

    // Remote session may have been deactivated while the app was closed —
    // re-check the profile when we're online and still signed in.
    if (_currentUser != null && _cloudReady && _supabase!.isAuthed) {
      try {
        final profile = await _supabase.fetchProfile(_currentUser!.email);
        if (profile != null) {
          await _db.linkRemoteUser(
            _currentUser!.email,
            remoteId: profile['id'] as String?,
            role: profile['role'] as String?,
            isActive: profile['is_active'] as bool?,
            name: profile['name'] as String?,
          );
          if (profile['is_active'] == false) {
            await logout();
          } else {
            _currentUser = await _db.findUserByEmail(_currentUser!.email);
          }
        }
      } catch (_) {
        // Offline-ish failure — keep the local session.
      }
    }

    _initialized = true;
    notifyListeners();
  }

  Future<User> login(
    String email,
    String password, {
    bool rememberMe = true,
  }) async {
    final normalized = email.trim().toLowerCase();
    User? user;

    if (_cloudReady) {
      try {
        await _supabase!.signIn(normalized, password);
        final profile = await _supabase.fetchProfile(normalized);
        if (profile?['is_active'] == false) {
          await _supabase.signOut();
          throw StateError(
            'This account has been deactivated. Contact an admin.',
          );
        }
        user = await _db.findUserByEmail(normalized);
        if (user == null) {
          // First sign-in on this device — mirror the account locally so
          // it works offline too.
          user = await _db.registerUser(
            (profile?['name'] as String?)?.isNotEmpty == true
                ? profile!['name'] as String
                : normalized.split('@').first,
            normalized,
            password,
          );
        } else {
          // Keep the offline hash in step with the remote password.
          await _db.cacheLocalPassword(user.id!, password);
        }
        await _db.linkRemoteUser(
          normalized,
          remoteId: _supabase.currentUserId,
          role: profile?['role'] as String?,
          isActive: profile?['is_active'] as bool?,
          name: profile?['name'] as String?,
        );
        user = await _db.findUserByEmail(normalized);
        await _db.logActivity(user!.id, 'login', 'User signed in (cloud)');
      } on StateError {
        rethrow;
      } on AuthException {
        // Not a cloud account (created offline, or password differs) —
        // fall back to the local check, then provision in the background.
        user = await _tryLocalLogin(normalized, password);
        unawaited(_provision(user, password));
      } catch (_) {
        // Network/API failure despite connectivity — local fallback.
        user = await _tryLocalLogin(normalized, password);
      }
    } else {
      user = await _tryLocalLogin(normalized, password);
    }

    _currentUser = user;
    _rememberMe = rememberMe;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_rememberKey, rememberMe);
    if (rememberMe) {
      await prefs.setInt(_sessionKey, user.id!);
    } else {
      await prefs.remove(_sessionKey);
    }
    notifyListeners();
    return user;
  }

  Future<User> _tryLocalLogin(String email, String password) async {
    final user = await _db.login(email, password);
    if (user == null) {
      throw StateError('Invalid email or password.');
    }
    return user;
  }

  /// Creates the cloud copy of a local-only account after a successful
  /// local sign-in while online. Already-registered emails fall through to
  /// a plain sign-in attempt (succeeds when passwords match).
  Future<void> _provision(User user, String password) async {
    try {
      final id = await _supabase!.provisionIfMissing(
        user.email,
        password,
        user.name,
      );
      if (id != null) {
        await _db.linkRemoteUser(user.email, remoteId: id);
      }
      // signUp may succeed without a session (email confirmation enabled),
      // and 'already registered' returns null — either way, get a session.
      if (!_supabase.isAuthed) {
        await _supabase.signIn(user.email, password);
        await _db.linkRemoteUser(
          user.email,
          remoteId: _supabase.currentUserId,
        );
      }
      _provisionError = null;
      // A local admin's fresh server profile defaults to 'user' — push the
      // role so admin-only writes (dataset, log reads) pass RLS.
      if (user.role == 'admin' && _supabase.isAuthed) {
        await _supabase.pushRow('profiles', user.email, 'upsert', {
          'email': user.email,
          'name': user.name,
          'role': 'admin',
          'is_active': true,
          'updated_at': DateTime.now().toIso8601String(),
        });
      }
    } on AuthException catch (e) {
      final m = e.message.toLowerCase();
      _provisionError = m.contains('confirm')
          ? 'cloud account needs email confirmation — disable email '
              'confirmation in Supabase Auth settings, or confirm the email'
          : 'cloud sign-in failed: ${e.message}';
      debugPrint('Cloud provisioning failed: $e');
      notifyListeners();
    } catch (e) {
      _provisionError = 'cloud provisioning failed: $e';
      debugPrint('Cloud provisioning failed: $e');
      notifyListeners();
    }
  }

  Future<User> register(String name, String email, String password) async {
    final normalized = email.trim().toLowerCase();
    String? remoteId;
    if (_cloudReady) {
      try {
        remoteId = await _supabase!.signUp(normalized, password, name.trim());
      } on AuthException catch (e) {
        final m = e.message.toLowerCase();
        if (m.contains('already') || m.contains('registered')) {
          throw StateError('An account with this email already exists.');
        }
        // Other auth failures (weak password format, offline mid-request)
        // fall back to a local-only account — it provisions on next login.
      } catch (_) {}
    }

    final user = await _db.registerUser(name, normalized, password);
    if (remoteId != null) {
      await _db.linkRemoteUser(normalized, remoteId: remoteId);
    }
    _currentUser = user;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_sessionKey, user.id!);
    await prefs.setBool(_rememberKey, true);
    notifyListeners();
    return user;
  }

  Future<void> changePassword(String newPassword) async {
    final user = _currentUser;
    if (user == null) {
      throw StateError('Not signed in.');
    }
    await _db.changePassword(user.id!, newPassword);
    if (_cloudReady && _supabase!.isAuthed) {
      try {
        await _supabase.updateRemotePassword(newPassword);
      } catch (_) {
        // Local change stands; the remote password updates at next login.
      }
    }
    _currentUser = User(
      id: user.id,
      name: user.name,
      email: user.email,
      passwordHash: user.passwordHash,
      role: user.role,
      isActive: user.isActive,
      mustChangePassword: false,
      createdAt: user.createdAt,
    );
    notifyListeners();
  }

  Future<void> logout() async {
    if (_supabase?.enabled ?? false) await _supabase!.signOut();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionKey);
    _currentUser = null;
    notifyListeners();
  }
}
