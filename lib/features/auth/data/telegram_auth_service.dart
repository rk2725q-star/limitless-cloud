import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/constants/app_constants.dart';

// ── Provider ─────────────────────────────────────────────────────────────────

final telegramAuthServiceProvider = Provider<TelegramAuthService>((ref) {
  return TelegramAuthService();
});

// ── Result model ─────────────────────────────────────────────────────────────

class AuthResult {
  final bool success;
  final bool needsPassword;
  final String? phoneCodeHash;
  final String? sessionString;
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

// ── Storage keys ──────────────────────────────────────────────────────────────

const _kSession    = 'tg_session';
const _kUserId     = 'tg_user_id';
const _kFirstName  = 'tg_first_name';
const _kLastName   = 'tg_last_name';
const _kPhone      = 'tg_phone';
const _kUsername   = 'tg_username';
const kServerUrl   = 'server_url'; // public so Settings can write it

// ── Service ───────────────────────────────────────────────────────────────────

class TelegramAuthService {

  // Read the URL from SharedPreferences every call so Settings changes apply
  // immediately without restarting the app.
  Future<String> get _base async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(kServerUrl) ?? '';
    return saved.isNotEmpty ? saved : AppConstants.backendBaseUrl;
  }

  // ── HTTP helpers ────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final base = await _base;
    final uri = Uri.parse('$base$path');
    try {
      final resp = await http
          .post(uri, headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 30));
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (resp.statusCode >= 400) {
        throw Exception(data['detail'] ?? 'Server error ${resp.statusCode}');
      }
      return data;
    } on Exception catch (e) {
      // Convert timeout / connection refused into a friendly message
      final msg = e.toString();
      if (msg.contains('TimeoutException') || msg.contains('SocketException') ||
          msg.contains('Connection refused') || msg.contains('Network')) {
        throw Exception(
          '❌ Cannot reach server.\n\n'
          'The cloud server is temporarily unavailable.\n'
          'Please check your internet connection and try again.\n\n'
          'Server URL: $base',
        );
      }
      rethrow;
    }
  }

  // ── SharedPreferences helpers ───────────────────────────────────────────────

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<void> _saveSession(Map<String, dynamic> data) async {
    final prefs = await _prefs;
    await prefs.setString(_kSession,   data['session_string'] ?? '');
    await prefs.setString(_kUserId,    (data['user_id'] ?? '').toString());
    await prefs.setString(_kFirstName, data['first_name'] ?? '');
    await prefs.setString(_kLastName,  data['last_name']  ?? '');
    await prefs.setString(_kPhone,     data['phone']      ?? '');
    await prefs.setString(_kUsername,  data['username']   ?? '');
  }

  // Save / load server URL
  static Future<void> saveServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kServerUrl, url.trimRight().replaceAll(RegExp(r'/$'), ''));
  }

  static Future<String> loadServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(kServerUrl) ?? '';
  }

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Step 1 – Send OTP to the phone via Telegram.
  Future<AuthResult> sendCode(String phone) async {
    try {
      final data = await _post('/auth/send-code', {'phone': phone});
      return AuthResult(
        success: true,
        phoneCodeHash: data['phone_code_hash'],
        sessionString: data['session_string'],
      );
    } catch (e) {
      return AuthResult(success: false, error: e.toString());
    }
  }

  /// Step 2 – Verify the OTP received on Telegram.
  Future<AuthResult> verifyCode({
    required String phone,
    required String phoneCodeHash,
    required String code,
    String partialSession = '',
  }) async {
    try {
      final data = await _post('/auth/verify-code', {
        'phone': phone,
        'phone_code_hash': phoneCodeHash,
        'code': code,
        'session_string': partialSession, // ← CRITICAL: reuse DC from send-code
      });


      if (data['needs_password'] == true) {
        final prefs = await _prefs;
        await prefs.setString(_kSession, data['session_string'] ?? '');
        return AuthResult(
          success: true,
          needsPassword: true,
          sessionString: data['session_string'],
        );
      }

      await _saveSession(data);
      return AuthResult(
        success: true,
        sessionString: data['session_string'],
        user: data,
      );
    } catch (e) {
      return AuthResult(success: false, error: e.toString());
    }
  }

  /// Step 3 (optional) – Complete 2FA with cloud password.
  Future<AuthResult> verifyPassword(String password) async {
    try {
      final prefs = await _prefs;
      final session = prefs.getString(_kSession) ?? '';
      final data = await _post('/auth/verify-2fa', {
        'session_string': session,
        'password': password,
      });
      await _saveSession(data);
      return AuthResult(
        success: true,
        sessionString: data['session_string'],
        user: data,
      );
    } catch (e) {
      return AuthResult(success: false, error: e.toString());
    }
  }

  /// Check whether the locally stored session is still valid on Telegram.
  Future<bool> isLoggedIn() async {
    final prefs = await _prefs;
    final session = prefs.getString(_kSession) ?? '';
    if (session.isEmpty) return false;
    try {
      final data = await _post('/auth/check-session', {'session_string': session});
      return data['valid'] == true;
    } catch (_) {
      return false;
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

  /// Return the stored session string.
  Future<String> getSession() async {
    final prefs = await _prefs;
    return prefs.getString(_kSession) ?? '';
  }

  /// Sign out: revoke session on Telegram and clear local storage.
  Future<void> logout() async {
    try {
      final prefs = await _prefs;
      final session = prefs.getString(_kSession) ?? '';
      if (session.isNotEmpty) {
        await _post('/auth/logout', {'session_string': session});
      }
    } catch (_) {}
    final prefs = await _prefs;
    await prefs.remove(_kSession);
    await prefs.remove(_kUserId);
    await prefs.remove(_kFirstName);
    await prefs.remove(_kLastName);
    await prefs.remove(_kPhone);
    await prefs.remove(_kUsername);
  }
}
