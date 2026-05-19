import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/constants/app_constants.dart';
import '../../auth/data/telegram_auth_service.dart';

// ── Upload progress callback ──────────────────────────────────────────────────
typedef ProgressCallback = void Function(double progress);

// ── Telegram Saved Messages file descriptor ───────────────────────────────────
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
        fileName: j['file_name'] as String,
        fileSize: j['file_size'] as int,
        mimeType: j['mime_type'] as String? ?? 'application/octet-stream',
        date: DateTime.parse(j['date'] as String),
        caption: j['caption'] as String? ?? '',
      );
}

// ── Folder metadata (stored as LIMITLESS_FOLDER:<json> text in Saved Messages) ─
class TelegramFolderMeta {
  final int metaMessageId; // Telegram msg ID of THIS metadata text message
  final String id;         // Our internal folder UUID
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
        id: j['id'] as String,
        name: j['name'] as String,
        parentId: j['parentId'] as String?,
        path: j['path'] as String,
        color: j['color'] as String? ?? '#4F8CFF',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'parentId': parentId,
        'path': path,
        'color': color,
      };
}

// ── Caption encoding constants ────────────────────────────────────────────────
const _folderPrefix = 'LIMITLESS_FOLDER:';
const _fileMetaPrefix = 'LIMITLESS_FILE:';

// ── Service ───────────────────────────────────────────────────────────────────

class TelegramStorageService {
  final TelegramAuthService _auth;
  final String _base = AppConstants.backendBaseUrl;

  TelegramStorageService(this._auth);

  // ── Private helpers ────────────────────────────────────────────────────────

  Future<String> get _session => _auth.getSession();

  Future<Map<String, dynamic>> _get(
      String path, [Map<String, String>? params]) async {
    final session = await _session;
    final uri = Uri.parse('$_base$path').replace(queryParameters: {
      'session_string': session,
      ...?params,
    });
    final resp = await http.get(uri).timeout(const Duration(seconds: 60));
    if (resp.statusCode >= 400) {
      final err = jsonDecode(resp.body)['detail'] ?? 'Error ${resp.statusCode}';
      throw Exception(err);
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _delete(
      String path, Map<String, dynamic> body) async {
    final session = await _session;
    final uri = Uri.parse('$_base$path');
    final resp = await http
        .delete(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({...body, 'session_string': session}),
        )
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode >= 400) {
      final err = jsonDecode(resp.body)['detail'] ?? 'Error ${resp.statusCode}';
      throw Exception(err);
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _postMultipart(
      String path, Map<String, String> fields) async {
    final session = await _session;
    final uri = Uri.parse('$_base$path');
    final request = http.MultipartRequest('POST', uri)
      ..fields['session_string'] = session
      ..fields.addAll(fields);
    final streamed = await request.send().timeout(const Duration(seconds: 30));
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode >= 400) {
      final err = jsonDecode(resp.body)['detail'] ?? 'Error ${resp.statusCode}';
      throw Exception(err);
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // ── File Caption Encoding ──────────────────────────────────────────────────

  /// Encode folder membership into the file caption so it can be restored
  /// on sync after reinstall.  Format: LIMITLESS_FILE:{"n":"x","fi":"id","fp":"/path"}
  static String buildFileCaption({
    required String fileName,
    String? folderId,
    String folderPath = '/',
  }) {
    return '$_fileMetaPrefix${jsonEncode({
      'n': fileName,
      'fi': folderId,
      'fp': folderPath,
    })}';
  }

  /// Parse encoded folder info from a file's Telegram caption.
  /// Returns null if caption was not written by Limitless Cloud.
  static Map<String, dynamic>? parseFileCaption(String caption) {
    if (!caption.startsWith(_fileMetaPrefix)) return null;
    try {
      return jsonDecode(caption.substring(_fileMetaPrefix.length))
          as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // ── File Operations ────────────────────────────────────────────────────────

  /// Upload [file] to Telegram Saved Messages.
  /// [folderId] / [folderPath] are encoded in the caption for later sync.
  /// Returns the Telegram message_id.
  Future<int> uploadFile(
    File file, {
    ProgressCallback? onProgress,
    String? folderId,
    String folderPath = '/',
  }) async {
    final session = await _session;
    final fileName = p.basename(file.path);
    final mimeType =
        lookupMimeType(file.path) ?? 'application/octet-stream';
    final fileBytes = await file.readAsBytes();

    onProgress?.call(0.05);

    final caption = buildFileCaption(
      fileName: fileName,
      folderId: folderId,
      folderPath: folderPath,
    );

    final uri = Uri.parse('$_base/files/upload');
    final request = http.MultipartRequest('POST', uri)
      ..fields['session_string'] = session
      ..fields['caption'] = caption
      ..files.add(http.MultipartFile.fromBytes(
        'file',
        fileBytes,
        filename: fileName,
        contentType: MediaType.parse(mimeType),
      ));

    onProgress?.call(0.2);

    final streamed =
        await request.send().timeout(const Duration(minutes: 10));

    onProgress?.call(0.9);

    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode >= 400) {
      final err = jsonDecode(resp.body)['detail'] ?? 'Upload failed';
      throw Exception(err);
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    onProgress?.call(1.0);
    return data['message_id'] as int;
  }

  /// List all document files stored in Saved Messages.
  Future<List<TelegramFile>> listFiles() async {
    final data = await _get('/files/list');
    final raw = data['files'] as List<dynamic>;
    return raw.cast<Map<String, dynamic>>().map(TelegramFile.fromJson).toList();
  }

  /// Download a file by its message_id to app documents directory.
  Future<File> downloadFile(int messageId, String fileName) async {
    final session = await _session;
    final uri = Uri.parse('$_base/files/download/$messageId')
        .replace(queryParameters: {'session_string': session});

    final resp = await http.get(uri).timeout(const Duration(minutes: 10));
    if (resp.statusCode >= 400) {
      final err = jsonDecode(resp.body)['detail'] ?? 'Download failed';
      throw Exception(err);
    }

    final dir = await getApplicationDocumentsDirectory();
    final localFile = File('${dir.path}/$fileName');
    await localFile.writeAsBytes(resp.bodyBytes);
    return localFile;
  }

  /// [Cloud-to-Cloud] Fetch [url] server-side and upload it straight to
  /// the user's Telegram Saved Messages — the phone never downloads any bytes.
  /// Returns the Telegram message_id on success.
  Future<int> uploadFileFromUrl(String url, {String caption = ''}) async {
    final session = await _session;
    final uri = Uri.parse('$_base/files/upload-from-url');
    final body = jsonEncode({
      'session_string': session,
      'url': url,
      'caption': caption,
    });
    final resp = await http
        .post(uri,
            headers: {'Content-Type': 'application/json'}, body: body)
        .timeout(const Duration(minutes: 60)); // large files can take time
    if (resp.statusCode >= 400) {
      final err =
          (jsonDecode(resp.body) as Map<String, dynamic>)['detail'] ??
              'Upload failed (${resp.statusCode})';
      throw Exception(err);
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return data['message_id'] as int;
  }

  /// Delete a file from Saved Messages by its message_id.
  Future<void> deleteFile(int messageId) async {
    await _delete('/files/$messageId', {'message_id': messageId});
  }

  /// Get metadata for a single file without downloading it.
  Future<TelegramFile> getFileInfo(int messageId) async {
    final data = await _get('/files/info/$messageId');
    return TelegramFile.fromJson(data);
  }

  // ── Folder Metadata (persisted to Telegram as LIMITLESS_FOLDER: text msgs) ─

  /// Persist a folder's metadata to Telegram Saved Messages.
  /// Returns the Telegram message_id of the metadata text message.
  Future<int> saveFolderMeta(TelegramFolderMeta meta) async {
    final payload = '$_folderPrefix${jsonEncode(meta.toJson())}';
    final data = await _postMultipart('/meta/save', {'data': payload});
    return data['message_id'] as int;
  }

  /// Delete a folder's metadata message from Telegram.
  /// Call this when a folder is permanently deleted.
  Future<void> deleteFolderMeta(int metaMessageId) async {
    await _delete('/meta/$metaMessageId', {'message_id': metaMessageId});
  }

  /// Fetch all LIMITLESS_FOLDER: metadata messages from Saved Messages.
  Future<List<TelegramFolderMeta>> listFolderMeta() async {
    final data = await _get('/meta/list', {'prefix': _folderPrefix});
    final items = (data['metadata'] as List<dynamic>).cast<Map<String, dynamic>>();
    final result = <TelegramFolderMeta>[];
    for (final item in items) {
      final text = item['text'] as String;
      final msgId = item['message_id'] as int;
      if (!text.startsWith(_folderPrefix)) continue;
      try {
        final json = jsonDecode(text.substring(_folderPrefix.length))
            as Map<String, dynamic>;
        result.add(TelegramFolderMeta.fromJson(msgId, json));
      } catch (_) {
        // Skip malformed entries
      }
    }
    return result;
  }
}
