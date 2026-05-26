import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/constants/app_constants.dart';
import '../../auth/data/telegram_auth_service.dart';

// ── Upload progress callback ──────────────────────────────────────────────────
typedef ProgressCallback = void Function(double progress);

// ─────────────────────────────────────────────────────────────────────────────
//  TELEGRAM SIZE RULES
//  • Files < 2 GB  → 1 Telegram message (single upload)
//  • Files ≥ 2 GB  → split into 1.95 GB Telegram messages (chunked upload)
//
//  DOWNLOAD IS ALWAYS A SINGLE FILE regardless of how many Telegram messages
//  were used during upload.  The server's /files/download-chunked endpoint
//  streams all Telegram messages as one contiguous byte stream.
// ─────────────────────────────────────────────────────────────────────────────

const int    _kTelegramLimit  = 2  * 1024 * 1024 * 1024; // 2 GB
const double _kMaxChunkBytes  = 1.95 * 1024 * 1024 * 1024; // 1.95 GB per Telegram msg

// ── HTTP chunk size for /upload/chunk requests ────────────────────────────────────
// 4 MB matches the server's HTTP_CHUNK_SIZE (was 16 MB in v5.0).
// Smaller chunks = more granular progress + faster relay per chunk.
// Must be kept in sync with server's HTTP_CHUNK_SIZE constant.
const int _kHttpChunkSize = 4 * 1024 * 1024; // 4 MB per HTTP chunk

// ── Retry / timeout configuration ────────────────────────────────────────────
// v5.1: chunk sendTimeout increased (4MB at slow connection + relay time)
const int _kChunkMaxRetries    = 8;  // retries per 4 MB chunk
const int _kInitMaxRetries     = 5;  // retries for /upload/init

// Polling interval while waiting for server to finish Telegram upload
const Duration _kPollInterval  = Duration(seconds: 5);

// Maximum time we wait for server to finish sending a Telegram message.
// v5.1: finalize is synchronous but waits for relay_worker to drain.
// The relay drain can take up to a few minutes for very large queues.
const Duration _kFinalizeMaxWait = Duration(hours: 1);

// Maximum outer retries when server reports "error" during finalize polling.
const int _kFinalizeAutoRetries = 3;

// ─────────────────────────────────────────────────────────────────────────────

int _numTelegramChunks(int fileSize) {
  if (fileSize < _kTelegramLimit) return 1;
  return (fileSize / _kMaxChunkBytes).ceil();
}

int _telegramChunkSize(int fileSize) {
  final n = _numTelegramChunks(fileSize);
  return (fileSize / n).ceil();
}

// ── Upload result ─────────────────────────────────────────────────────────────
class ChunkedUploadResult {
  final int primaryMessageId;
  final List<int> allMessageIds;  // empty when NOT chunked across Telegram msgs

  bool get isChunked => allMessageIds.length > 1;

  const ChunkedUploadResult({
    required this.primaryMessageId,
    required this.allMessageIds,
  });
}

// ── Telegram file info ────────────────────────────────────────────────────────
class TelegramFile {
  final int messageId;
  final String fileName;
  final int fileSize;
  final String mimeType;
  final DateTime date;
  final String caption;

  const TelegramFile({
    required this.messageId,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.date,
    required this.caption,
  });

  factory TelegramFile.fromJson(Map<String, dynamic> j) => TelegramFile(
        messageId: j['message_id'] as int,
        fileName:  j['file_name']  as String,
        fileSize:  j['file_size']  as int,
        mimeType:  j['mime_type']  as String? ?? 'application/octet-stream',
        date:      DateTime.parse(j['date'] as String),
        caption:   j['caption']    as String? ?? '',
      );
}

// ── Folder metadata ───────────────────────────────────────────────────────────
class TelegramFolderMeta {
  final int metaMessageId;
  final String id;
  final String name;
  final String? parentId;
  final String path;
  final String color;

  const TelegramFolderMeta({
    required this.metaMessageId,
    required this.id,
    required this.name,
    this.parentId,
    required this.path,
    this.color = '#4F8CFF',
  });

  factory TelegramFolderMeta.fromJson(int msgId, Map<String, dynamic> j) =>
      TelegramFolderMeta(
        metaMessageId: msgId,
        id:       j['id']       as String,
        name:     j['name']     as String,
        parentId: j['parentId'] as String?,
        path:     j['path']     as String,
        color:    j['color']    as String? ?? '#4F8CFF',
      );

  Map<String, dynamic> toJson() => {
        'id':       id,
        'name':     name,
        'parentId': parentId,
        'path':     path,
        'color':    color,
      };
}

// ── Caption constants ─────────────────────────────────────────────────────────
const _folderPrefix   = 'LIMITLESS_FOLDER:';
const _fileMetaPrefix = 'LIMITLESS_FILE:';

// ─────────────────────────────────────────────────────────────────────────────
//  TelegramStorageService
// ─────────────────────────────────────────────────────────────────────────────
class TelegramStorageService {
  final TelegramAuthService _auth;
  final String _base = AppConstants.backendBaseUrl;

  TelegramStorageService(this._auth);

  // Public accessors used by DlManagerNotifier for streaming downloads
  TelegramAuthService get authService => _auth;
  String get backendBaseUrl => _base;



  // ── Dio (chunk uploads only) ──────────────────────────────────────────────
  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    sendTimeout:    Duration.zero,  // individual chunk calls set their own
    receiveTimeout: const Duration(minutes: 2),
  ));

  // ── Private helpers ───────────────────────────────────────────────────────

  Future<String> get _session => _auth.getSession();

  /// ── Security: session sent as Authorization header ────────────────────────
  /// Session string NEVER goes into URLs (query params) or request bodies.
  /// It travels only in the encrypted HTTPS Authorization header, invisible
  /// to server logs, proxies, and browser history.

  Future<Map<String, dynamic>> _get(
      String path, [Map<String, String>? params]) async {
    final session = await _session;
    final uri = Uri.parse('$_base$path')
        .replace(queryParameters: params?.isNotEmpty == true ? params : null);
    final resp = await http.get(uri, headers: {
      'Authorization': 'Bearer $session',
    }).timeout(const Duration(seconds: 60));
    if (resp.statusCode >= 400) throw Exception(_parseError(resp.body, resp.statusCode));
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _delete(
      String path, Map<String, dynamic> body) async {
    final session = await _session;
    final uri = Uri.parse('$_base$path');
    final resp = await http
        .delete(uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $session',   // ✅ header, not body
            },
            body: jsonEncode(body))                 // body has NO session_string
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode >= 400) throw Exception(_parseError(resp.body, resp.statusCode));
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _post(
      String path, Map<String, dynamic> body) async {
    final session = await _session;
    final uri = Uri.parse('$_base$path');
    final resp = await http
        .post(uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $session',   // ✅ header, not body
            },
            body: jsonEncode(body))                 // body has NO session_string
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode >= 400) throw Exception(_parseError(resp.body, resp.statusCode));
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Rename a file's caption in Telegram Saved Messages.
  Future<void> renameFileTelegram(int messageId, String newName) async {
    try {
      await _post('/files/rename', {
        'message_id': messageId,
        'new_name': newName,
      });
    } catch (_) {
      // Non-fatal — local DB rename is the source of truth
    }
  }

  Future<Map<String, dynamic>> _postMultipart(
      String path, Map<String, String> fields) async {
    final session = await _session;
    final uri = Uri.parse('$_base$path');
    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $session'  // ✅ header, not form field
      ..fields.addAll(fields);                         // fields have NO session_string
    final streamed = await request.send().timeout(const Duration(seconds: 30));
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode >= 400) throw Exception(_parseError(resp.body, resp.statusCode));
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  static String _parseError(String body, int statusCode) {
    try {
      return (jsonDecode(body) as Map<String, dynamic>)['detail'] as String? ??
          'HTTP $statusCode';
    } catch (_) {
      return 'HTTP $statusCode';
    }
  }

  // ── Caption helpers ───────────────────────────────────────────────────────

  static String buildFileCaption({
    required String fileName,
    String? folderId,
    String folderPath = '/',
  }) =>
      '$_fileMetaPrefix${jsonEncode({'n': fileName, 'fi': folderId, 'fp': folderPath})}';

  static Map<String, dynamic>? parseFileCaption(String caption) {
    if (!caption.startsWith(_fileMetaPrefix)) return null;
    try {
      return jsonDecode(caption.substring(_fileMetaPrefix.length))
          as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  PUBLIC UPLOAD API  (unchanged signature — drive_provider needs no edits)
  // ══════════════════════════════════════════════════════════════════════════

  /// Upload [file] using the resumable 4-step protocol.
  ///
  /// Files < 2 GB  → 1 Telegram message
  /// Files ≥ 2 GB  → N Telegram messages of ≤ 1.95 GB each
  ///
  /// Either way the user downloads the result as a SINGLE file.
  Future<ChunkedUploadResult> uploadFileChunked(
    File file, {
    ProgressCallback? onProgress,
    String? folderId,
    String folderPath = '/',
    int maxRetries = _kChunkMaxRetries,
  }) async {
    final session  = await _session;
    final fileName = p.basename(file.path);
    final mimeType = lookupMimeType(file.path) ?? 'application/octet-stream';
    final fileSize = await file.length();

    onProgress?.call(0.0);

    final numTgChunks = _numTelegramChunks(fileSize);

    if (numTgChunks == 1) {
      // ── Single Telegram message (file < 2 GB) ─────────────────────────────
      final caption = buildFileCaption(
        fileName:   fileName,
        folderId:   folderId,
        folderPath: folderPath,
      );
      final msgId = await _resumableUpload(
        file:       file,
        byteOffset: 0,
        byteLength: fileSize,
        fileName:   fileName,
        mimeType:   mimeType,
        caption:    caption,
        session:    session,
        onProgress: (p) => onProgress?.call(p.clamp(0.0, 1.0)),
        maxRetries: maxRetries,
      );
      onProgress?.call(1.0);
      return ChunkedUploadResult(primaryMessageId: msgId, allMessageIds: []);
    } else {
      // ── Multiple Telegram messages (file ≥ 2 GB) ──────────────────────────
      final tgChunkSize = _telegramChunkSize(fileSize);
      final chunkMsgIds = <int>[];

      for (int i = 0; i < numTgChunks; i++) {
        final offset   = i * tgChunkSize;
        final chunkLen = min(tgChunkSize, fileSize - offset);

        final String chunkCaption = i == 0
            ? buildFileCaption(
                fileName:   fileName,
                folderId:   folderId,
                folderPath: folderPath,
              )
            : 'LIMITLESS_CHUNK:${jsonEncode({'n': fileName, 'i': i, 'fi': folderId, 'fp': folderPath})}';

        final chunkMsgId = await _resumableUpload(
          file:       file,
          byteOffset: offset,
          byteLength: chunkLen,
          fileName:   '$fileName.part${i + 1}of$numTgChunks',
          mimeType:   mimeType,
          caption:    chunkCaption,
          session:    session,
          onProgress: (p) {
            final overall = (i + p) / numTgChunks;
            onProgress?.call(overall.clamp(0.0, 1.0));
          },
          maxRetries: maxRetries,
        );
        chunkMsgIds.add(chunkMsgId);
      }

      onProgress?.call(1.0);
      return ChunkedUploadResult(
        primaryMessageId: chunkMsgIds.first,
        allMessageIds:    chunkMsgIds,
      );
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  RESUMABLE UPLOAD — 4 steps per Telegram message  (v5.0 streaming relay)
  // ══════════════════════════════════════════════════════════════════════════
  //
  //  Step 1  POST /upload/init       → get upload_id + Telegram file_id
  //  Step 2  POST /upload/chunk × N  → relay 512KB parts to Telegram NOW
  //                                    (Telegram already has the bytes when
  //                                     this call returns 200)
  //  Step 3  POST /upload/finalize   → calls sendMedia (INSTANT <500ms)
  //                                    returns {status:"done", message_id:X}
  //  Step 4  [optional] poll         → only needed for old server; v5.0
  //                                    finalize returns message_id directly
  //
  //  Progress reporting:
  //    0.00 → 0.90  during chunk uploads + live Telegram relay
  //    0.90 → 1.00  finalize (instant on v5.0 — no more 91%→restart!)
  //
  // ══════════════════════════════════════════════════════════════════════════

  Future<int> _resumableUpload({
    required File file,
    required int byteOffset,
    required int byteLength,
    required String fileName,
    required String mimeType,
    required String caption,
    required String session,
    required ProgressCallback onProgress,
    required int maxRetries,
  }) async {
    // ── Step 1: init ──────────────────────────────────────────────────────────
    final totalHttpChunks = max(1, (byteLength / _kHttpChunkSize).ceil());

    final uploadId = await _uploadInit(
      session:      session,
      filename:     fileName,
      totalSize:    byteLength,
      totalChunks:  totalHttpChunks,
      mimeType:     mimeType,
      maxRetries:   _kInitMaxRetries,
    );

    // ── Step 2: upload HTTP chunks ────────────────────────────────────────────
    // Progress 0.0 → 0.90 during this phase
    final raf = await file.open(mode: FileMode.read);
    try {
      for (int ci = 0; ci < totalHttpChunks; ci++) {
        final chunkStart = byteOffset + ci * _kHttpChunkSize;
        final chunkLen   = min(_kHttpChunkSize, byteLength - ci * _kHttpChunkSize);

        await raf.setPosition(chunkStart);
        final bytes = await raf.read(chunkLen);

        await _uploadChunkWithRetry(
          uploadId:   uploadId,
          chunkIndex: ci,
          data:       bytes,
          maxRetries: maxRetries,
          session:    session,
        );

        // Map chunk progress to 0.0–0.90
        final rawProgress = (ci + 1) / totalHttpChunks;
        onProgress((rawProgress * 0.90).clamp(0.0, 0.90));
      }
    } finally {
      await raf.close();
    }

    // ── Step 3: finalize ─────────────────────────────────────────────────────
    // v5.0 server: finalize is INSTANT — parts already on Telegram.
    //              Returns message_id directly; no polling needed.
    // v4.x server: returns "finalizing"; poll until done.
    onProgress(0.91);
    final directMsgId = await _uploadFinalizeRequest(
      uploadId: uploadId,
      session:  session,
      caption:  caption,
    );

    if (directMsgId != null) {
      // v5.0 server: finalize returned message_id immediately. Done!
      onProgress(1.0);
      return directMsgId;
    }

    // ── Step 4: poll (v4.x server fallback) ──────────────────────────────────
    return await _pollUntilDone(
      uploadId:   uploadId,
      session:    session,
      caption:    caption,
      onProgress: onProgress,
    );
  }

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<String> _uploadInit({
    required String session,
    required String filename,
    required int totalSize,
    required int totalChunks,
    required String mimeType,
    required int maxRetries,
  }) async {
    final uri = Uri.parse('$_base/upload/init');
    Exception? last;

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final req = http.MultipartRequest('POST', uri)
          ..headers['Authorization'] = 'Bearer $session'  // ✅ header, not form field
          ..fields['filename']       = filename
          ..fields['total_size']     = totalSize.toString()
          ..fields['total_chunks']   = totalChunks.toString()
          ..fields['mime_type']      = mimeType;

        final streamed = await req.send().timeout(const Duration(seconds: 30));
        final resp     = await http.Response.fromStream(streamed);

        if (resp.statusCode >= 400) {
          final msg = _parseError(resp.body, resp.statusCode);
          // 4xx → not retryable (bad session, bad params)
          throw Exception(msg);
        }

        return (jsonDecode(resp.body) as Map<String, dynamic>)['upload_id'] as String;
      } catch (e) {
        last = e is Exception ? e : Exception(e.toString());
        if (attempt < maxRetries) await Future.delayed(_backoff(attempt));
      }
    }
    throw last!;
  }

  // ── Chunk upload ──────────────────────────────────────────────────────────

  Future<void> _uploadChunkWithRetry({
    required String    uploadId,
    required int       chunkIndex,
    required Uint8List data,
    required int       maxRetries,
    required String    session,     // passed to _uploadChunkOnce for Authorization header
  }) async {
    Exception? last;
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        await _uploadChunkOnce(
          uploadId:   uploadId,
          chunkIndex: chunkIndex,
          data:       data,
          session:    session,
        );
        return;
      } on DioException catch (e) {
        final code = e.response?.statusCode ?? 0;
        // 4xx = client error, do not retry
        if (code >= 400 && code < 500) {
          throw Exception(
            'Chunk $chunkIndex rejected by server (HTTP $code): '
            '${e.response?.data?['detail'] ?? e.message}',
          );
        }
        last = Exception('Chunk $chunkIndex network error (attempt $attempt): ${e.message}');
        if (attempt < maxRetries) await Future.delayed(_backoff(attempt));
      } catch (e) {
        last = e is Exception ? e : Exception(e.toString());
        if (attempt < maxRetries) await Future.delayed(_backoff(attempt));
      }
    }
    throw last!;
  }

  Future<void> _uploadChunkOnce({
    required String    uploadId,
    required int       chunkIndex,
    required Uint8List data,
    required String    session,      // session needed for Authorization header
  }) async {
    final formData = FormData.fromMap({
      'upload_id':   uploadId,
      'chunk_index': chunkIndex.toString(),
      'chunk_data':  MultipartFile.fromBytes(
        data,
        filename: 'chunk_$chunkIndex',
        contentType: MediaType('application', 'octet-stream'),
      ),
    });

    final response = await _dio.post<Map<String, dynamic>>(
      '$_base/upload/chunk',
      data: formData,
      options: Options(
        sendTimeout:    const Duration(minutes: 3),
        receiveTimeout: const Duration(minutes: 2),
        responseType: ResponseType.json,
        headers: {'Authorization': 'Bearer $session'},  // ✅ auth header
      ),
    );

    if ((response.statusCode ?? 0) >= 400) {
      throw Exception(
        response.data?['detail'] as String? ?? 'Chunk $chunkIndex upload failed',
      );
    }
  }

  // ── Finalize ──────────────────────────────────────────────────────────────

  /// Calls POST /upload/finalize.
  ///
  /// v5.0 server: returns {status:"done", message_id:X} immediately because
  ///   all bytes are already on Telegram (uploaded during chunk relay).
  ///   Returns the message_id directly — no polling needed.
  ///
  /// v4.x server: returns {status:"finalizing"} — caller must poll.
  ///   Returns null to signal that polling is required.
  Future<int?> _uploadFinalizeRequest({
    required String uploadId,
    required String session,
    required String caption,
  }) async {
    final uri = Uri.parse('$_base/upload/finalize');
    Exception? last;

    for (int attempt = 1; attempt <= 5; attempt++) {
      try {
        final req = http.MultipartRequest('POST', uri)
          ..headers['Authorization'] = 'Bearer $session'  // ✅ header, not form field
          ..fields['upload_id']      = uploadId
          ..fields['caption']        = caption;

        // v5.1: finalize waits for relay_worker drain which can take
        // minutes if many chunks are still queued. 3 min timeout.
        final streamed = await req.send().timeout(const Duration(minutes: 3));
        final resp     = await http.Response.fromStream(streamed);

        if (resp.statusCode >= 400) {
          throw Exception(_parseError(resp.body, resp.statusCode));
        }

        // v5.1/v5.0: check if server returned message_id immediately
        try {
          final body   = jsonDecode(resp.body) as Map<String, dynamic>;
          final status = body['status'] as String? ?? '';
          if (status == 'done') {
            final mid = body['message_id'];
            if (mid != null) return mid as int;
          }
        } catch (_) {}

        return null; // finalizing — caller will poll
      } catch (e) {
        last = e is Exception ? e : Exception(e.toString());
        if (attempt < 5) await Future.delayed(_backoff(attempt));
      }
    }
    throw last!;
  }

  // ── Poll until done ───────────────────────────────────────────────────────

  /// Polls GET /upload/status/{uploadId} every 5 s until the background
  /// Telegram upload is done.  Progress is held at 0.91→0.99 during this
  /// phase so the user sees that work is still happening.
  ///
  /// v4.1 FIX: When the server reports "error" status (e.g. FloodWait or
  /// network drop during send_file), this method automatically re-calls
  /// POST /upload/finalize up to [_kFinalizeAutoRetries] times before
  /// surfacing the error to the user.  The server keeps all chunk files on
  /// disk so no data is re-uploaded — the user sees the progress bar stay
  /// at 91-99% while retrying, instead of restarting from 91%.
  ///
  /// Returns the Telegram message_id when status == "done".
  /// Throws if all retries are exhausted or a hard error occurs.
  Future<int> _pollUntilDone({
    required String           uploadId,
    required String           session,
    required String           caption,
    required ProgressCallback onProgress,
  }) async {
    final statusUri  = Uri.parse('$_base/upload/status/$uploadId');
    final deadline   = DateTime.now().add(_kFinalizeMaxWait);
    int   ticks      = 0;
    int   autoRetries = 0;  // outer retries when server reports "error"

    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(_kPollInterval);
      ticks++;

      // Pulse progress 0.91 → 0.99 so the user sees ongoing activity
      final pulse = 0.91 + (ticks % 8) * 0.01;
      onProgress(pulse.clamp(0.91, 0.99));

      try {
        final resp = await http.get(statusUri).timeout(const Duration(seconds: 10));

        if (resp.statusCode == 404) {
          // Session cleaned up — should not happen within TTL, but handle gracefully
          throw Exception('Upload session expired on server. Please retry the upload.');
        }

        if (resp.statusCode >= 400) {
          throw Exception(_parseError(resp.body, resp.statusCode));
        }

        final body   = jsonDecode(resp.body) as Map<String, dynamic>;
        final status = body['status'] as String;

        if (status == 'done') {
          final messageId = body['message_id'];
          if (messageId == null) {
            throw Exception('Server returned done but no message_id.');
          }
          onProgress(1.0);
          return messageId as int;
        }

        if (status == 'error') {
          // ── Auto-retry finalize (THE CORE FIX) ───────────────────────────
          //
          // The server marked "error" because send_file() to Telegram failed
          // (FloodWait, network drop, etc.).  However all chunk files are
          // still on disk.  Re-calling /upload/finalize (which now accepts
          // "error" sessions) re-triggers the background task without any
          // data re-upload.  The user's progress bar stays at 91-99%.
          //
          if (autoRetries < _kFinalizeAutoRetries) {
            autoRetries++;
            // Back-off before retry: 30 s, 60 s, 120 s
            final backoffSecs = 30 * autoRetries;
            for (int s = 0; s < backoffSecs; s += 5) {
              await Future.delayed(const Duration(seconds: 5));
              ticks++;
              onProgress((0.91 + (ticks % 8) * 0.01).clamp(0.91, 0.99));
              if (DateTime.now().isAfter(deadline)) break;
            }
            // Re-trigger the background task on the server
            try {
              await _uploadFinalizeRequest(
                uploadId: uploadId,
                session:  session,
                caption:  caption,
              );
            } catch (_) {
              // If re-finalize itself fails transiently, keep polling —
              // the server status poll will tell us the true state.
            }
            // Continue polling loop — server is finalizing again
            continue;
          }

          // All auto-retries exhausted — surface the error to the user
          final errMsg = body['error'] as String? ?? 'Unknown server error during upload.';
          throw Exception('Upload failed after $autoRetries retries: $errMsg');
        }

        // status == 'finalizing' → keep polling (normal path)
      } catch (e) {
        // Re-throw hard errors that indicate we should give up immediately.
        final msg = e.toString();
        if (msg.contains('Upload session expired') ||
            msg.contains('no message_id') ||
            msg.contains('Upload failed after')) {
          rethrow;
        }
        // Transient network hiccup during polling — continue polling.
        // The server is still working in the background.
      }
    }

    throw Exception(
      'Upload timed out after ${_kFinalizeMaxWait.inMinutes} minutes. '
      'The server may still be uploading — check your file list.',
    );
  }

  // ── Exponential back-off helper ───────────────────────────────────────────

  static Duration _backoff(int attempt) {
    final seconds = min(60, 1 << attempt); // 2, 4, 8, 16, 32, 60 s
    return Duration(seconds: seconds);
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  LEGACY WRAPPER  (keeps DriveProvider call-sites unchanged)
  // ══════════════════════════════════════════════════════════════════════════

  Future<int> uploadFile(
    File file, {
    ProgressCallback? onProgress,
    String? folderId,
    String folderPath = '/',
  }) async {
    final result = await uploadFileChunked(
      file,
      onProgress: onProgress,
      folderId:   folderId,
      folderPath: folderPath,
    );
    return result.primaryMessageId;
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  LIST / DOWNLOAD / DELETE
  // ══════════════════════════════════════════════════════════════════════════

  Future<List<TelegramFile>> listFiles() async {
    final data = await _get('/files/list');
    return (data['files'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map(TelegramFile.fromJson)
        .toList();
  }

  /// Download a single-message file (< 2 GB), streamed to local filesystem.
  Future<File> downloadFile(int messageId, String fileName) async {
    final session   = await _session;
    final uri       = Uri.parse('$_base/files/download/$messageId');
    final dir       = await getApplicationDocumentsDirectory();
    final localFile = File('${dir.path}/$fileName');

    final client = http.Client();
    final sink   = localFile.openWrite();
    try {
      final request  = http.Request('GET', uri)
        ..headers['Authorization'] = 'Bearer $session';  // ✅ header, not URL
      final response = await client.send(request);
      if (response.statusCode >= 400) {
        final body = await response.stream.bytesToString();
        throw Exception(_parseError(body, response.statusCode));
      }
      await response.stream.pipe(sink);
    } finally {
      client.close();
      await sink.flush();
      await sink.close();
    }
    return localFile;
  }

  /// Download a file that was uploaded as multiple Telegram messages (≥ 2 GB).
  ///
  /// The server streams all Telegram messages as ONE contiguous byte stream.
  /// The user receives a single complete file — no reassembly needed on device.
  Future<File> downloadChunkedFile(
    List<int> chunkMessageIds,
    String fileName, {
    ProgressCallback? onProgress,
  }) async {
    final session = await _session;
    final uri     = Uri.parse('$_base/files/download-chunked');
    final body    = jsonEncode({'message_ids': chunkMessageIds});
    final dir     = await getApplicationDocumentsDirectory();
    final outFile = File('${dir.path}/$fileName');
    final sink    = outFile.openWrite();
    final client  = http.Client();
    try {
      final request = http.Request('POST', uri)
        ..headers['Content-Type'] = 'application/json'
        ..headers['Authorization'] = 'Bearer $session'  // ✅ header, not body
        ..body = body;
      final response = await client.send(request);
      if (response.statusCode >= 400) {
        final b = await response.stream.bytesToString();
        throw Exception(_parseError(b, response.statusCode));
      }
      int received  = 0;
      final cLength = response.contentLength ?? 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (cLength > 0) {
          onProgress?.call((received / cLength).clamp(0.0, 1.0));
        }
      }
    } finally {
      client.close();
      await sink.flush();
      await sink.close();
    }
    onProgress?.call(1.0);
    return outFile;
  }

  /// Cloud-to-cloud: server downloads [url] and pushes straight to Telegram.
  Future<int> uploadFileFromUrl(String url, {String caption = ''}) async {
    final session = await _session;
    final uri     = Uri.parse('$_base/files/upload-from-url');
    final body    = jsonEncode({'url': url, 'caption': caption}); // no session in body
    final resp    = await http
        .post(uri, headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $session',   // ✅ header only
        }, body: body)
        .timeout(const Duration(minutes: 60));
    if (resp.statusCode >= 400) throw Exception(_parseError(resp.body, resp.statusCode));
    return (jsonDecode(resp.body) as Map<String, dynamic>)['message_id'] as int;
  }


  Future<void> deleteFile(int messageId) async {
    await _delete('/files/$messageId', {'message_id': messageId});
  }

  Future<void> deleteChunkedFile(List<int> chunkMessageIds) async {
    for (final msgId in chunkMessageIds) {
      try { await deleteFile(msgId); } catch (_) {}
    }
  }

  Future<TelegramFile> getFileInfo(int messageId) async {
    return TelegramFile.fromJson(await _get('/files/info/$messageId'));
  }

  // ── Folder metadata ────────────────────────────────────────────────────────

  Future<int> saveFolderMeta(TelegramFolderMeta meta) async {
    final payload = '$_folderPrefix${jsonEncode(meta.toJson())}';
    return (await _postMultipart('/meta/save', {'data': payload}))['message_id'] as int;
  }

  Future<void> deleteFolderMeta(int metaMessageId) async {
    await _delete('/meta/$metaMessageId', {'message_id': metaMessageId});
  }

  Future<List<TelegramFolderMeta>> listFolderMeta() async {
    final data  = await _get('/meta/list', {'prefix': _folderPrefix});
    final items = (data['metadata'] as List<dynamic>).cast<Map<String, dynamic>>();
    final result = <TelegramFolderMeta>[];
    for (final item in items) {
      final text  = item['text']       as String;
      final msgId = item['message_id'] as int;
      if (!text.startsWith(_folderPrefix)) continue;
      try {
        final json = jsonDecode(text.substring(_folderPrefix.length)) as Map<String, dynamic>;
        result.add(TelegramFolderMeta.fromJson(msgId, json));
      } catch (_) {}
    }
    return result;
  }
}
