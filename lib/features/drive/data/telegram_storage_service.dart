import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

import '../../../core/services/tdlib_service.dart';
import '../../auth/data/telegram_auth_service.dart';

// ── Re-export TdlibService types under the old names for API compat ──────────
export '../../../core/services/tdlib_service.dart'
    show ProgressCallback, TdUploadResult, TdSavedMessage;

// ── Upload result (backward compat wrapper) ────────────────────────────────────
class ChunkedUploadResult {
  final int primaryMessageId;
  final List<int> allMessageIds;
  bool get isChunked => allMessageIds.length > 1;

  const ChunkedUploadResult({
    required this.primaryMessageId,
    required this.allMessageIds,
  });
}

// ── Telegram file info (for listFiles) ───────────────────────────────────────
class TelegramFile {
  final int messageId;
  final String fileName;
  final int fileSize;
  final String mimeType;
  final DateTime date;
  final String caption;
  final int? thumbnailId;

  const TelegramFile({
    required this.messageId,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.date,
    required this.caption,
    this.thumbnailId,
  });

  factory TelegramFile.fromSavedMessage(TdSavedMessage msg) => TelegramFile(
        messageId: msg.messageId,
        fileName:  msg.fileName ?? 'unknown',
        fileSize:  msg.fileSize,
        mimeType:  msg.mimeType,
        date:      msg.date,
        caption:   msg.caption,
        thumbnailId: msg.thumbnailId,
      );
}

// ── Folder metadata ────────────────────────────────────────────────────────────
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

// ── Caption constants (identical to Python server — backward compat) ──────────
const _folderPrefix      = 'LIMITLESS_FOLDER:';
const _fileMetaPrefix    = 'LIMITLESS_FILE:';

// ── Move-override message prefix ─────────────────────────────────────────────
// When editMessageCaption fails (Telegram only allows edits within 48 hours),
// we send a NEW lightweight text message with this prefix to record the move.
// syncFromTelegram reads these overrides and applies them on top of file captions,
// so data recovery always restores files to their LATEST folder, not the upload folder.
//
// Format (what appears in Telegram Saved Messages):
//   ☁️📍 <originalTelegramMessageId>
//   📂 /NewFolder/Path
//   🆔 newFolderIdIfAny
const _moveOverridePrefix = '☁️📍 ';

// ─────────────────────────────────────────────────────────────────────────────
//  TelegramStorageService  — serverless direct-to-Telegram
// ─────────────────────────────────────────────────────────────────────────────

class TelegramStorageService {
  final TelegramAuthService _auth;

  TelegramStorageService(this._auth);

  // Public accessor kept for backward compat with DlManagerNotifier
  TelegramAuthService get authService => _auth;

  TdlibService get _tdlib => TdlibService.instance;

  // ── Caption helpers ─────────────────────────────────────────────────────────

  /// Build the caption for a newly uploaded file.
  /// Uses the new clean human-readable format — what the user sees in Telegram:
  ///
  ///   ☁️ Report.pdf
  ///   📂 /Work
  ///   🆔 abc123
  ///
  static String buildFileCaption({
    required String fileName,
    String? folderId,
    String folderPath = '/',
  }) {
    final buf = StringBuffer();
    buf.write('☁️ $fileName');                          // line 0: filename
    buf.write('\n📂 $folderPath');                       // line 1: folder path
    if (folderId != null && folderId.isNotEmpty) {
      buf.write('\n🆔 $folderId');                      // line 2: folder ID (optional)
    }
    return buf.toString();
  }

  /// Parse a caption from Telegram — supports both new clean format and legacy.
  /// Returns map with keys: 'n' (name), 'fp' (folderPath), 'fi' (folderId?).
  static Map<String, dynamic>? parseFileCaption(String caption) {
    // ── New clean format ─────────────────────────────────────────────────
    if (caption.startsWith('☁️ ')) {
      return TdlibService.parseFileCaption(caption);
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

  // ══════════════════════════════════════════════════════════════════════════
  // UPLOAD — direct to Telegram, zero server hops
  // ══════════════════════════════════════════════════════════════════════════

  /// Upload [file] directly to Telegram Saved Messages.
  ///
  /// Uses TDLib's upload mechanism which handles 512 KB parts and
  /// parallel uploads internally for maximum speed.
  Future<ChunkedUploadResult> uploadFileChunked(
    File file, {
    ProgressCallback? onProgress,
    String? folderId,
    String folderPath = '/',
    int maxRetries = 8,
  }) async {
    Exception? last;
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final result = await _tdlib.uploadFile(
          file,
          onProgress: onProgress,
          folderId:   folderId,
          folderPath: folderPath,
        );
        return ChunkedUploadResult(
          primaryMessageId: result.primaryMessageId,
          allMessageIds:    result.allMessageIds,
        );
      } catch (e) {
        last = e is Exception ? e : Exception(e.toString());
        if (attempt < maxRetries) {
          await Future.delayed(_backoff(attempt));
        }
      }
    }
    throw last!;
  }

  /// Legacy single-file upload wrapper (keeps DriveProvider unchanged).
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
  // DOWNLOAD — 8-parallel workers via TDLib
  // ══════════════════════════════════════════════════════════════════════════

  /// Download a single-message file (< 2 GB) to local filesystem.
  Future<File> downloadFile(int messageId, String fileName) async {
    final dir       = await getApplicationDocumentsDirectory();
    final destPath  = '${dir.path}/$fileName';

    await _tdlib.downloadFile(messageId, destPath);
    return File(destPath);
  }

  /// Download a multi-part file (≥ 2 GB, multiple Telegram messages).
  /// Reassembles all parts into one file.
  Future<File> downloadChunkedFile(
    List<int> chunkMessageIds,
    String fileName, {
    ProgressCallback? onProgress,
  }) async {
    final dir      = await getApplicationDocumentsDirectory();
    final destPath = '${dir.path}/$fileName';

    await _tdlib.downloadChunkedFile(
      chunkMessageIds,
      destPath,
      onProgress: onProgress,
    );
    return File(destPath);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // LIST / INFO / DELETE
  // ══════════════════════════════════════════════════════════════════════════

  /// List all files from Telegram Saved Messages (new + legacy format).
  Future<List<TelegramFile>> listFiles() async {
    // Fetch all messages — no prefix filter so we catch both old and new captions.
    final msgs = await _tdlib.listSavedMessages(limit: 500);
    return msgs
        .where((m) => TdlibService.isFileCaption(m.caption))
        .map(TelegramFile.fromSavedMessage)
        .toList();
  }

  /// Delete a single Telegram message (file or metadata).
  Future<void> deleteFile(int messageId) async {
    await _tdlib.deleteMessages([messageId]);
  }

  /// Delete multiple Telegram messages (used for chunked ≥ 2 GB files).
  Future<void> deleteChunkedFile(List<int> chunkMessageIds) async {
    try {
      await _tdlib.deleteMessages(chunkMessageIds);
    } catch (_) {
      // Best-effort — delete one by one on failure
      for (final id in chunkMessageIds) {
        try { await _tdlib.deleteMessages([id]); } catch (_) {}
      }
    }
  }

  /// Rename a file by editing its caption in Telegram.
  Future<void> renameFileTelegram(int messageId, String newName) async {
    try {
      // Re-read the old caption to preserve folder metadata
      final msgs = await _tdlib.listSavedMessages();
      final old  = msgs.firstWhere(
        (m) => m.messageId == messageId,
        orElse: () => TdSavedMessage(
          messageId: messageId,
          caption:   buildFileCaption(fileName: newName),
          date:      DateTime.now(),
        ),
      );
      final meta = parseFileCaption(old.caption);
      final newCaption = buildFileCaption(
        fileName:   newName,
        folderId:   meta?['fi'] as String?,
        folderPath: meta?['fp'] as String? ?? '/',
      );
      await _tdlib.editMessageCaption(messageId, newCaption);
    } catch (_) {
      // Non-fatal
    }
  }

  /// Update the folder location of a file by editing its Telegram caption.
  ///
  /// Strategy (handles the 48-hour Telegram edit limit):
  ///   1. Try editMessageCaption — works within 48 hours of upload.
  ///   2. If that fails (MESSAGE_EDIT_TIME_EXPIRED or any error), fall back to
  ///      sending a NEW move-override text message. Text messages can always be
  ///      sent; there is no time limit on sending. syncFromTelegram reads these
  ///      overrides and applies them on top of the base file captions.
  ///
  /// For chunked (>2 GB) files only the primary message carries the caption,
  /// so passing [messageId] = file.telegramMessageId is always correct.
  Future<void> moveFileTelegram(
    int messageId, {
    required String fileName,
    required String? newFolderId,
    required String newFolderPath,
  }) async {
    // ── Attempt 1: direct caption edit (works within 48 hours) ──────────────
    try {
      final newCaption = buildFileCaption(
        fileName:   fileName,
        folderId:   newFolderId,
        folderPath: newFolderPath,
      );
      await _tdlib.editMessageCaption(messageId, newCaption);
      return; // ✔ Edit succeeded — done.
    } catch (_) {
      // Edit failed: file is older than 48 hours (MESSAGE_EDIT_TIME_EXPIRED),
      // or some transient error. Fall through to the override message strategy.
    }

    // ── Attempt 2: send a move-override text message (no time limit) ────────
    // This lightweight text message records that the original file message
    // (identified by [messageId]) has been moved to a new folder. When the
    // user reinstalls and syncFromTelegram runs, listMoveOverrides() will
    // find this message and apply the new folder location.
    try {
      final buf = StringBuffer();
      buf.write('$_moveOverridePrefix$messageId');        // line 0: original msg ID
      buf.write('\n📂 $newFolderPath');                   // line 1: new folder path
      if (newFolderId != null && newFolderId.isNotEmpty) {
        buf.write('\n🆔 $newFolderId');                    // line 2: new folder ID
      }
      await _tdlib.sendTextMessage(buf.toString());
    } catch (_) {
      // Non-fatal — the move already succeeded in SQLite for this session.
    }
  }

  // ── Move-override parsing ────────────────────────────────────────────────────

  /// Parse a move-override text message.
  /// Returns null if the text is not a move-override message.
  /// Returns a map with keys:
  ///   'msgId'      (int)     — the original Telegram file message ID
  ///   'folderPath' (String)  — the new folder path
  ///   'folderId'   (String?) — the new folder ID (optional)
  static Map<String, dynamic>? parseMoveOverride(String text) {
    if (!text.startsWith(_moveOverridePrefix)) return null;
    try {
      final lines = text.split('\n');
      final msgId = int.tryParse(lines[0].substring(_moveOverridePrefix.length).trim());
      if (msgId == null) return null;
      String folderPath = '/';
      String? folderId;
      for (final line in lines.skip(1)) {
        if (line.startsWith('📂 '))       { folderPath = line.substring(3).trim(); }
        else if (line.startsWith('🆔 '))  { folderId   = line.substring(3).trim(); }
      }
      return {'msgId': msgId, 'folderPath': folderPath, 'folderId': folderId};
    } catch (_) {
      return null;
    }
  }

  /// Read all move-override messages from Telegram Saved Messages.
  /// Returns a map: originalMessageId → {folderPath, folderId?}
  /// Only the LATEST override per file is kept (in case the file was moved
  /// multiple times after the 48-hour window).
  Future<Map<int, Map<String, dynamic>>> listMoveOverrides() async {
    final msgs = await _tdlib.listSavedMessages(limit: 500);
    final overrides = <int, Map<String, dynamic>>{};
    for (final msg in msgs) {
      // Move overrides are text messages (fileSize == 0)
      if (msg.fileSize > 0) continue;
      final parsed = parseMoveOverride(msg.caption);
      if (parsed == null) continue;
      final msgId = parsed['msgId'] as int;
      // Keep the most recent override (list is newest-first from Telegram)
      overrides.putIfAbsent(msgId, () => parsed);
    }
    return overrides;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FOLDER METADATA — stored as text messages in Saved Messages
  // ══════════════════════════════════════════════════════════════════════════

  /// Save folder metadata as a clean, readable text message in Saved Messages.
  ///
  /// What the user sees in Telegram:
  ///
  ///   ☁️📁 Movies
  ///   📂 /
  ///   🆔 abc123folderId
  ///   👆 parentFolderId    ← only for sub-folders
  ///   🎨 #4F8CFF           ← only when non-default color
  ///
  Future<int> saveFolderMeta(TelegramFolderMeta meta) async {
    final buf = StringBuffer();
    buf.write('☁️📁 ${meta.name}');               // line 0: folder name
    buf.write('\n📂 ${meta.path}');                // line 1: path
    buf.write('\n🆔 ${meta.id}');                  // line 2: folder ID
    if (meta.parentId != null && meta.parentId!.isNotEmpty) {
      buf.write('\n👆 ${meta.parentId}');           // line 3: parent ID
    }
    if (meta.color != '#4F8CFF') {
      buf.write('\n🎨 ${meta.color}');             // line 4: custom color
    }
    return _tdlib.sendTextMessage(buf.toString());
  }


  /// Delete a folder metadata message.
  Future<void> deleteFolderMeta(int metaMessageId) async {
    await _tdlib.deleteMessages([metaMessageId]);
  }

  /// List all folder metadata messages from Saved Messages.
  /// Supports both new clean format and legacy LIMITLESS_FOLDER: format.
  Future<List<TelegramFolderMeta>> listFolderMeta() async {
    // Fetch all messages without prefix filter to catch both old and new.
    final msgs = await _tdlib.listSavedMessages(limit: 200);
    final result = <TelegramFolderMeta>[];

    for (final msg in msgs) {
      final caption = msg.caption;

      // ── New clean format: starts with ☁️📁 ────────────────────────────────
      if (caption.startsWith('☁️📁 ')) {
        try {
          final lines = caption.split('\n');
          final name = lines[0].substring('☁️📁 '.length);
          String path = '/';
          String id = msg.messageId.toString(); // fallback
          String? parentId;
          String color = '#4F8CFF';

          for (int i = 1; i < lines.length; i++) {
            final line = lines[i];
            if (line.startsWith('📂 '))      { path     = line.substring('📂 '.length); }
            else if (line.startsWith('🆔 ')) { id       = line.substring('🆔 '.length); }
            else if (line.startsWith('👆 ')) { parentId = line.substring('👆 '.length); }
            else if (line.startsWith('🎨 ')) { color    = line.substring('🎨 '.length); }
          }
          result.add(TelegramFolderMeta(
            metaMessageId: msg.messageId,
            id:            id,
            name:          name,
            parentId:      parentId,
            path:          path,
            color:         color,
          ));
        } catch (_) {}
        continue;
      }

      // ── Legacy format: LIMITLESS_FOLDER:{...} ──────────────────────────────
      if (!caption.startsWith(_folderPrefix)) continue;
      try {
        final json = jsonDecode(caption.substring(_folderPrefix.length))
            as Map<String, dynamic>;
        result.add(TelegramFolderMeta.fromJson(msg.messageId, json));
      } catch (_) {}
    }
    return result;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // URL UPLOAD — download URL to temp file, then upload to Telegram
  // ══════════════════════════════════════════════════════════════════════════

  /// Download [url] to a temp file, then upload that file to Telegram.
  /// Called by DlManagerNotifier.uploadUrl().
  Future<int> uploadFileFromUrl(String url, {String caption = ''}) async {
    // This is handled externally in DlManagerNotifier:
    // Phase 1: Dio downloads URL to temp file
    // Phase 2: calls uploadFileChunked on the temp file
    // We keep this stub for API compat.
    throw UnimplementedError('Use DlManagerNotifier.uploadUrl() instead');
  }

  // ── Exponential back-off ──────────────────────────────────────────────────

  static Duration _backoff(int attempt) {
    final secs = min(60, 1 << attempt);
    return Duration(seconds: secs);
  }
}
