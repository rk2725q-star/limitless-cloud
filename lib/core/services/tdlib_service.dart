import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:handy_tdlib/handy_tdlib.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Callbacks ──────────────────────────────────────────────────────────────────
typedef ProgressCallback = void Function(double progress);

// ── Upload result ─────────────────────────────────────────────────────────────
class TdUploadResult {
  final int primaryMessageId;
  final List<int> allMessageIds;
  bool get isChunked => allMessageIds.length > 1;
  const TdUploadResult(
      {required this.primaryMessageId, required this.allMessageIds});
}

// ── Saved message info ────────────────────────────────────────────────────────
class TdSavedMessage {
  final int messageId;
  final String caption;
  final String? fileName;
  final int fileSize;
  final String mimeType;
  final DateTime date;
  final int? thumbnailId;

  const TdSavedMessage({
    required this.messageId,
    required this.caption,
    this.fileName,
    this.fileSize = 0,
    this.mimeType = 'application/octet-stream',
    required this.date,
    this.thumbnailId,
  });
}

// ── Auth result ───────────────────────────────────────────────────────────────
class TdAuthResult {
  final bool success;
  final bool needsPassword;
  final String? error;
  final Map<String, dynamic>? user;
  const TdAuthResult({
    required this.success,
    this.needsPassword = false,
    this.error,
    this.user,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
//  Constants
// ─────────────────────────────────────────────────────────────────────────────

/// Chunk threshold for files exceeding Telegram's single-file upload limit.
/// Telegram natively supports single file uploads up to 2000 MB (2 GB).
/// Files <= 2000 MB upload as a single high-speed message directly via TDLib
/// priority-32 MTProto pipeline, saturating 5G/5G++ network bandwidth without
/// creating intermediate chunk files or cluttering channels.
/// Files > 2000 MB are split into 1000 MB chunks.
const int _kChunkThreshold = 2000 * 1024 * 1024; // 2000 MB (2 GB)
const int _kTargetChunkSize = 1000 * 1024 * 1024; // 1000 MB (1 GB) per chunk

// ── NEW clean caption markers (human-readable in Telegram) ─────────────────
// Format: multi-line, emoji-prefixed, easy to read by anyone browsing Saved Messages.
// Example:
//   ☁️ Report.pdf
//   📂 /Work/Reports
//   🆔 abc123folderId
const _lcFileMarker   = '☁️ ';          // line 0: ☁️ {filename}
const _lcPathMarker   = '\n📂 ';         // line 1: 📂 {folderPath}
const _lcIdMarker     = '\n🆔 ';         // line 2: 🆔 {folderId}  (optional)
const _lcChunkMarker  = ' (part ';       // inside line 0 for chunks: ☁️ file.zip (part 2/5)

// ── LEGACY markers — kept only for backward-compat parsing ────────────────
// Existing files in Telegram already have these captions. We still parse them
// on sync so no data is ever lost. New uploads use the clean format above.
const _folderPrefix   = 'LIMITLESS_FOLDER:';
const _fileMetaPrefix = 'LIMITLESS_FILE:';
const _chunkPrefix    = 'LIMITLESS_CHUNK:';

const int _kApiId = 36148181;
const String _kApiHash = 'cf8e8509b0ceaf5b229ad47f59b79e6e';

// ─────────────────────────────────────────────────────────────────────────────
//  TdlibService  — singleton
// ─────────────────────────────────────────────────────────────────────────────

class TdlibService {
  TdlibService._();
  static final TdlibService instance = TdlibService._();

  late int _clientId;
  bool _initialized = false;

  // Poll timer — replaces the isolate approach (isolates don't share TdPlugin.instance)
  Timer? _pollTimer;

  // Pending invocations: extra → completer
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  int _nextExtra = 1;

  // Broadcast stream for update events
  final _updateCtrl = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get updates => _updateCtrl.stream;

  // Auth state tracking
  String _authState = '';
  String get authState => _authState;
  bool get isInitialized => _initialized;
  bool get isReady => _initialized && _authState == 'authorizationStateReady';

  // Initialization error
  String? initError;

  // ── Initialize ──────────────────────────────────────────────────────────────

  Future<void> initialize({required String dbPath}) async {
    if (_initialized) return;

    // Load native libtdjson.so
    await TdPlugin.initialize();

    _clientId = TdPlugin.instance.tdCreateClientId();
    _initialized = true;

    // Start polling loop — every 5ms checks for new TDLib messages.
    // Loop drains up to 200 updates per tick to eliminate MTProto queue backpressure.
    _pollTimer = Timer.periodic(const Duration(milliseconds: 5), (_) {
      _poll();
    });

    // Subscribe to auth state changes internally
    updates.listen((upd) {
      if (upd['@type'] == 'error') {
        debugPrint('[TDLib Core Error] ${upd['message']}');
        // Only treat as fatal init error if TDLib is in a closed/dead state
        if (_authState == 'authorizationStateClosed') {
          initError = 'TDLib Error: ${upd['message']}';
        }
        return;
      }

      if (upd['@type'] == 'updateAuthorizationState') {
        final state = upd['authorization_state'] as Map<String, dynamic>?;
        final type = state?['@type'] as String? ?? '';
        _authState = type;
        // Any progressing auth state indicates TDLib core is running successfully
        initError = null;
        
        // Respond to encryption key request automatically
        if (type == 'authorizationStateWaitEncryptionKey') {
          _fireAndForget({
            '@type': 'checkDatabaseEncryptionKey',
            'encryption_key': '',
          });
        }

        if (type == 'authorizationStateReady') {
          // Pre-resolve storage chat ID in background so uploads/downloads start with zero delay
          getStorageChatId().catchError((_) => 0);
          _fireAndForget({
            '@type': 'setOption',
            'name': 'online',
            'value': {'@type': 'optionValueBoolean', 'value': true},
          });
        }
      }
    });

    // Send parameters unconditionally — fire and forget
    _fireAndForget({
      '@type': 'setTdlibParameters',
      'use_test_dc': false,
      'database_directory': dbPath,
      'files_directory': '$dbPath/files',
      'database_encryption_key': '',
      'use_file_database': true,
      'use_chat_info_database': true,
      'use_message_database': true,
      'use_secret_chats': false,
      'api_id': _kApiId,
      'api_hash': _kApiHash,
      'system_language_code': 'en',
      'device_model': 'Android',
      'system_version': 'Android',
      'application_version': '1.0',
      'enable_storage_optimizer': true,
    });

    _setPerformanceOptions();
    _listenConnectivity();
  }

  // ── TDLib Performance & Network Tuning ─────────────────────────────────────

  void _setPerformanceOptions() {
    // Standard valid TDLib network & performance options:
    _fireAndForget({
      '@type': 'setOption',
      'name': 'prefer_ipv6',
      'value': {'@type': 'optionValueBoolean', 'value': true},
    });

    _fireAndForget({
      '@type': 'setOption',
      'name': 'ignore_background_updates',
      'value': {'@type': 'optionValueBoolean', 'value': false},
    });
  }

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  void _listenConnectivity() {
    _connectivitySub?.cancel();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      updateNetworkType(results: results);
    });
    updateNetworkType();
  }

  /// Inform TDLib about active network type so it scales connection pools and limits
  Future<void> updateNetworkType({List<ConnectivityResult>? results}) async {
    try {
      final list = results ?? await Connectivity().checkConnectivity();
      final hasWifi = list.contains(ConnectivityResult.wifi);
      final hasMobile = list.contains(ConnectivityResult.mobile);
      final hasEthernet = list.contains(ConnectivityResult.ethernet);
      final isNone = list.isEmpty || list.contains(ConnectivityResult.none);

      String netType;
      if (isNone && !hasWifi && !hasMobile && !hasEthernet) {
        netType = 'networkTypeNone';
      } else {
        // Report networkTypeWiFi whenever online so TDLib unlocks unthrottled desktop/Wi-Fi
        // socket buffer sizes and TCP windows even on 5G/LTE connections.
        netType = 'networkTypeWiFi';
      }

      _fireAndForget({
        '@type': 'setNetworkType',
        'type': {'@type': netType},
      });
    } catch (_) {}
  }

  // ── Poll loop (high throughput, non-blocking) ──────────────────────────────

  bool _isPolling = false;

  void _poll() {
    if (_isPolling) return;
    _isPolling = true;
    try {
      int count = 0;
      // Drain up to 200 events per cycle to prevent actor queue backup
      while (count < 200) {
        String? raw;
        try {
          raw = TdPlugin.instance.tdReceive(0);
        } catch (_) {
          break;
        }
        if (raw == null) break;
        count++;

        try {
          final msg = jsonDecode(raw) as Map<String, dynamic>;
          _route(msg);
        } catch (_) {}
      }
      // If there are still more events queued, drain in next microtask immediately
      if (count >= 200) {
        scheduleMicrotask(_poll);
      }
    } finally {
      _isPolling = false;
    }
  }

  // ── Route messages ──────────────────────────────────────────────────────────

  void _route(Map<String, dynamic> msg) {
    final extra = msg['@extra'];
    if (extra != null) {
      final id = extra is int ? extra : int.tryParse(extra.toString()) ?? -1;
      final completer = _pending.remove(id);
      if (completer != null && !completer.isCompleted) {
        if (msg['@type'] == 'error') {
          completer.completeError(
            Exception(msg['message'] ?? 'TDLib error ${msg['code']}'),
          );
        } else {
          completer.complete(msg);
        }
        return;
      }
    }
    // Broadcast as update
    if (!_updateCtrl.isClosed) _updateCtrl.add(msg);
  }

  // ── Send with response (awaitable) ─────────────────────────────────────────

  Future<Map<String, dynamic>> _send(Map<String, dynamic> fn,
      {Duration timeout = const Duration(seconds: 60)}) async {
    if (!_initialized) throw Exception('TDLib not initialized');
    final extra = _nextExtra++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[extra] = completer;

    final json = jsonEncode({...fn, '@extra': extra});
    TdPlugin.instance.tdSend(_clientId, json);

    return completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(extra);
      throw Exception('TDLib timeout: ${fn['@type']}');
    });
  }

  // ── Fire and forget (no response expected) ──────────────────────────────────

  void _fireAndForget(Map<String, dynamic> fn) {
    if (!_initialized) return;
    final json = jsonEncode(fn);
    TdPlugin.instance.tdSend(_clientId, json);
  }

  // ── Wait for auth state ─────────────────────────────────────────────────────
  // Waits until the current auth state matches [expectedState].
  // Also terminates early on terminal error/closed states so we don't
  // hang the UI forever.

  Future<void> _waitForAuthState(String expectedState,
      {Duration timeout = const Duration(seconds: 60)}) async {
    // Already in the target state — nothing to do.
    if (_authState == expectedState) return;

    // If TDLib hasn't initialized yet, give it up to [timeout] to start.
    // We poll the _authState string which is updated by the listener above.
    final deadline = DateTime.now().add(timeout);
    while (_authState != expectedState) {
      if (DateTime.now().isAfter(deadline)) {
        throw Exception(
            'Timed out waiting for TDLib auth state: $expectedState (current: $_authState)');
      }
      // Terminal states — don't wait forever
      if (_authState == 'authorizationStateClosed' ||
          _authState == 'authorizationStateClosing') {
        throw Exception('TDLib closed while waiting for: $expectedState');
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  // ── Get own user ID ─────────────────────────────────────────────────────────

  Future<int> _getMyId() async {
    final me = await _send({'@type': 'getMe'});
    return me['id'] as int;
  }

  int? _savedMessagesChatId;

  Future<int> _getSavedMessagesChatId() async {
    if (_savedMessagesChatId != null) return _savedMessagesChatId!;
    final myId = await _getMyId();
    final chat = await _send({
      '@type': 'createPrivateChat',
      'user_id': myId,
      'force': false,
    });
    _savedMessagesChatId = chat['id'] as int;
    return _savedMessagesChatId!;
  }

  /// Public accessor for legacy Saved Messages chat ID
  Future<int> getSavedMessagesChatId() => _getSavedMessagesChatId();

  static const String _kStorageChannelTitle = '☁️ Limitless Cloud Storage';

  /// Get user's personal Saved Messages chat ID for Limitless Cloud.
  /// Direct storage in Saved Messages ensures files are immediately accessible,
  /// visible as a single clean file in Telegram, and never lost in separate channels.
  Future<int> getStorageChatId() async {
    return _getSavedMessagesChatId();
  }

  /// Backward-compatible accessor for older private channel if one was previously created.
  Future<int> getLegacyChannelId() => _resolveStorageChatId();

  Future<int> _resolveStorageChatId() async {
    int? myId;
    try {
      myId = await _getMyId();
    } catch (_) {}

    final prefKey = myId != null
        ? 'telegram_storage_channel_id_$myId'
        : 'telegram_storage_channel_id';

    // 1. Check SharedPreferences cache
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedId = prefs.getInt(prefKey);
      if (cachedId != null) {
        try {
          final chat = await _send({'@type': 'getChat', 'chat_id': cachedId},
              timeout: const Duration(seconds: 5));
          if (chat['@type'] == 'chat') {
            return cachedId;
          }
        } catch (_) {
          await prefs.remove(prefKey);
        }
      }
    } catch (_) {}

    // 2. Search for existing channel titled 'Limitless Cloud Storage'
    try {
      final searchResp = await _send({
        '@type': 'searchChats',
        'query': 'Limitless Cloud Storage',
        'limit': 10,
      }, timeout: const Duration(seconds: 10));
      final chatIds = (searchResp['chat_ids'] as List?)?.cast<int>() ?? [];
      for (final cid in chatIds) {
        try {
          final chat = await _send({'@type': 'getChat', 'chat_id': cid},
              timeout: const Duration(seconds: 5));
          final title = (chat['title'] as String?) ?? '';
          if (title.contains('Limitless Cloud Storage')) {
            try {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setInt(prefKey, cid);
            } catch (_) {}
            return cid;
          }
        } catch (_) {}
      }
    } catch (_) {}

    // 3. Create new private supergroup channel for Limitless Cloud
    try {
      final newChat = await _send({
        '@type': 'createNewSupergroupChat',
        'title': _kStorageChannelTitle,
        'is_channel': true,
        'description':
            'Private cloud storage channel for Limitless Cloud. High-speed encrypted storage for your files. Do not delete.',
        'for_import': false,
      }, timeout: const Duration(seconds: 25));
      final cid = newChat['id'] as int;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(prefKey, cid);
      } catch (_) {}
      return cid;
    } catch (_) {
      // 4. Graceful fallback: return user's personal Saved Messages
      return _getSavedMessagesChatId();
    }
  }

  // ════════════════════════════════════════════════════════════════════════════
  // AUTH API
  // ════════════════════════════════════════════════════════════════════════════

  /// Step 1: Send OTP.
  ///
  /// Strategy:
  ///  1. If TDLib is already in [authorizationStateWaitCode], resend instead.
  ///  2. If TDLib is in [authorizationStateReady] (stale re-auth attempt),
  ///     call logOut first so TDLib goes back to WaitPhoneNumber.
  ///  3. Otherwise wait up to 60 s for [authorizationStateWaitPhoneNumber].
  ///     During startup TDLib may still be negotiating encryption key, so we
  ///     give it plenty of time before giving up.
  Future<TdAuthResult> sendCode(String phone) async {
    try {
      // Ensure TDLib is initialized before touching auth state
      if (!_initialized) {
        throw Exception('TDLib is still initializing. Please wait a moment and try again.');
      }

      // Already waiting for code — resend to same number
      if (_authState == 'authorizationStateWaitCode') {
        return resendCode();
      }

      // If somehow already authorized (e.g. app relaunched), log out first
      // so we go back to the phone-number step.
      if (_authState == 'authorizationStateReady') {
        _fireAndForget({'@type': 'logOut'});
        // Wait for TDLib to reach WaitPhoneNumber after logout
      }

      // Wait for TDLib to reach WaitPhoneNumber
      await _waitForAuthState('authorizationStateWaitPhoneNumber',
          timeout: const Duration(seconds: 10));

      await _send({
        '@type': 'setAuthenticationPhoneNumber',
        'phone_number': phone,
        'settings': {
          '@type': 'phoneNumberAuthenticationSettings',
          'allow_flash_call': false,
          'allow_missed_call': false,
          'is_current_phone_number': false,
          'has_unknown_phone_number': false,
          'allow_sms_retriever_api': false,
          'authentication_tokens': [],
        },
      });
      return const TdAuthResult(success: true);
    } catch (e) {
      return TdAuthResult(success: false, error: _clean(e));
    }
  }

  /// Resend OTP — use when already in authorizationStateWaitCode
  Future<TdAuthResult> resendCode() async {
    try {
      await _send({'@type': 'resendAuthenticationCode'});
      return const TdAuthResult(success: true);
    } catch (e) {
      return TdAuthResult(success: false, error: _clean(e));
    }
  }

  /// Step 2: Verify OTP.
  ///
  /// After checkAuthenticationCode TDLib will transition to either:
  ///   • authorizationStateWaitPassword  → 2FA required
  ///   • authorizationStateReady         → fully logged in
  ///
  /// We must wait for the async state update rather than checking _authState
  /// immediately after the send(), because the poll loop processes the
  /// state update on the next timer tick (≤ 10 ms later).
  Future<TdAuthResult> verifyCode(String code) async {
    try {
      // Send the code — TDLib will respond with 'ok' and then emit
      // updateAuthorizationState asynchronously.
      await _send({'@type': 'checkAuthenticationCode', 'code': code});

      // Wait for TDLib to settle into its next state (up to 15 s).
      await _waitForNextAuthState(
        from: 'authorizationStateWaitCode',
        timeout: const Duration(seconds: 15),
      );

      if (_authState == 'authorizationStateWaitPassword') {
        return const TdAuthResult(success: true, needsPassword: true);
      }

      if (_authState == 'authorizationStateReady') {
        final me = await _send({'@type': 'getMe'});
        return TdAuthResult(success: true, user: me);
      }

      // Any other state is unexpected
      return TdAuthResult(
          success: false,
          error: 'Unexpected auth state after code: $_authState');
    } catch (e) {
      return TdAuthResult(success: false, error: _clean(e));
    }
  }

  /// Step 3 (optional): 2FA password
  Future<TdAuthResult> verifyPassword(String password) async {
    try {
      await _send({
        '@type': 'checkAuthenticationPassword',
        'password': password,
      });

      // Wait for TDLib to reach Ready state
      await _waitForAuthState('authorizationStateReady',
          timeout: const Duration(seconds: 30));

      final me = await _send({'@type': 'getMe'});
      return TdAuthResult(success: true, user: me);
    } catch (e) {
      return TdAuthResult(success: false, error: _clean(e));
    }
  }

  /// Waits until _authState changes away from [from] (or until timeout).
  /// Used after sending a code to wait for the next auth state without
  /// needing to know exactly what it will be.
  Future<void> _waitForNextAuthState(
      {required String from,
      Duration timeout = const Duration(seconds: 15)}) async {
    final deadline = DateTime.now().add(timeout);
    while (_authState == from) {
      if (DateTime.now().isAfter(deadline)) {
        throw Exception(
            'Timed out waiting for auth state to change from: $from');
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Check if currently authorized
  Future<bool> isAuthorized() async {
    try {
      await _send({'@type': 'getMe'}, timeout: const Duration(seconds: 5));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Get profile
  Future<Map<String, dynamic>> getMe() => _send({'@type': 'getMe'});

  /// Public raw TDLib send — for use by services that don't live inside
  /// TdlibService itself (e.g. ShareService) but need to call TDLib directly.
  Future<Map<String, dynamic>> sendRaw(
    Map<String, dynamic> fn, {
    Duration timeout = const Duration(seconds: 60),
  }) => _send(fn, timeout: timeout);

  /// Log out
  Future<void> logout() async {
    try {
      _savedMessagesChatId = null;
      try {
        final prefs = await SharedPreferences.getInstance();
        final keys = prefs
            .getKeys()
            .where((k) => k.startsWith('telegram_storage_channel_id'))
            .toList();
        for (final k in keys) {
          await prefs.remove(k);
        }
      } catch (_) {}
      await _send({'@type': 'logOut'}, timeout: const Duration(seconds: 10));
    } catch (_) {}
  }

  // ════════════════════════════════════════════════════════════════════════════
  // UPLOAD API
  // ════════════════════════════════════════════════════════════════════════════

  static int getChunkThreshold() => _kChunkThreshold;

  /// Optimal chunk size for parallel multi-stream uploads.
  static int calculateOptimalChunkBytes(int fileSize) {
    if (fileSize <= _kChunkThreshold) return fileSize;
    final numChunks = (fileSize / _kTargetChunkSize).ceil();
    return (fileSize / numChunks).ceil();
  }

  /// Total chunks for given file size (1 for files <= 25 MB).
  static int calculateTotalChunks(int fileSize) {
    if (fileSize <= _kChunkThreshold) return 1;
    final numChunks = (fileSize / _kTargetChunkSize).ceil();
    return numChunks;
  }

  Future<TdUploadResult> uploadFile(
    io.File file, {
    ProgressCallback? onProgress,
    String? folderId,
    String folderPath = '/',
    int? chatId,
  }) async {
    final fileName = p.basename(file.path);
    final fileSize = await file.length();
    onProgress?.call(0.0);

    final targetChatId = chatId ?? await getStorageChatId();

    // Files <= 2000 MB (photos, docs, videos up to 2 GB) upload as a single message.
    if (fileSize <= _kChunkThreshold) {
      final caption = _buildFileCaption(
          fileName: fileName, folderId: folderId, folderPath: folderPath);
      final msgId = await _uploadSingleFile(
        localPath: file.path,
        caption: caption,
        onProgress: onProgress,
        chatId: targetChatId,
      );
      onProgress?.call(1.0);
      return TdUploadResult(primaryMessageId: msgId, allMessageIds: []);
    } else {
      final numChunks = (fileSize / _kTargetChunkSize).ceil();
      final chunkBytes = (fileSize / numChunks).ceil();
      final msgIds = List<int?>.filled(numChunks, null);
      final tmpDir = await getTemporaryDirectory();
      final taskId = DateTime.now().millisecondsSinceEpoch;
      final chunkDir = io.Directory('${tmpDir.path}/chunks_$taskId');
      if (!await chunkDir.exists()) await chunkDir.create(recursive: true);
      final chunkProgress = List<double>.filled(numChunks, 0.0);

      // Chunks are ~1000 MB (1 GB) each for files > 2 GB.
      // 2 parallel workers prevent mobile disk I/O thrashing while keeping high throughput.
      const maxParallel = 2;
      int nextChunkIdx = 0;
      final workers = <Future<void>>[];

      try {
        for (int w = 0; w < min(maxParallel, numChunks); w++) {
          if (w > 0) await Future.delayed(const Duration(milliseconds: 150));
          workers.add(() async {
            while (true) {
              final j = nextChunkIdx++;
              if (j >= numChunks) break;

              final offset = j * chunkBytes;
              final partLen = min(chunkBytes, fileSize - offset);
              final baseWithoutExt = p.withoutExtension(fileName);
              final ext = p.extension(fileName);
              final partFileName =
                  '$baseWithoutExt.part${j + 1}of$numChunks$ext';
              final tmpPath = p.join(chunkDir.path, partFileName);
              final tmpFile = io.File(tmpPath);

              try {
                // 1. Buffer streaming to temp part file
                final sink = tmpFile.openWrite();
                await sink.addStream(file.openRead(offset, offset + partLen));
                await sink.flush();
                await sink.close();

                final caption = _buildChunkCaption(
                  fileName: fileName,
                  partIndex: j,
                  totalParts: numChunks,
                  folderId: folderId,
                  folderPath: folderPath,
                );

                // 2. Upload with priority 32 + per-chunk auto-retry
                int retry = 0;
                while (true) {
                  try {
                    final msgId = await _uploadSingleFile(
                      localPath: tmpPath,
                      caption: caption,
                      onProgress: (prog) {
                        chunkProgress[j] = prog;
                        final totalProg =
                            chunkProgress.reduce((a, b) => a + b) / numChunks;
                        onProgress?.call(totalProg.clamp(0.0, 1.0));
                      },
                      fileName: partFileName,
                      chatId: targetChatId,
                    );
                    msgIds[j] = msgId;
                    break;
                  } catch (e) {
                    retry++;
                    if (retry > 2) rethrow;
                    await Future.delayed(Duration(seconds: retry * 2));
                  }
                }
              } finally {
                // 3. Immediate cleanup of part file to save disk space
                try {
                  if (await tmpFile.exists()) {
                    await tmpFile.delete();
                  }
                } catch (_) {}
              }
            }
          }());
        }
        await Future.wait(workers);
      } finally {
        try {
          if (await chunkDir.exists()) {
            await chunkDir.delete(recursive: true);
          }
        } catch (_) {}
      }

      onProgress?.call(1.0);
      final finalMsgIds = msgIds.whereType<int>().toList();
      return TdUploadResult(
          primaryMessageId: finalMsgIds.first, allMessageIds: finalMsgIds);
    }
  }

  Future<int> _uploadSingleFile({
    required String localPath,
    required String caption,
    ProgressCallback? onProgress,
    String? fileName,
    int? chatId,
  }) async {
    final targetChatId = chatId ?? await getStorageChatId();

    final file = io.File(localPath);
    if (!await file.exists()) {
      throw Exception('File does not exist: $localPath');
    }
    final fileSize = await file.length();

    // Fake animated progress for tiny files (<2 MB) where TDLib may finish
    // before the first updateFile event arrives.
    final isSmall = fileSize < 2 * 1024 * 1024;
    double fakePct = 0.0;
    Timer? fakeTimer;
    if (isSmall && onProgress != null) {
      final double mb = fileSize / (1024 * 1024);
      final double step = 0.05 + (0.05 * (1.0 - (mb / 2.0)).clamp(0.0, 1.0));
      final int intervalMs = 40 + (40 * (mb / 2.0)).round();
      fakePct = step;
      onProgress(fakePct);
      fakeTimer = Timer.periodic(Duration(milliseconds: intervalMs), (t) {
        if (fakePct < 0.85) {
          fakePct += step;
          onProgress(fakePct.clamp(0.0, 0.85));
        } else {
          t.cancel();
        }
      });
    } else {
      onProgress?.call(0.0);
    }

    final completer = Completer<int>();
    int? expectedTempId;
    int? trackedTdFileId;
    final recentSucceeded = <int, int>{}; // oldId -> realId
    final recentFailed = <int, String>{}; // oldId -> errorMsg

    double lastReportedPct = -1.0;
    int lastReportTime = 0;

    final sub = updates.listen((upd) {
      final type = upd['@type'] as String?;

      // ── Upload progress via updateFile ────────────────────────────────────
      if (type == 'updateFile') {
        final fileMap = upd['file'] as Map<String, dynamic>?;
        if (fileMap == null) return;
        final tdId = fileMap['id'] as int?;
        if (tdId == null || tdId == 0) return;

        // If not yet locked to a tdId, adopt the first actively uploading file
        if (trackedTdFileId == null) {
          final remote = fileMap['remote'] as Map<String, dynamic>?;
          if (remote != null && remote['is_uploading_active'] == true) {
            trackedTdFileId = tdId;
            _claimedUploadFileIds.add(tdId);
          }
        }

        if (tdId == trackedTdFileId) {
          final remote = fileMap['remote'] as Map<String, dynamic>?;
          if (remote != null) {
            final uploadedSize =
                (remote['uploaded_size'] as num?)?.toInt() ?? 0;
            final isCompleted = remote['is_uploading_completed'] == true;
            final expectedSize =
                (fileMap['expected_size'] as num?)?.toInt() ??
                (fileMap['size'] as num?)?.toInt() ??
                fileSize;

            if (uploadedSize > 0 || isCompleted) fakeTimer?.cancel();

            if (expectedSize > 0 && onProgress != null) {
              final rawRatio =
                  (uploadedSize / expectedSize).clamp(0.0, 1.0);
              // Report actual transferred bytes up to 99%
              final pct = (rawRatio * 0.99).clamp(0.0, 0.99);
              final now = DateTime.now().millisecondsSinceEpoch;
              if ((pct - lastReportedPct).abs() >= 0.005 ||
                  now - lastReportTime >= 100 ||
                  rawRatio >= 1.0) {
                lastReportedPct = pct;
                lastReportTime = now;
                onProgress(pct);
              }
            }
          }
        }
      }

      // ── Telegram confirmed the message was delivered ──────────────────────
      if (type == 'updateMessageSendSucceeded') {
        final oldId = upd['old_message_id'] as int?;
        final msg = upd['message'] as Map<String, dynamic>?;
        final realId = msg?['id'] as int?;
        if (oldId != null && realId != null) {
          recentSucceeded[oldId] = realId;
          if (expectedTempId != null &&
              oldId == expectedTempId &&
              !completer.isCompleted) {
            completer.complete(realId);
          }
        }
      }

      // ── Telegram rejected the message send ─────────────────────────────────
      else if (type == 'updateMessageSendFailed') {
        final oldId = upd['old_message_id'] as int?;
        final errMap = upd['error'] as Map<String, dynamic>?;
        final msg = errMap?['message'] as String? ??
            'Telegram rejected file upload';
        if (oldId != null) {
          recentFailed[oldId] = msg;
          if (expectedTempId != null &&
              oldId == expectedTempId &&
              !completer.isCompleted) {
            completer.completeError(Exception(msg));
          }
        }
      }
    });

    try {
      // Send document directly to targetChatId (Saved Messages)
      final Map<String, dynamic> pending = await _send({
        '@type': 'sendMessage',
        'chat_id': targetChatId,
        'message_thread_id': 0,
        'input_message_content': {
          '@type': 'inputMessageDocument',
          'document': {'@type': 'inputFileLocal', 'path': localPath},
          'caption': {
            '@type': 'formattedText',
            'text': caption,
            'entities': <dynamic>[],
          },
          'disable_content_type_detection': true,
        },
      }, timeout: const Duration(seconds: 45));

      final tempId = pending['id'] as int;
      expectedTempId = tempId;

      // Extract generated TDLib file ID to track and boost priority to 32
      final content = pending['content'] as Map<String, dynamic>?;
      final doc = content?['document'] as Map<String, dynamic>?;
      final fileObj = doc?['document'] as Map<String, dynamic>?;
      final fileId = fileObj?['id'] as int?;
      if (fileId != null && fileId > 0) {
        trackedTdFileId = fileId;
        _claimedUploadFileIds.add(fileId);

        // Maximize MTProto parallel socket throughput (priority 32)
        _fireAndForget({
          '@type': 'uploadFile',
          'file': {'@type': 'inputFileId', 'id': fileId},
          'file_type': {'@type': 'fileTypeDocument'},
          'priority': 32,
        });
      }

      // If TDLib already confirmed the message before our await resumed:
      if (recentSucceeded.containsKey(tempId)) {
        final realId = recentSucceeded[tempId]!;
        fakeTimer?.cancel();
        onProgress?.call(1.0);
        return realId;
      }
      if (recentFailed.containsKey(tempId)) {
        fakeTimer?.cancel();
        throw Exception(recentFailed[tempId]);
      }

      // Dynamic upload timeout based on file size: minimum 10 min, + 1 min per 20 MB
      final timeoutMinutes = max(10, (fileSize / (20 * 1024 * 1024)).ceil());
      final realId = await completer.future.timeout(
        Duration(minutes: timeoutMinutes),
        onTimeout: () => throw Exception(
            'Upload timed out after $timeoutMinutes minutes — check your connection'),
      );
      fakeTimer?.cancel();
      onProgress?.call(1.0);
      return realId;
    } finally {
      fakeTimer?.cancel();
      await sub.cancel();
      if (trackedTdFileId != null) {
        _claimedUploadFileIds.remove(trackedTdFileId);
      }
    }
  }

  // Global set of TDLib file IDs currently being uploaded.
  // Prevents concurrent chunk-uploads from adopting the same file ID.
  final _claimedUploadFileIds = <int>{};

  // ════════════════════════════════════════════════════════════════════════════
  // DOWNLOAD API
  // ════════════════════════════════════════════════════════════════════════════

  /// High-performance file transfer from TDLib internal cache to destination.
  /// Tries instantaneous O(1) filesystem rename first; falls back to copy across mounts.
  Future<void> _copyOrMoveFile(String srcPath, String destPath) async {
    if (srcPath == destPath) return;
    final src = io.File(srcPath);
    final dest = io.File(destPath);

    final parent = dest.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }

    try {
      // Instant O(1) rename if on same filesystem mount (zero flash memory writes)
      await src.rename(destPath);
      return;
    } catch (_) {
      // Cross-mount fallback (e.g. app private storage to /storage/emulated/0/Download)
      await src.copy(destPath);
    }
  }

  /// Downloads a file directly into TDLib's internal cache and returns the cached file path.
  /// Eliminates redundant intermediate copies when downloading multi-chunk files.
  Future<String> downloadFileToCache(
    int messageId, {
    ProgressCallback? onProgress,
    int? chatId,
  }) async {
    if (!_initialized) {
      throw Exception(
          'Telegram is still starting up. Please wait a moment and try again.');
    }

    onProgress?.call(0.0);
    final targetChatId = chatId ?? await getStorageChatId();

    Map<String, dynamic> msg;
    try {
      msg = await _send(
          {'@type': 'getMessage', 'chat_id': targetChatId, 'message_id': messageId});
    } catch (_) {
      int altChatId = 0;
      try {
        final savedChatId = await _getSavedMessagesChatId();
        if (targetChatId == savedChatId) {
          altChatId = await _resolveStorageChatId();
        } else {
          altChatId = savedChatId;
        }
      } catch (_) {}

      if (altChatId != 0 && altChatId != targetChatId) {
        msg = await _send(
            {'@type': 'getMessage', 'chat_id': altChatId, 'message_id': messageId});
      } else {
        rethrow;
      }
    }

    final content = msg['content'] as Map<String, dynamic>?;
    if (content == null) throw Exception('Message has no content');

    final tdFileId = _extractTdFileId(content);
    if (tdFileId == null) {
      throw Exception('Cannot extract file from message $messageId');
    }

    final dlResult = await _send({
      '@type': 'downloadFile',
      'file_id': tdFileId,
      'priority': 32, // max TDLib priority (1-32) for maximum parallel sockets
      'offset': 0,
      'limit': 0,
      'synchronous': false,
    });

    final initialLocal = dlResult['local'] as Map<String, dynamic>?;
    if (initialLocal != null &&
        initialLocal['is_downloading_completed'] == true) {
      final localPath = initialLocal['path'] as String?;
      if (localPath != null && localPath.isNotEmpty) {
        onProgress?.call(1.0);
        return localPath;
      }
    }

    double lastReportedPct = -1.0;
    int lastReportTime = 0;

    final completer = Completer<String>();
    StreamSubscription<Map<String, dynamic>>? sub;

    sub = updates.listen((upd) {
      if (upd['@type'] == 'updateFile') {
        final fileMap = upd['file'] as Map<String, dynamic>?;
        if (fileMap?['id'] == tdFileId) {
          final local = fileMap?['local'] as Map<String, dynamic>?;
          if (local != null) {
            final expectedSize =
                (fileMap?['expected_size'] as num?)?.toInt() ?? 0;
            final downloadedSize =
                (local['downloaded_size'] as num?)?.toInt() ?? 0;

            if (expectedSize > 0 && onProgress != null) {
              final pct =
                  ((downloadedSize / expectedSize) * 0.99).clamp(0.0, 0.99);
              final now = DateTime.now().millisecondsSinceEpoch;
              if ((pct - lastReportedPct).abs() >= 0.005 ||
                  now - lastReportTime >= 100 ||
                  pct >= 0.99) {
                lastReportedPct = pct;
                lastReportTime = now;
                onProgress(pct);
              }
            }

            if (local['is_downloading_completed'] == true) {
              final path = local['path'] as String?;
              if (path != null && path.isNotEmpty && !completer.isCompleted) {
                completer.complete(path);
              }
            }
          }
        }
      }
    });

    try {
      final localPath =
          await completer.future.timeout(const Duration(hours: 2));
      onProgress?.call(1.0);
      return localPath;
    } catch (e) {
      _fireAndForget({
        '@type': 'cancelDownloadFile',
        'file_id': tdFileId,
        'only_if_pending': false,
      });
      rethrow;
    } finally {
      await sub.cancel();
    }
  }

  Future<void> downloadFile(
    int messageId,
    String destPath, {
    ProgressCallback? onProgress,
    int? chatId,
  }) async {
    final cachedPath = await downloadFileToCache(
      messageId,
      onProgress: onProgress,
      chatId: chatId,
    );
    await _copyOrMoveFile(cachedPath, destPath);
    onProgress?.call(1.0);
  }

  // Concurrency guard: Only one range download query active per tdFileId at any time
  final Map<int, Future<void>> _fileRangeLocks = {};

  /// Reads raw bytes of a file directly from TDLib's internal cache via base64.
  /// Used for streaming partial ranges when the full file is not yet completed on disk.
  Future<List<int>> readFilePart(
    int tdFileId, {
    required int offset,
    required int count,
  }) async {
    final res = await _send({
      '@type': 'readFilePart',
      'file_id': tdFileId,
      'offset': offset,
      'count': count,
    });
    if (res['@type'] == 'filePart') {
      final b64 = res['data'] as String?;
      if (b64 != null) {
        return base64Decode(b64);
      }
    }
    throw Exception('Failed to read file part at offset $offset: $res');
  }

  /// Cancels any active TDLib download for a file.
  Future<void> cancelFileDownload(int messageId, {int? chatId}) async {
    try {
      final targetChatId = chatId ?? await getStorageChatId();
      final msg = await _send({
        '@type': 'getMessage',
        'chat_id': targetChatId,
        'message_id': messageId,
      });
      final content = msg['content'] as Map<String, dynamic>?;
      if (content != null) {
        final tdFileId = _extractTdFileId(content);
        if (tdFileId != null) {
          _fireAndForget({
            '@type': 'cancelDownloadFile',
            'file_id': tdFileId,
            'only_if_pending': false,
          });
        }
      }
    } catch (_) {}
  }

  /// Downloads a **specific byte range** [offset .. offset+limit] from a
  /// Telegram file directly to [destPath].
  ///
  /// This is the foundation of part-based smart streaming.
  ///
  /// TDLib writes the range into its internal cache file. We then read
  /// exactly [limit] bytes starting at [offset] from the cached file or
  /// via [readFilePart] and write them to [destPath].
  Future<void> downloadFileRange(
    int messageId, {
    required String destPath,
    required int offset,
    required int limit,
    int? chatId,
  }) async {
    if (!_initialized) {
      throw Exception('TDLib not initialized');
    }

    final targetChatId = chatId ?? await getStorageChatId();

    // Resolve TDLib file ID from the message
    Map<String, dynamic> msg;
    try {
      msg = await _send({
        '@type': 'getMessage',
        'chat_id': targetChatId,
        'message_id': messageId,
      });
    } catch (_) {
      // Try alternate chat (legacy channel)
      final savedId = await _getSavedMessagesChatId();
      final altId   = targetChatId == savedId
          ? await _resolveStorageChatId()
          : savedId;
      msg = await _send({
        '@type': 'getMessage',
        'chat_id': altId,
        'message_id': messageId,
      });
    }

    final content  = msg['content'] as Map<String, dynamic>?;
    if (content == null) throw Exception('Message $messageId has no content');
    final tdFileId = _extractTdFileId(content);
    if (tdFileId == null) throw Exception('Cannot resolve file from message $messageId');

    // Serialize access to this specific tdFileId so no concurrent downloadFile calls collide
    while (_fileRangeLocks.containsKey(tdFileId)) {
      try {
        await _fileRangeLocks[tdFileId];
      } catch (_) {}
    }

    final lockCompleter = Completer<void>();
    _fileRangeLocks[tdFileId] = lockCompleter.future;

    try {
      // Ask TDLib to download the requested byte range with synchronous=true.
      Map<String, dynamic> dlResult;
      try {
        dlResult = await _send({
          '@type':       'downloadFile',
          'file_id':     tdFileId,
          'priority':    32,
          'offset':      offset,
          'limit':       limit,
          'synchronous': true,
        });
      } catch (e) {
        if (e.toString().contains('Canceled by another downloadFile request')) {
          await Future.delayed(const Duration(milliseconds: 300));
          dlResult = await _send({
            '@type':       'downloadFile',
            'file_id':     tdFileId,
            'priority':    32,
            'offset':      offset,
            'limit':       limit,
            'synchronous': true,
          });
        } else {
          rethrow;
        }
      }

      final local = dlResult['local'] as Map<String, dynamic>?;
      String? cachedPath = local?['path'] as String?;

      final destFile = io.File(destPath);
      final parent   = destFile.parent;
      if (!await parent.exists()) await parent.create(recursive: true);

      // Fast-path: Check if file is already on disk with enough bytes
      if (cachedPath != null && cachedPath.isNotEmpty && io.File(cachedPath).existsSync()) {
        final cacheFile = io.File(cachedPath);
        final cacheLen  = await cacheFile.length();
        if (cacheLen >= offset + limit) {
          final sink = destFile.openWrite();
          try {
            await sink.addStream(cacheFile.openRead(offset, offset + limit));
          } finally {
            await sink.flush();
            await sink.close();
          }
          return;
        }
      }

      // Safe-path: Read directly from TDLib's internal cache via readFilePart!
      // This is 100% reliable even when local.path is empty during in-progress downloads.
      final sink = destFile.openWrite();
      try {
        int bytesRead = 0;
        const readChunkSize = 2 * 1024 * 1024; // 2 MB per read chunk (4x faster throughput)
        while (bytesRead < limit) {
          final toRead = min(readChunkSize, limit - bytesRead);
          final bytes = await readFilePart(
            tdFileId,
            offset: offset + bytesRead,
            count: toRead,
          );
          if (bytes.isEmpty) break;
          sink.add(bytes);
          bytesRead += bytes.length;
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
    } finally {
      _fileRangeLocks.remove(tdFileId);
      if (!lockCompleter.isCompleted) lockCompleter.complete();
    }
  }

  int? _extractTdFileId(Map<String, dynamic> content) {
    final type = content['@type'] as String?;
    switch (type) {
      case 'messageDocument':
        final doc = content['document'] as Map<String, dynamic>?;
        final file = doc?['document'] as Map<String, dynamic>?;
        return file?['id'] as int?;
      case 'messageVideo':
        final video = content['video'] as Map<String, dynamic>?;
        final file = video?['video'] as Map<String, dynamic>?;
        return file?['id'] as int?;
      case 'messageAudio':
        final audio = content['audio'] as Map<String, dynamic>?;
        final file = audio?['audio'] as Map<String, dynamic>?;
        return file?['id'] as int?;
      case 'messagePhoto':
        final photo = content['photo'] as Map<String, dynamic>?;
        final sizes = (photo?['sizes'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        if (sizes.isNotEmpty) {
          final largest = sizes.last;
          final largestFile = largest['photo'] as Map<String, dynamic>?;
          return largestFile?['id'] as int?;
        }
        return null;
      case 'messageAnimation':
        final anim = content['animation'] as Map<String, dynamic>?;
        final file = anim?['animation'] as Map<String, dynamic>?;
        return file?['id'] as int?;
      case 'messageVoiceNote':
        final vn = content['voice_note'] as Map<String, dynamic>?;
        final file = vn?['voice'] as Map<String, dynamic>?;
        return file?['id'] as int?;
      default:
        return null;
    }
  }

  Future<void> downloadChunkedFile(
    List<int> messageIds,
    String destPath, {
    ProgressCallback? onProgress,
    int? chatId,
  }) async {
    final n = messageIds.length;
    final chunkProgress = List<double>.filled(n, 0.0);
    final cachedPaths = List<String>.filled(n, '');

    // ── High-Throughput Continuous Sliding Pool (8 parallel streams) ──
    // Eliminates per-stream MTProto rate limiting; pulls chunks in parallel directly into cache.
    const maxParallel = 8;
    int nextIdx = 0;
    final workers = <Future<void>>[];

    for (int w = 0; w < min(maxParallel, n); w++) {
      if (w > 0) await Future.delayed(const Duration(milliseconds: 50));
      workers.add(() async {
        while (true) {
          final idx = nextIdx++;
          if (idx >= n) break;

          int retry = 0;
          while (true) {
            try {
              final cached = await downloadFileToCache(
                messageIds[idx],
                chatId: chatId,
                onProgress: (prog) {
                  chunkProgress[idx] = prog;
                  final total =
                      chunkProgress.fold(0.0, (a, b) => a + b) / n;
                  onProgress?.call(total.clamp(0.0, 0.98));
                },
              );
              cachedPaths[idx] = cached;
              break;
            } catch (e) {
              retry++;
              if (retry > 2) rethrow;
              await Future.delayed(Duration(seconds: retry));
            }
          }
        }
      }());
    }
    await Future.wait(workers);

    // ── Phase 2: Direct sequential stream stitching into final output file ────
    // Zero duplicate intermediate disk copies; writes directly to destination file.
    onProgress?.call(0.98);
    final outFile = io.File(destPath);
    final parent = outFile.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    final sink = outFile.openWrite();
    try {
      for (int i = 0; i < n; i++) {
        final chunkFile = io.File(cachedPaths[i]);
        if (await chunkFile.exists()) {
          await sink.addStream(chunkFile.openRead());
          try {
            await chunkFile.delete();
          } catch (_) {}
        }
        onProgress?.call(0.98 + (0.02 * (i + 1) / n));
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    onProgress?.call(1.0);
  }

  Future<String?> downloadThumbnail(int fileId) async {
    final dlResult = await _send({
      '@type': 'downloadFile',
      'file_id': fileId,
      'priority': 1,
      'offset': 0,
      'limit': 0,
      'synchronous': false,
    });

    final initialLocal = dlResult['local'] as Map<String, dynamic>?;
    if (initialLocal != null && initialLocal['is_downloading_completed'] == true) {
      return initialLocal['path'] as String?;
    }

    final completer = Completer<String?>();
    StreamSubscription<Map<String, dynamic>>? sub;

    sub = updates.listen((upd) {
      if (upd['@type'] == 'updateFile') {
        final fileMap = upd['file'] as Map<String, dynamic>?;
        if (fileMap?['id'] == fileId) {
          final local = fileMap?['local'] as Map<String, dynamic>?;
          if (local != null && local['is_downloading_completed'] == true) {
            final path = local['path'] as String?;
            if (path != null && path.isNotEmpty && !completer.isCompleted) {
              completer.complete(path);
            }
          }
        }
      }
    });

    try {
      return await completer.future.timeout(const Duration(seconds: 30));
    } catch (e) {
      _fireAndForget({
        '@type': 'cancelDownloadFile',
        'file_id': fileId,
        'only_if_pending': false,
      });
      return null;
    } finally {
      await sub.cancel();
    }
  }

  // ════════════════════════════════════════════════════════════════════════════
  // LIST / META API
  // ════════════════════════════════════════════════════════════════════════════

  Future<List<TdSavedMessage>> listSavedMessages({
    int? chatId,
    String? prefix,
    int limit = 500,
  }) async {
    final targetChatId = chatId ?? await getStorageChatId();
    final results = <TdSavedMessage>[];
    int fromMsgId = 0;

    while (true) {
      final resp = await _send({
        '@type': 'getChatHistory',
        'chat_id': targetChatId,
        'from_message_id': fromMsgId,
        'offset': 0,
        'limit': min(limit - results.length, 100),
        'only_local': false,
      });

      final messages =
          (resp['messages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      if (messages.isEmpty) break;

      for (final msg in messages) {
        // Skip messages with a TEMPORARY negative ID — these haven't been
        // confirmed by Telegram yet. Storing them would corrupt the local DB.
        final msgId = msg['id'] as int;
        if (msgId <= 0) continue;

        // Skip messages that are still pending or failed to send
        if (msg['sending_state'] != null) continue;

        final content = msg['content'] as Map<String, dynamic>?;
        if (content == null) continue;
        final caption = _extractCaption(content);
        if (prefix != null && !caption.startsWith(prefix)) continue;

        final fileInfo = _extractFileInfo(content);
        // Only skip regular text messages that have NO file content and are NOT metadata
        final isText = content['@type'] == 'messageText';
        if (isText &&
            !isFolderCaption(caption) &&
            !caption.startsWith('MOVE_OVERRIDE:') &&
            !caption.startsWith('☁️📍 ')) {
          continue;
        }

        final date = DateTime.fromMillisecondsSinceEpoch((msg['date'] as int) * 1000);
        String? resolvedFileName = fileInfo?['name'] as String?;
        if (resolvedFileName == null || resolvedFileName.isEmpty) {
          final meta = parseFileCaption(caption);
          if (meta?['n'] != null && (meta!['n'] as String).isNotEmpty) {
            resolvedFileName = meta['n'] as String;
          }
        }
        if (resolvedFileName == null || resolvedFileName.isEmpty) {
          final mime = fileInfo?['mime'] as String? ?? '';
          if (mime.startsWith('image/')) {
            resolvedFileName = 'IMG_${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}_$msgId.jpg';
          } else if (mime.startsWith('video/')) {
            resolvedFileName = 'VID_${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}_$msgId.mp4';
          } else if (mime.startsWith('audio/')) {
            resolvedFileName = 'AUD_${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}_$msgId.mp3';
          }
        }

        results.add(TdSavedMessage(
          messageId: msgId,
          caption: caption,
          fileName: resolvedFileName,
          fileSize: fileInfo?['size'] as int? ?? 0,
          mimeType: fileInfo?['mime'] as String? ?? 'application/octet-stream',
          date: date,
          thumbnailId: fileInfo?['thumbnailId'] as int?,
        ));
      }

      if (messages.length < 100 || results.length >= limit) break;
      fromMsgId = messages.last['id'] as int;
    }

    return results;
  }

  Future<int> sendTextMessage(String text, {int? chatId}) async {
    final targetChatId = chatId ?? await getStorageChatId();
    final result = await _send({
      '@type': 'sendMessage',
      'chat_id': targetChatId,
      'message_thread_id': 0,
      'input_message_content': {
        '@type': 'inputMessageText',
        'text': {'@type': 'formattedText', 'text': text, 'entities': []},
        'disable_web_page_preview': true,
        'clear_draft': false,
      },
    });
    return result['id'] as int;
  }

  Future<void> editMessageCaption(int messageId, String newCaption, {int? chatId}) async {
    final targetChatId = chatId ?? await getStorageChatId();
    try {
      await _send({
        '@type': 'editMessageCaption',
        'chat_id': targetChatId,
        'message_id': messageId,
        'caption': {
          '@type': 'formattedText',
          'text': newCaption,
          'entities': []
        },
      });
    } catch (_) {
      final savedChatId = await _getSavedMessagesChatId();
      if (savedChatId != targetChatId) {
        await _send({
          '@type': 'editMessageCaption',
          'chat_id': savedChatId,
          'message_id': messageId,
          'caption': {
            '@type': 'formattedText',
            'text': newCaption,
            'entities': []
          },
        });
      } else {
        rethrow;
      }
    }
  }

  Future<void> deleteMessages(List<int> messageIds, {int? chatId}) async {
    final targetChatId = chatId ?? await getStorageChatId();
    try {
      await _send({
        '@type': 'deleteMessages',
        'chat_id': targetChatId,
        'message_ids': messageIds,
        'revoke': true,
      });
    } catch (_) {
      final savedChatId = await _getSavedMessagesChatId();
      if (savedChatId != targetChatId) {
        try {
          await _send({
            '@type': 'deleteMessages',
            'chat_id': savedChatId,
            'message_ids': messageIds,
            'revoke': true,
          });
        } catch (_) {}
      }
    }
  }

  // ── Caption helpers ─────────────────────────────────────────────────────────
  //
  // NEW clean format (what users see in Telegram Saved Messages):
  //
  //   ☁️ Report.pdf
  //   📂 /Work/Reports
  //   🆔 abc123folderId          ← only when inside a folder
  //
  // Chunk part caption (for files > 1.95 GB):
  //
  //   ☁️ BigVideo.mp4 (part 2/5)
  //   📂 /Videos
  //   🆔 abc123folderId
  //
  // OLD format (legacy, still parsed for backward compat):
  //   LIMITLESS_FILE:{"n":"...","fi":"...","fp":"..."}
  //
  // ─────────────────────────────────────────────────────────────────────────

  /// Build a clean, human-readable caption for a file upload.
  static String _buildFileCaption({
    required String fileName,
    String? folderId,
    String folderPath = '/',
  }) {
    final buf = StringBuffer();
    buf.write('$_lcFileMarker$fileName');           // ☁️ filename
    buf.write('$_lcPathMarker$folderPath');          // 📂 /path
    if (folderId != null && folderId.isNotEmpty) {
      buf.write('$_lcIdMarker$folderId');            // 🆔 folderId
    }
    return buf.toString();
  }

  /// Build a clean caption for a chunk part of a large file.
  static String _buildChunkCaption({
    required String fileName,
    required int partIndex,   // 0-based
    required int totalParts,
    String? folderId,
    String folderPath = '/',
  }) {
    final buf = StringBuffer();
    buf.write('$_lcFileMarker$fileName$_lcChunkMarker${partIndex + 1}/$totalParts)');

    buf.write('$_lcPathMarker$folderPath');
    if (folderId != null && folderId.isNotEmpty) {
      buf.write('$_lcIdMarker$folderId');
    }
    return buf.toString();
  }

  /// Parse a file caption — supports both new clean format and legacy JSON.
  /// Returns a map with keys: 'n' (name), 'fp' (folderPath), 'fi' (folderId?).
  static Map<String, dynamic>? parseFileCaption(String caption) {
    // ── New clean format ──────────────────────────────────────────────────
    if (caption.startsWith(_lcFileMarker)) {
      final lines = caption.split('\n');
      final firstLine = lines[0]; // '☁️ filename' or '☁️ filename (part X/Y)'

      // Strip the '☁️ ' prefix to get raw name (possibly with chunk suffix)
      String rawName = firstLine.substring(_lcFileMarker.length);
      // If chunk, strip the ' (part X/Y)' suffix
      final chunkIdx = rawName.indexOf(_lcChunkMarker);
      if (chunkIdx != -1) rawName = rawName.substring(0, chunkIdx);

      String folderPath = '/';
      String? folderId;

      for (int i = 1; i < lines.length; i++) {
        final line = lines[i];
        if (line.startsWith('📂 ')) {
          folderPath = line.substring('📂 '.length);
        } else if (line.startsWith('🆔 ')) {
          folderId = line.substring('🆔 '.length);
        }
      }
      return {'n': rawName, 'fp': folderPath, 'fi': folderId};
    }

    // ── Legacy format: LIMITLESS_FILE:{...} ──────────────────────────────
    if (!caption.startsWith(_fileMetaPrefix)) return null;
    try {
      return jsonDecode(caption.substring(_fileMetaPrefix.length))
          as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Returns true if the caption belongs to a Limitless Cloud file.
  static bool isFileCaption(String caption) =>
      caption.startsWith(_lcFileMarker) ||
      caption.startsWith(_fileMetaPrefix);

  /// Returns true for chunk captions (new OR legacy).
  static bool isChunkCaption(String caption) =>
      (caption.startsWith(_lcFileMarker) && caption.contains(_lcChunkMarker)) ||
      caption.startsWith(_chunkPrefix);

  /// Returns true if the caption belongs to a Limitless Cloud folder.
  static bool isFolderCaption(String caption) =>
      caption.startsWith('☁️📁 ') ||
      caption.startsWith(_folderPrefix);

  String _extractCaption(Map<String, dynamic> content) {
    final type = content['@type'] as String?;
    switch (type) {
      case 'messageText':
        return (content['text'] as Map<String, dynamic>?)?['text'] as String? ?? '';
      default:
        // messageDocument, messageVideo, messagePhoto, etc. all have 'caption' on root content object
        final cap = content['caption'] as Map<String, dynamic>?;
        return cap?['text'] as String? ?? '';
    }
  }

  Map<String, dynamic>? _extractFileInfo(Map<String, dynamic> content) {
    final type = content['@type'] as String?;
    if (type == 'messageDocument') {
      final doc = content['document'] as Map<String, dynamic>?;
      final file = doc?['document'] as Map<String, dynamic>?;
      final thumb = doc?['thumbnail'] as Map<String, dynamic>?;
      final thumbFile = thumb?['file'] as Map<String, dynamic>?;
      return {
        'name': doc?['file_name'],
        'size': file?['size'] ?? 0,
        'mime': doc?['mime_type'] ?? 'application/octet-stream',
        'thumbnailId': thumbFile?['id'],
      };
    } else if (type == 'messagePhoto') {
      final photo = content['photo'] as Map<String, dynamic>?;
      final sizes = (photo?['sizes'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      if (sizes.isNotEmpty) {
        final largest = sizes.last;
        final largestFile = largest['photo'] as Map<String, dynamic>?;
        final thumbSize = sizes.first;
        final thumbFile = thumbSize['photo'] as Map<String, dynamic>?;
        return {
          'name': null,
          'size': largestFile?['size'] ?? 0,
          'mime': 'image/jpeg',
          'thumbnailId': thumbFile?['id'] ?? largestFile?['id'],
        };
      }
    } else if (type == 'messageVideo') {
      final video = content['video'] as Map<String, dynamic>?;
      final file = video?['video'] as Map<String, dynamic>?;
      final thumb = video?['thumbnail'] as Map<String, dynamic>?;
      final thumbFile = thumb?['file'] as Map<String, dynamic>?;
      return {
        'name': video?['file_name'],
        'size': file?['size'] ?? 0,
        'mime': video?['mime_type'] ?? 'video/mp4',
        'thumbnailId': thumbFile?['id'],
      };
    } else if (type == 'messageAudio') {
      final audio = content['audio'] as Map<String, dynamic>?;
      final file = audio?['audio'] as Map<String, dynamic>?;
      final thumb = audio?['album_cover_thumbnail'] as Map<String, dynamic>?;
      final thumbFile = thumb?['file'] as Map<String, dynamic>?;
      return {
        'name': audio?['file_name'] ?? (audio?['title'] != null ? '${audio!['title']}.mp3' : null),
        'size': file?['size'] ?? 0,
        'mime': audio?['mime_type'] ?? 'audio/mpeg',
        'thumbnailId': thumbFile?['id'],
      };
    } else if (type == 'messageAnimation') {
      final anim = content['animation'] as Map<String, dynamic>?;
      final file = anim?['animation'] as Map<String, dynamic>?;
      final thumb = anim?['thumbnail'] as Map<String, dynamic>?;
      final thumbFile = thumb?['file'] as Map<String, dynamic>?;
      return {
        'name': anim?['file_name'],
        'size': file?['size'] ?? 0,
        'mime': anim?['mime_type'] ?? 'video/mp4',
        'thumbnailId': thumbFile?['id'],
      };
    } else if (type == 'messageVoiceNote') {
      final vn = content['voice_note'] as Map<String, dynamic>?;
      final file = vn?['voice'] as Map<String, dynamic>?;
      return {
        'name': 'voice_note.ogg',
        'size': file?['size'] ?? 0,
        'mime': vn?['mime_type'] ?? 'audio/ogg',
        'thumbnailId': null,
      };
    }
    return null;
  }

  String _clean(Object e) =>
      e.toString().replaceFirst('Exception: ', '').replaceFirst('TDLib timeout: ', 'Timeout — ');

  // ── Dispose ─────────────────────────────────────────────────────────────────

  void dispose() {
    _pollTimer?.cancel();
    _connectivitySub?.cancel();
    _updateCtrl.close();
    _fireAndForget({'@type': 'close'});
  }

  /// Safety net: Aggressively try to close any leaked clients (from hot restart or 
  /// detached engines) and reinitialize TDLib.
  Future<void> retryInit() async {
    initError = null;
    if (_clientId > 0) {
      // Send close to our known client, plus a few previous ones just in case 
      // they were leaked from a previous Isolate in the same C++ process.
      for (int i = 1; i <= _clientId + 5; i++) {
        try {
          TdPlugin.instance.tdSend(i, '{"@type":"close"}');
        } catch (_) {}
      }
    }
    await Future.delayed(const Duration(milliseconds: 500));
    _initialized = false;
    _pollTimer?.cancel();
    final docs = await getApplicationDocumentsDirectory();
    final dbPath = p.join(docs.path, 'tdlib_db');
    await initialize(dbPath: dbPath);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Top-level init helper — call AFTER runApp() to avoid blocking startup
// ─────────────────────────────────────────────────────────────────────────────

Future<void> initTdlibService() async {
  final docs = await getApplicationDocumentsDirectory();
  final dbPath = p.join(docs.path, 'tdlib_db');
  await io.Directory(dbPath).create(recursive: true);
  await TdlibService.instance.initialize(dbPath: dbPath);
}