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
  final List<int> chunkMessageIds;

  const TelegramFile({
    required this.messageId,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.date,
    required this.caption,
    this.thumbnailId,
    this.chunkMessageIds = const [],
  });

  factory TelegramFile.fromSavedMessage(TdSavedMessage msg) {
    String name = msg.fileName ?? 'unknown';
    final meta = TelegramStorageService.parseFileCaption(msg.caption);
    if (meta != null && meta['n'] != null && (meta['n'] as String).isNotEmpty) {
      name = meta['n'] as String;
    }
    return TelegramFile(
      messageId: msg.messageId,
      fileName:  name,
      fileSize:  msg.fileSize,
      mimeType:  msg.mimeType,
      date:      msg.date,
      caption:   msg.caption,
      thumbnailId: msg.thumbnailId,
      chunkMessageIds: const [],
    );
  }
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

// ── Unified Sync Result ───────────────────────────────────────────────────────
class TelegramSyncData {
  final List<TelegramFolderMeta> folders;
  final Map<int, Map<String, dynamic>> moveOverrides;
  final List<TelegramFile> files;

  const TelegramSyncData({
    required this.folders,
    required this.moveOverrides,
    required this.files,
  });
}

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
  /// Checks if a message for this file name was already uploaded to Saved Messages.
  /// Used by OfflineSyncService to prevent double-uploading if TDLib or a previous
  /// attempt already delivered the file to Telegram.
  Future<int?> findRecentMessageForFile(String fileName) async {
    try {
      final storageChatId = await _tdlib.getStorageChatId();
      final msgs = await _tdlib.listSavedMessages(chatId: storageChatId, limit: 60);
      for (final m in msgs) {
        if (m.fileName == fileName || m.caption.contains(fileName)) {
          return m.messageId;
        }
      }
      final legacyChannelId = await _tdlib.getLegacyChannelId();
      if (legacyChannelId != 0 && legacyChannelId != storageChatId) {
        final legacy = await _tdlib.listSavedMessages(chatId: legacyChannelId, limit: 60);
        for (final m in legacy) {
          if (m.fileName == fileName || m.caption.contains(fileName)) {
            return m.messageId;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Upload [file] directly to Telegram dedicated storage channel.
  ///
  /// Uses TDLib's upload mechanism with parallel multi-stream chunking
  /// for maximum 15 to 25+ MB/s speed without cluttering Saved Messages.
  Future<ChunkedUploadResult> uploadFileChunked(
    File file, {
    ProgressCallback? onProgress,
    String? folderId,
    String folderPath = '/',
    int maxRetries = 2,
    int? chatId,
  }) async {
    Exception? last;
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final result = await _tdlib.uploadFile(
          file,
          onProgress: onProgress,
          folderId:   folderId,
          folderPath: folderPath,
          chatId:     chatId,
        );
        return ChunkedUploadResult(
          primaryMessageId: result.primaryMessageId,
          allMessageIds:    result.allMessageIds,
        );
      } catch (e) {
        last = e is Exception ? e : Exception(e.toString());
        // If upload timed out or was already dispatched to TDLib's queue,
        // do not re-send to avoid creating double copies in Telegram.
        if (e.toString().contains('Upload timed out') || attempt >= maxRetries) {
          throw last;
        }
        await Future.delayed(_backoff(attempt));
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
    int? chatId,
  }) async {
    final result = await uploadFileChunked(
      file,
      onProgress: onProgress,
      folderId:   folderId,
      folderPath: folderPath,
      chatId:     chatId,
    );
    return result.primaryMessageId;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // DOWNLOAD — 8-parallel workers via TDLib
  // ══════════════════════════════════════════════════════════════════════════

  /// Download a file to local filesystem.
  /// If [customDestPath] is provided, writes directly to it in a single step (zero redundant copies).
  Future<File> downloadFile(
    int messageId,
    String fileName, {
    String? customDestPath,
    ProgressCallback? onProgress,
    List<int>? chunkMessageIds,
    int? chatId,
  }) async {
    if (chunkMessageIds != null && chunkMessageIds.length > 1) {
      return downloadChunkedFile(
        chunkMessageIds,
        fileName,
        customDestPath: customDestPath,
        onProgress: onProgress,
        chatId: chatId,
      );
    }
    final String destPath;
    if (customDestPath != null && customDestPath.isNotEmpty) {
      destPath = customDestPath;
    } else {
      final dir = await getApplicationDocumentsDirectory();
      destPath = '${dir.path}/$fileName';
    }

    await _tdlib.downloadFile(messageId, destPath, onProgress: onProgress, chatId: chatId);
    return File(destPath);
  }

  /// Download a multi-part file (multiple Telegram messages).
  /// Reassembles all parts into one file.
  Future<File> downloadChunkedFile(
    List<int> chunkMessageIds,
    String fileName, {
    String? customDestPath,
    ProgressCallback? onProgress,
    int? chatId,
  }) async {
    final String destPath;
    if (customDestPath != null && customDestPath.isNotEmpty) {
      destPath = customDestPath;
    } else {
      final dir = await getApplicationDocumentsDirectory();
      destPath = '${dir.path}/$fileName';
    }

    await _tdlib.downloadChunkedFile(
      chunkMessageIds,
      destPath,
      onProgress: onProgress,
      chatId: chatId,
    );
    return File(destPath);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // LIST / INFO / DELETE
  // ══════════════════════════════════════════════════════════════════════════

  /// High-speed unified single-pass sync scan.
  /// Fetches Telegram storage messages once and extracts folders, move overrides,
  /// and all uploaded files (documents, photos, videos, audio, etc.).
  Future<TelegramSyncData> unifiedSyncScan() async {
    final storageChatId = await _tdlib.getStorageChatId();

    // 1. Fetch all storage messages in a single continuous stream
    final msgs = await _tdlib.listSavedMessages(chatId: storageChatId, limit: 3000);

    // Also check legacy private channel if one was previously used
    try {
      final legacyChannelId = await _tdlib.getLegacyChannelId();
      if (legacyChannelId != 0 && legacyChannelId != storageChatId) {
        final legacyMsgs = await _tdlib.listSavedMessages(chatId: legacyChannelId, limit: 1000);
        final seenIds = msgs.map((m) => m.messageId).toSet();
        for (final lm in legacyMsgs) {
          if (!seenIds.contains(lm.messageId)) {
            msgs.add(lm);
          }
        }
      }
    } catch (_) {}

    final folders = <TelegramFolderMeta>[];
    final moveOverrides = <int, Map<String, dynamic>>{};
    final fileMsgs = <TdSavedMessage>[];

    for (final m in msgs) {
      final caption = m.caption;

      // 1. Check folder metadata
      if (TdlibService.isFolderCaption(caption)) {
        final f = parseFolderMeta(m);
        if (f != null) folders.add(f);
        continue;
      }

      // 2. Check move override
      final override = parseMoveOverride(caption);
      if (override != null) {
        final msgId = override['msgId'] as int;
        moveOverrides.putIfAbsent(msgId, () => override);
        continue;
      }

      // 3. File messages: accept any message that contains a real file or non-plain-text payload
      final hasFile = (m.fileName != null && m.fileName!.isNotEmpty) ||
          m.fileSize > 0 ||
          (m.mimeType.isNotEmpty && m.mimeType != 'text/plain');

      if (hasFile) {
        fileMsgs.add(m);
      }
    }

    // 4. Process chunked files and normal files
    final partRegex = RegExp(r'\(part\s*(\d+)/(\d+)\)');
    final chunkGroups = <String, List<TdSavedMessage>>{};
    final consumedChunkMsgIds = <int>{};

    for (final m in fileMsgs) {
      final isChunk = TdlibService.isChunkCaption(m.caption) ||
          (m.fileName?.startsWith('lc_chunk_') ?? false) ||
          (m.fileName?.contains(RegExp(r'\.part\d+of\d+')) ?? false);

      if (isChunk) {
        final meta = parseFileCaption(m.caption);
        String cleanName = meta?['n'] as String? ?? m.fileName ?? 'unknown';
        if (cleanName.startsWith('lc_chunk_') && m.caption.contains('☁️ ')) {
          final lines = m.caption.split('\n');
          String first = lines[0].substring(lines[0].indexOf('☁️ ') + 3);
          final cIdx = first.indexOf(' (part ');
          if (cIdx != -1) first = first.substring(0, cIdx);
          if (first.isNotEmpty) cleanName = first;
        }
        final folderPath = (meta?['fp'] as String?) ?? '/';
        final key = '$folderPath:$cleanName';
        chunkGroups.putIfAbsent(key, () => []).add(m);
        consumedChunkMsgIds.add(m.messageId);
      }
    }

    // Second pass: for chunk groups, link part 1 if uploaded with standard caption
    for (final entry in chunkGroups.entries) {
      final group = entry.value;
      bool hasPart1 = false;
      for (final m in group) {
        final match = partRegex.firstMatch(m.caption);
        if (match != null && match.group(1) == '1') {
          hasPart1 = true;
          break;
        }
      }
      if (!hasPart1) {
        final sepIdx = entry.key.indexOf(':');
        final targetPath = sepIdx != -1 ? entry.key.substring(0, sepIdx) : '/';
        final targetName = sepIdx != -1 ? entry.key.substring(sepIdx + 1) : entry.key;

        for (final m in fileMsgs) {
          if (consumedChunkMsgIds.contains(m.messageId)) continue;
          final meta = parseFileCaption(m.caption);
          if (meta == null) continue;
          final name = meta['n'] as String?;
          final path = (meta['fp'] as String?) ?? '/';
          if (name == targetName && path == targetPath) {
            group.add(m);
            consumedChunkMsgIds.add(m.messageId);
            break;
          }
        }
      }
    }

    final unifiedFiles = <TelegramFile>[];

    // Unify chunk groups into single files
    for (final entry in chunkGroups.entries) {
      final group = entry.value;
      if (group.isEmpty) continue;

      group.sort((a, b) {
        final matchA = partRegex.firstMatch(a.caption);
        final matchB = partRegex.firstMatch(b.caption);
        if (matchA != null && matchB != null) {
          final idxA = int.tryParse(matchA.group(1)!) ?? 0;
          final idxB = int.tryParse(matchB.group(1)!) ?? 0;
          return idxA.compareTo(idxB);
        }
        return a.messageId.compareTo(b.messageId);
      });

      final primary = group.first;
      final meta = parseFileCaption(primary.caption) ??
          parseFileCaption(group.last.caption);
      var cleanName = meta?['n'] as String? ?? primary.fileName ?? 'unknown';
      if (cleanName.startsWith('lc_chunk_')) {
        for (final gm in group) {
          final gMeta = parseFileCaption(gm.caption);
          if (gMeta?['n'] != null && !(gMeta!['n'] as String).startsWith('lc_chunk_')) {
            cleanName = gMeta['n'] as String;
            break;
          }
        }
      }

      final totalSize = group.fold<int>(0, (sum, m) => sum + m.fileSize);
      final chunkIds = group.map((m) => m.messageId).toList();
      int? thumbId = primary.thumbnailId;
      if (thumbId == null) {
        for (final gm in group) {
          if (gm.thumbnailId != null) {
            thumbId = gm.thumbnailId;
            break;
          }
        }
      }

      unifiedFiles.add(TelegramFile(
        messageId: primary.messageId,
        fileName: cleanName,
        fileSize: totalSize,
        mimeType: primary.mimeType,
        date: primary.date,
        caption: primary.caption,
        thumbnailId: thumbId,
        chunkMessageIds: chunkIds,
      ));
    }

    // Add all normal files (including photos, videos, audios with or without ☁️ caption)
    for (final m in fileMsgs) {
      if (consumedChunkMsgIds.contains(m.messageId)) continue;
      if (m.fileName?.startsWith('lc_chunk_') ?? false) continue;
      if (m.fileName?.contains(RegExp(r'\.part\d+of\d+')) ?? false) continue;
      if (TdlibService.isChunkCaption(m.caption)) continue;

      unifiedFiles.add(TelegramFile.fromSavedMessage(m));
    }

    return TelegramSyncData(
      folders: folders,
      moveOverrides: moveOverrides,
      files: unifiedFiles,
    );
  }

  /// List all files using the unified scan
  Future<List<TelegramFile>> listFiles() async {
    final syncData = await unifiedSyncScan();
    return syncData.files;
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
  Future<Map<int, Map<String, dynamic>>> listMoveOverrides() async {
    final syncData = await unifiedSyncScan();
    return syncData.moveOverrides;
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

  /// Parse a folder metadata message from Saved Messages.
  static TelegramFolderMeta? parseFolderMeta(TdSavedMessage msg) {
    final caption = msg.caption;
    if (caption.startsWith('☁️📁 ')) {
      try {
        final lines = caption.split('\n');
        final name = lines[0].substring('☁️📁 '.length).trim();
        String path = '/';
        String id = msg.messageId.toString(); // fallback
        String? parentId;
        String color = '#4F8CFF';

        for (int i = 1; i < lines.length; i++) {
          final line = lines[i];
          if (line.startsWith('📂 ')) {
            path = line.substring('📂 '.length).trim();
          } else if (line.startsWith('🆔 ')) {
            id = line.substring('🆔 '.length).trim();
          } else if (line.startsWith('👆 ')) {
            parentId = line.substring('👆 '.length).trim();
          } else if (line.startsWith('🎨 ')) {
            color = line.substring('🎨 '.length).trim();
          }
        }
        return TelegramFolderMeta(
          metaMessageId: msg.messageId,
          id:            id,
          name:          name,
          parentId:      parentId,
          path:          path,
          color:         color,
        );
      } catch (_) {}
      return null;
    }

    if (caption.startsWith(_folderPrefix)) {
      try {
        final json = jsonDecode(caption.substring(_folderPrefix.length))
            as Map<String, dynamic>;
        return TelegramFolderMeta.fromJson(msg.messageId, json);
      } catch (_) {}
    }
    return null;
  }

  /// List all folder metadata messages from Saved Messages.
  Future<List<TelegramFolderMeta>> listFolderMeta() async {
    final syncData = await unifiedSyncScan();
    return syncData.folders;
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
