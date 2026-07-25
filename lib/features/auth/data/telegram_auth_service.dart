
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/tdlib_service.dart';

// ── Provider ──────────────────────────────────────────────────────────────────

final telegramAuthServiceProvider = Provider<TelegramAuthService>((ref) {
  return TelegramAuthService();
});

// ── Result model ──────────────────────────────────────────────────────────────

class AuthResult {
  final bool success;
  final bool needsPassword;
  final String? phoneCodeHash; // kept for API compat, unused in TDLib path
  final String? sessionString; // kept for API compat
  final String? error;
  final Map<String, dynamic>? user;

  const AuthResult({
    required this.success,
    this.needsPassword = false,
    this.phoneCodeHash,
    this.sessionString,
    this.error,
    this.user,
  });
}

// ── Storage keys ───────────────────────────────────────────────────────────────

const _kSession      = 'tg_session';
const _kUserId       = 'tg_user_id';
const _kFirstName    = 'tg_first_name';
const _kLastName     = 'tg_last_name';
const _kPhone        = 'tg_phone';
const _kUsername     = 'tg_username';
const kNeedsDbResync = 'needs_db_resync';

// ── Service ───────────────────────────────────────────────────────────────────

class TelegramAuthService {

  // Hardware-encrypted storage for session token (Android Keystore)
  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
  );

  TdlibService get _tdlib => TdlibService.instance;

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  // ── Session helpers ──────────────────────────────────────────────────────────

  Future<void> _writeSession(String value) =>
      _secure.write(key: _kSession, value: value);

  Future<String> _readSession() async =>
      await _secure.read(key: _kSession) ?? '';

  Future<void> _deleteSession() => _secure.delete(key: _kSession);

  Future<void> _saveProfile(Map<String, dynamic> user) async {
    // Write session marker first — this is what isLoggedIn() checks
    await _writeSession('tdlib_active');

    final prefs = await _prefs;
    // user['id'] can be int from TDLib JSON
    final uid = (user['id'] ?? '').toString();
    final firstName = user['first_name'] as String? ?? '';
    final lastName  = user['last_name']  as String? ?? '';
    final phone     = user['phone_number'] as String? ?? '';
    final username  = (user['usernames'] as Map<String, dynamic>?)?['editable_username'] as String?
        ?? user['username'] as String? ?? '';

    await prefs.setString(_kUserId,    uid);
    await prefs.setString(_kFirstName, firstName);
    await prefs.setString(_kLastName,  lastName);
    await prefs.setString(_kPhone,     phone);
    await prefs.setString(_kUsername,  username);
  }

  // ── Public Auth API ───────────────────────────────────────────────────────────

  /// Step 1 — Send OTP to the phone via Telegram MTProto (direct, no server).
  Future<AuthResult> sendCode(String phone) async {
    try {
      final result = await _tdlib.sendCode(phone);
      if (!result.success) {
        return AuthResult(success: false, error: result.error);
      }
      return const AuthResult(success: true);
    } catch (e) {
      return AuthResult(success: false, error: _friendly(e));
    }
  }

  /// Step 2 — Verify the OTP received on Telegram.
  Future<AuthResult> verifyCode({
    required String phone,
    required String phoneCodeHash, // kept for API compat, not used by TDLib
    required String code,
    String partialSession = '',    // kept for API compat, not used by TDLib
  }) async {
    try {
      final result = await _tdlib.verifyCode(code);
      if (!result.success) {
        return AuthResult(success: false, error: result.error);
      }
      if (result.needsPassword) {
        return const AuthResult(success: true, needsPassword: true);
      }
      if (result.user != null) {
        await _saveProfile(result.user!);
      }
      return AuthResult(success: true, user: result.user);
    } catch (e) {
      return AuthResult(success: false, error: _friendly(e));
    }
  }

  /// Step 3 (optional) — Complete 2FA with cloud password.
  Future<AuthResult> verifyPassword(String password) async {
    try {
      final result = await _tdlib.verifyPassword(password);
      if (!result.success) {
        return AuthResult(success: false, error: result.error);
      }
      if (result.user != null) {
        await _saveProfile(result.user!);
      }
      return AuthResult(success: true, user: result.user);
    } catch (e) {
      return AuthResult(success: false, error: _friendly(e));
    }
  }

  /// Check whether user has a stored session (fast, no network).
  Future<bool> isLoggedIn() async {
    final session = await _readSession();
    return session.isNotEmpty; // 'tdlib_active' = logged in
  }

  /// Clear session if it turns out to be stale (TDLib reported not authorized).
  Future<void> clearStaleSession() async {
    await _deleteSession();
  }

  /// Save profile when TDLib confirms authorization (called after verifyCode).
  Future<void> saveProfileFromTdlib() async {
    try {
      final me = await _tdlib.getMe();
      await _saveProfile(me);
    } catch (_) {
      // Fallback: at least write the session marker
      await _writeSession('tdlib_active');
    }
  }

  /// Return stored profile info (no network call).
  Future<Map<String, String>> getProfile() async {
    final prefs = await _prefs;
    return {
      'userId':    prefs.getString(_kUserId)    ?? '',
      'firstName': prefs.getString(_kFirstName) ?? '',
      'lastName':  prefs.getString(_kLastName)  ?? '',
      'phone':     prefs.getString(_kPhone)     ?? '',
      'username':  prefs.getString(_kUsername)  ?? '',
    };
  }

  /// Returns a non-empty string when logged in (used by storage service checks).
  Future<String> getSession() => _readSession();

  /// Sign out: log out from Telegram and clear all local state.
  Future<void> logout() async {
    try {
      await _tdlib.logout();
    } catch (_) {}

    await _deleteSession();

    final prefs = await _prefs;
    await prefs.setBool(kNeedsDbResync, true);
    await prefs.remove(_kUserId);
    await prefs.remove(_kFirstName);
    await prefs.remove(_kLastName);
    await prefs.remove(_kPhone);
    await prefs.remove(_kUsername);
  }

  /// Returns true if a full DB re-sync is required (set after logout).
  Future<bool> needsDbResync() async {
    final prefs = await _prefs;
    return prefs.getBool(kNeedsDbResync) ?? false;
  }

  /// Clear the resync flag once sync completes.
  Future<void> clearResyncFlag() async {
    final prefs = await _prefs;
    await prefs.remove(kNeedsDbResync);
  }

  // ── Error helper ─────────────────────────────────────────────────────────────

  String _friendly(Object e) {
    final msg = e.toString().replaceFirst('Exception: ', '');
    if (msg.contains('PHONE_NUMBER_INVALID')) {
      return 'Invalid phone number. Include country code (e.g. +91...).';
    }
    if (msg.contains('PHONE_CODE_INVALID')) {
      return 'Invalid verification code. Check Telegram and try again.';
    }
    if (msg.contains('PHONE_CODE_EXPIRED')) {
      return 'Code expired. Tap \'Resend\' to get a new one.';
    }
    if (msg.contains('PASSWORD_HASH_INVALID')) {
      return 'Wrong 2FA password. Try again.';
    }
    if (msg.contains('FLOOD_WAIT')) {
      return 'Too many attempts. Please wait a few minutes and try again.';
    }
    if (msg.contains('still initializing') || msg.contains('not initialized')) {
      return 'Telegram is still connecting. Please wait a moment and try again.';
    }
    if (msg.contains('Timed out waiting') || msg.contains('Timeout')) {
      return 'Connecting to Telegram timed out. Check your internet and try again.';
    }
    if (msg.contains('SocketException') || msg.contains('Connection')) {
      return 'No internet connection. Check your network and try again.';
    }
    if (msg.contains('TDLib closed')) {
      return 'Telegram connection was reset. Please restart the app.';
    }
    return msg;
  }
}
