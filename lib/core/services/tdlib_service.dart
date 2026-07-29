import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

import 'package:handy_tdlib/handy_tdlib.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

const int _kTgLimit = 1950 * 1024 * 1024; // stay under 2 GB limit

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

  // Initialization error
  String? initError;

  // ── Initialize ──────────────────────────────────────────────────────────────

  Future<void> initialize({required String dbPath}) async {
    if (_initialized) return;

    // Load native libtdjson.so
    await TdPlugin.initialize();

    _clientId = TdPlugin.instance.tdCreateClientId();
    _initialized = true;

    // Start polling loop — every 10ms checks for new TDLib messages.
    // This is the correct pattern for handy_tdlib: no isolate needed
    // because tdReceive() is non-blocking when timeout=0.
    _pollTimer = Timer.periodic(const Duration(milliseconds: 10), (_) {
      _poll();
    });

    // Subscribe to auth state changes internally
    updates.listen((upd) {
      if (upd['@type'] == 'error') {
        initError = 'TDLib Error: ${upd['message']}';
        return;
      }

      if (upd['@type'] == 'updateAuthorizationState') {
        final state = upd['authorization_state'] as Map<String, dynamic>?;
        final type = state?['@type'] as String? ?? '';
        _authState = type;
        
        // Respond to encryption key request automatically
        if (type == 'authorizationStateWaitEncryptionKey') {
          _fireAndForget({
            '@type': 'checkDatabaseEncryptionKey',
            'encryption_key': '',
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
    });
  }

  // ── Poll loop (main isolate, non-blocking) ──────────────────────────────────

  void _poll() {
    // tdReceive(0) returns immediately if nothing available
    String? raw;
    try {
      raw = TdPlugin.instance.tdReceive(0);
    } catch (_) {
      return;
    }
    if (raw == null) return;

    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    _route(msg);
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

  /// Log out
  Future<void> logout() async {
    try {
      await _send({'@type': 'logOut'}, timeout: const Duration(seconds: 10));
    } catch (_) {}
  }

  // ════════════════════════════════════════════════════════════════════════════
  // UPLOAD API
  // ════════════════════════════════════════════════════════════════════════════

  Future<TdUploadResult> uploadFile(
    io.File file, {
    ProgressCallback? onProgress,
    String? folderId,
    String folderPath = '/',
  }) async {
    final fileName = p.basename(file.path);
    final fileSize = await file.length();
    onProgress?.call(0.0);

    if (fileSize < _kTgLimit) {
      final caption = _buildFileCaption(
          fileName: fileName, folderId: folderId, folderPath: folderPath);
      final msgId = await _uploadSingleFile(
        localPath: file.path,
        caption: caption,
        onProgress: onProgress,
      );
      onProgress?.call(1.0);
      return TdUploadResult(primaryMessageId: msgId, allMessageIds: []);
    } else {
      final numChunks = (fileSize / _kTgLimit).ceil();
      final chunkBytes = (fileSize / numChunks).ceil();
      final msgIds = List<int?>.filled(numChunks, null);
      final tmpDir = await getTemporaryDirectory();
      final chunkProgress = List<double>.filled(numChunks, 0.0);
      final taskId = DateTime.now().millisecondsSinceEpoch;
      // Bounded parallel upload (max 2 chunks concurrently)
      const maxParallel = 2;
      for (int i = 0; i < numChunks; i += maxParallel) {
        final batch = <Future<void>>[];
        for (int j = i; j < i + maxParallel && j < numChunks; j++) {
          batch.add(() async {
            final offset = j * chunkBytes;
            final partLen = min(chunkBytes, fileSize - offset);
            final tmpPath = '${tmpDir.path}/lc_chunk_${taskId}_$j';
            final tmpFile = io.File(tmpPath);

            try {
              // 1. Buffer streaming to fix OOM
              final sink = tmpFile.openWrite();
              await file.openRead(offset, offset + partLen).pipe(sink);

              final partName = j == 0 ? fileName : '$fileName.part${j + 1}of$numChunks';
              final caption = j == 0
                  ? _buildFileCaption(fileName: fileName, folderId: folderId, folderPath: folderPath)
                  : _buildChunkCaption(
                      fileName: fileName,
                      partIndex: j,
                      totalParts: numChunks,
                      folderId: folderId,
                      folderPath: folderPath,
                    );

              // 2. Upload
              final msgId = await _uploadSingleFile(
                localPath: tmpPath,
                caption: caption,
                onProgress: (prog) {
                  chunkProgress[j] = prog;
                  final totalProg = chunkProgress.reduce((a, b) => a + b) / numChunks;
                  onProgress?.call(totalProg.clamp(0.0, 1.0));
                },
                fileName: partName,
              );
              msgIds[j] = msgId;
            } finally {
              // 3. Strict cleanup
              try {
                if (await tmpFile.exists()) {
                  await tmpFile.delete();
                }
              } catch (_) {}
            }
          }());
        }
        await Future.wait(batch);
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
  }) async {
    final chatId = await _getSavedMessagesChatId();
    onProgress?.call(0.0);

    // ── Step 1: Queue the message send ──────────────────────────────────────
    // sendMessage returns IMMEDIATELY with a TEMPORARY negative ID.
    // The real Telegram message ID arrives later via updateMessageSendSucceeded.
    // If we return the temp ID, the DB will store a broken record that can never
    // match real messages on sync — causing "files not appearing" after re-login.
    final pending = await _send({
      '@type': 'sendMessage',
      'chat_id': chatId,
      'message_thread_id': 0,
      'input_message_content': {
        '@type': 'inputMessageDocument',
        'document': {'@type': 'inputFileLocal', 'path': localPath},
        'caption': {
          '@type': 'formattedText',
          'text': caption,
          'entities': []
        },
        'disable_content_type_detection': true,
      },
    }, timeout: const Duration(minutes: 5));

    final tempId = pending['id'] as int; // negative temp ID
    final fileId = _extractTdFileId(pending['content'] as Map<String, dynamic>? ?? {});

    // ── Step 2: Subscribe to update events BEFORE yielding control ──────────
    // We listen for:
    //   updateFile                  → real byte-level upload progress (0→1)
    //   updateMessageSendSucceeded  → real final message ID
    //   updateMessageSendFailed     → upload error
    final completer = Completer<int>();

    StreamSubscription<Map<String, dynamic>>? sub;
    sub = updates.listen((upd) {
      final type = upd['@type'] as String?;

      // ── Real upload progress via updateFile ──────────────────────────────
      if (type == 'updateFile') {
        try {
          final fileMap = upd['file'] as Map<String, dynamic>?;
          final local   = fileMap?['local'] as Map<String, dynamic>?;
          
          bool matchesId = (fileId != null && fileMap?['id'] == fileId && fileId != 0);
          bool matchesPath = false;
          if (local != null && local['path'] != null) {
            matchesPath = p.basename(local['path'] as String) == p.basename(localPath);
          }
          
          if (!matchesId && !matchesPath) return;

          if (local != null) {
            final uploadOffset = (local['upload_offset'] as num?)?.toInt() ?? 0;
            final expectedSize = (fileMap?['expected_size'] as num?)?.toInt()
                              ?? (fileMap?['size'] as num?)?.toInt()
                              ?? 0;
            if (expectedSize > 0 && onProgress != null) {
              // Clamp to 0.95 — leave 0.95→1.0 for the final ID confirmation step
              final pct = (uploadOffset / expectedSize).clamp(0.0, 0.95);
              onProgress(pct);
            }
          }
        } catch (_) {}
        return;
      }

      // ── Real message ID when Telegram confirms the send ──────────────────
      if (type == 'updateMessageSendSucceeded') {
        final oldId = upd['old_message_id'] as int?;
        if (oldId == tempId && !completer.isCompleted) {
          final msg    = upd['message'] as Map<String, dynamic>?;
          final realId = msg?['id'] as int?;
          if (realId != null) {
            completer.complete(realId);
          } else {
            completer.completeError(Exception('updateMessageSendSucceeded missing id'));
          }
        }
        return;
      }

      // ── Upload failure ───────────────────────────────────────────────────
      if (type == 'updateMessageSendFailed') {
        final oldId = upd['old_message_id'] as int?;
        if (oldId == tempId && !completer.isCompleted) {
          final errMap = upd['error'] as Map<String, dynamic>?;
          final msg    = errMap?['message'] as String?
                      ?? 'Telegram rejected the file upload';
          completer.completeError(Exception(msg));
        }
        return;
      }
    });

    // ── Step 3: Wait for real ID (up to 60 min for large files) ─────────────
    try {
      final realId = await completer.future.timeout(
        const Duration(minutes: 60),
        onTimeout: () {
          throw Exception('Upload timed out after 60 minutes — check your connection');
        },
      );
      onProgress?.call(1.0);
      return realId;
    } finally {
      await sub.cancel();
    }
  }

  // ════════════════════════════════════════════════════════════════════════════
  // DOWNLOAD API
  // ════════════════════════════════════════════════════════════════════════════

  Future<void> downloadFile(
    int messageId,
    String destPath, {
    ProgressCallback? onProgress,
  }) async {
    // Guard: TDLib must be fully initialized before getMessage works.
    // Without this, TDLib throws the cryptic "Initialization parameters
    // are needed: call setTdlibParameters first" error.
    if (!_initialized) {
      throw Exception(
          'Telegram is still starting up. Please wait a moment and try again.');
    }

    onProgress?.call(0.0);
    final chatId = await _getSavedMessagesChatId();

    final msg = await _send({'@type': 'getMessage', 'chat_id': chatId, 'message_id': messageId});
    final content = msg['content'] as Map<String, dynamic>?;
    if (content == null) throw Exception('Message has no content');

    final tdFileId = _extractTdFileId(content);
    if (tdFileId == null) throw Exception('Cannot extract file from message $messageId');

    final dlResult = await _send({
      '@type': 'downloadFile',
      'file_id': tdFileId,
      'priority': 1,
      'offset': 0,
      'limit': 0,
      'synchronous': false,
    });

    final initialLocal = dlResult['local'] as Map<String, dynamic>?;
    if (initialLocal != null && initialLocal['is_downloading_completed'] == true) {
      final localPath = initialLocal['path'] as String?;
      if (localPath != null && localPath.isNotEmpty) {
        onProgress?.call(0.95);
        await io.File(localPath).copy(destPath);
        onProgress?.call(1.0);
        return;
      }
    }

    final completer = Completer<String>();
    StreamSubscription<Map<String, dynamic>>? sub;

    sub = updates.listen((upd) {
      if (upd['@type'] == 'updateFile') {
        final fileMap = upd['file'] as Map<String, dynamic>?;
        if (fileMap?['id'] == tdFileId) {
          final local = fileMap?['local'] as Map<String, dynamic>?;
          if (local != null) {
            final expectedSize = (fileMap?['expected_size'] as num?)?.toInt() ?? 0;
            final downloadedSize = (local['downloaded_size'] as num?)?.toInt() ?? 0;
            
            if (expectedSize > 0 && onProgress != null) {
              onProgress((downloadedSize / expectedSize).clamp(0.0, 0.95));
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
      // 2 hours absolute max for a single chunk/file download
      final localPath = await completer.future.timeout(const Duration(hours: 2));
      onProgress?.call(0.95);
      await io.File(localPath).copy(destPath);
      onProgress?.call(1.0);
    } catch (e) {
      // Cancel the download in TDLib if it timed out or failed
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
      default:
        return null;
    }
  }

  Future<void> downloadChunkedFile(
    List<int> messageIds,
    String destPath, {
    ProgressCallback? onProgress,
  }) async {
    final outFile = io.File(destPath);
    final sink = outFile.openWrite();
    try {
      for (int i = 0; i < messageIds.length; i++) {
        final tmpPath = '$destPath.part$i';
        try {
          await downloadFile(messageIds[i], tmpPath, onProgress: (prog) {
            onProgress?.call(((i + prog) / messageIds.length).clamp(0.0, 1.0));
          });
          final partFile = io.File(tmpPath);
          await partFile.openRead().pipe(sink);
        } finally {
          try {
            final partFile = io.File(tmpPath);
            if (await partFile.exists()) {
              await partFile.delete();
            }
          } catch (_) {}
        }
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
    String? prefix,
    int limit = 500,
  }) async {
    final chatId = await _getSavedMessagesChatId();
    final results = <TdSavedMessage>[];
    int fromMsgId = 0;

    while (true) {
      final resp = await _send({
        '@type': 'getChatHistory',
        'chat_id': chatId,
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
        if (caption == null) continue;
        if (prefix != null && !caption.startsWith(prefix)) continue;

        final fileInfo = _extractFileInfo(content);
        results.add(TdSavedMessage(
          messageId: msgId,
          caption: caption,
          fileName: fileInfo?['name'] as String?,
          fileSize: fileInfo?['size'] as int? ?? 0,
          mimeType: fileInfo?['mime'] as String? ?? 'application/octet-stream',
          date: DateTime.fromMillisecondsSinceEpoch(
              (msg['date'] as int) * 1000),
          thumbnailId: fileInfo?['thumbnailId'] as int?,
        ));
      }

      if (messages.length < 100 || results.length >= limit) break;
      fromMsgId = messages.last['id'] as int;
    }

    return results;
  }

  Future<int> sendTextMessage(String text) async {
    final chatId = await _getSavedMessagesChatId();
    final result = await _send({
      '@type': 'sendMessage',
      'chat_id': chatId,
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

  Future<void> editMessageCaption(int messageId, String newCaption) async {
    final chatId = await _getSavedMessagesChatId();
    try {
      await _send({
        '@type': 'editMessageCaption',
        'chat_id': chatId,
        'message_id': messageId,
        'caption': {
          '@type': 'formattedText',
          'text': newCaption,
          'entities': []
        },
      });
    } catch (_) {}
  }

  Future<void> deleteMessages(List<int> messageIds) async {
    final chatId = await _getSavedMessagesChatId();
    await _send({
      '@type': 'deleteMessages',
      'chat_id': chatId,
      'message_ids': messageIds,
      'revoke': true,
    });
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

  String? _extractCaption(Map<String, dynamic> content) {
    final type = content['@type'] as String?;
    switch (type) {
      case 'messageText':
        return (content['text'] as Map<String, dynamic>?)?['text'] as String?;
      default:
        // messageDocument, messageVideo, messagePhoto, etc. all have 'caption' on the root content object
        final cap = content['caption'] as Map<String, dynamic>?;
        return cap?['text'] as String?;
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
    }
    return null;
  }

  String _clean(Object e) =>
      e.toString().replaceFirst('Exception: ', '').replaceFirst('TDLib timeout: ', 'Timeout — ');

  // ── Dispose ─────────────────────────────────────────────────────────────────

  void dispose() {
    _pollTimer?.cancel();
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
