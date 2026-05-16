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

// ── Remote file descriptor ────────────────────────────────────────────────────
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

// ── Service ───────────────────────────────────────────────────────────────────

class TelegramStorageService {
  final TelegramAuthService _auth;
  final String _base = AppConstants.backendBaseUrl;

  TelegramStorageService(this._auth);

  // ── Helpers ────────────────────────────────────────────────────────────────

  Future<String> get _session => _auth.getSession();

  Future<Map<String, dynamic>> _get(String path, [Map<String, String>? params]) async {
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

  Future<Map<String, dynamic>> _delete(String path, Map<String, dynamic> body) async {
    final session = await _session;
    final uri = Uri.parse('$_base$path');
    final resp = await http.delete(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({...body, 'session_string': session}),
    ).timeout(const Duration(seconds: 30));
    if (resp.statusCode >= 400) {
      final err = jsonDecode(resp.body)['detail'] ?? 'Error ${resp.statusCode}';
      throw Exception(err);
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Upload [file] to the user's Telegram Saved Messages.
  /// Calls [onProgress] with 0.0–1.0 as upload progresses.
  /// Returns the Telegram message_id on success.
  Future<int> uploadFile(
    File file, {
    ProgressCallback? onProgress,
    String caption = '',
  }) async {
    final session = await _session;
    final fileName = p.basename(file.path);
    final mimeType = lookupMimeType(file.path) ?? 'application/octet-stream';
    final fileBytes = await file.readAsBytes();

    onProgress?.call(0.05);

    final uri = Uri.parse('$_base/files/upload');
    final request = http.MultipartRequest('POST', uri)
      ..fields['session_string'] = session
      ..fields['caption'] = caption.isEmpty ? fileName : caption
      ..files.add(http.MultipartFile.fromBytes(
        'file',
        fileBytes,
        filename: fileName,
        contentType: MediaType.parse(mimeType),
      ));

    onProgress?.call(0.2);

    final streamed = await request.send().timeout(const Duration(minutes: 10));

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

  /// List all files stored in Saved Messages.
  Future<List<TelegramFile>> listFiles() async {
    final data = await _get('/files/list');
    final raw = data['files'] as List<dynamic>;
    return raw
        .cast<Map<String, dynamic>>()
        .map(TelegramFile.fromJson)
        .toList();
  }

  /// Download a file by its message_id to the device's downloads/temp folder.
  /// Returns the local [File] path.
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

  /// Delete a file from Saved Messages by its message_id.
  Future<void> deleteFile(int messageId) async {
    await _delete('/files/$messageId', {'message_id': messageId});
  }

  /// Get metadata for a single file without downloading it.
  Future<TelegramFile> getFileInfo(int messageId) async {
    final data = await _get('/files/info/$messageId');
    return TelegramFile.fromJson(data);
  }
}
