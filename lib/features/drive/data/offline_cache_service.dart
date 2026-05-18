import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/constants/app_constants.dart';
import '../../auth/data/telegram_auth_service.dart';

// ── Offline status ─────────────────────────────────────────────────────────────

enum OfflineStatus {
  /// Not cached — must stream from Telegram.
  cloud,

  /// Currently being downloaded to app-private cache.
  caching,

  /// Fully cached — available without internet.
  cached,

  /// Download failed.
  failed,
}

// ── Per-file cache record ─────────────────────────────────────────────────────

class CacheRecord {
  final String fileId;
  final String fileName;
  final String localPath;
  final int sizeBytes;
  final DateTime cachedAt;
  final DateTime lastAccessedAt;

  const CacheRecord({
    required this.fileId,
    required this.fileName,
    required this.localPath,
    required this.sizeBytes,
    required this.cachedAt,
    required this.lastAccessedAt,
  });

  Map<String, dynamic> toMap() => {
        'file_id': fileId,
        'file_name': fileName,
        'local_path': localPath,
        'size_bytes': sizeBytes,
        'cached_at': cachedAt.millisecondsSinceEpoch,
        'last_accessed_at': lastAccessedAt.millisecondsSinceEpoch,
      };

  factory CacheRecord.fromMap(Map<String, dynamic> m) => CacheRecord(
        fileId: m['file_id'] as String,
        fileName: m['file_name'] as String,
        localPath: m['local_path'] as String,
        sizeBytes: m['size_bytes'] as int,
        cachedAt:
            DateTime.fromMillisecondsSinceEpoch(m['cached_at'] as int),
        lastAccessedAt: DateTime.fromMillisecondsSinceEpoch(
            m['last_accessed_at'] as int),
      );
}

// ── Progress event ────────────────────────────────────────────────────────────

class CacheProgress {
  final String fileId;
  final double progress; // 0.0 – 1.0
  final OfflineStatus status;
  final String? error;

  const CacheProgress({
    required this.fileId,
    required this.progress,
    required this.status,
    this.error,
  });
}

// ── Service ───────────────────────────────────────────────────────────────────

/// Manages the app-private offline cache.
///
/// Files are stored in `<app support>/offline_cache/` — invisible to
/// the Files app and excluded from Photos/Gallery.  SQLite tracks
/// which files are cached and when they were last accessed so we can
/// do LRU eviction.
class OfflineCacheService {
  OfflineCacheService._();
  static final OfflineCacheService instance = OfflineCacheService._();

  // ── Config ─────────────────────────────────────────────────────────────────
  /// Maximum total cache size before LRU eviction kicks in (default 2 GB).
  static const int maxCacheBytes = 2 * 1024 * 1024 * 1024;

  Database? _db;
  Directory? _cacheDir;

  // Progress stream — UI listens to this for per-file progress updates.
  final _progressController =
      StreamController<CacheProgress>.broadcast();
  Stream<CacheProgress> get progress$ => _progressController.stream;

  // Active downloads (fileId → CancelToken flag).
  final _active = <String, bool>{};

  // ── Init ───────────────────────────────────────────────────────────────────

  Future<void> init() async {
    final support = await getApplicationSupportDirectory();
    _cacheDir = Directory('${support.path}/offline_cache');
    if (!await _cacheDir!.exists()) await _cacheDir!.create(recursive: true);

    final dbPath = p.join(support.path, 'offline_cache.db');
    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE cache_records (
          file_id         TEXT PRIMARY KEY,
          file_name       TEXT NOT NULL,
          local_path      TEXT NOT NULL,
          size_bytes      INTEGER NOT NULL,
          cached_at       INTEGER NOT NULL,
          last_accessed_at INTEGER NOT NULL
        )
      '''),
    );
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Whether [fileId] is fully cached locally.
  Future<bool> isCached(String fileId) async {
    await _ensureInit();
    final rows = await _db!.query('cache_records',
        where: 'file_id = ?', whereArgs: [fileId], limit: 1);
    if (rows.isEmpty) return false;
    final rec = CacheRecord.fromMap(rows.first);
    // Verify the physical file still exists.
    return File(rec.localPath).existsSync();
  }

  /// Get the local path for a cached file, or null if not cached.
  Future<String?> getLocalPath(String fileId) async {
    await _ensureInit();
    final rows = await _db!.query('cache_records',
        where: 'file_id = ?', whereArgs: [fileId], limit: 1);
    if (rows.isEmpty) return null;
    final rec = CacheRecord.fromMap(rows.first);
    final f = File(rec.localPath);
    if (!f.existsSync()) {
      await _db!.delete('cache_records',
          where: 'file_id = ?', whereArgs: [fileId]);
      return null;
    }
    // Touch last-accessed time.
    await _db!.update(
      'cache_records',
      {'last_accessed_at': DateTime.now().millisecondsSinceEpoch},
      where: 'file_id = ?',
      whereArgs: [fileId],
    );
    return f.path;
  }

  /// All cached records sorted by most-recently-used first.
  Future<List<CacheRecord>> listCached() async {
    await _ensureInit();
    final rows = await _db!.query('cache_records',
        orderBy: 'last_accessed_at DESC');
    return rows.map(CacheRecord.fromMap).toList();
  }

  /// Total bytes used by the offline cache.
  Future<int> totalCacheBytes() async {
    await _ensureInit();
    final result = await _db!
        .rawQuery('SELECT SUM(size_bytes) as total FROM cache_records');
    return (result.first['total'] as int?) ?? 0;
  }

  /// Download [messageId] → app-private cache.
  ///
  /// Emits [CacheProgress] events on [progress$].
  Future<void> cacheFile({
    required String fileId,
    required int messageId,
    required String fileName,
    required int sizeBytes,
    required TelegramAuthService auth,
  }) async {
    if (_active[fileId] == true) return; // Already downloading.
    _active[fileId] = true;

    _emit(fileId, 0.0, OfflineStatus.caching);

    try {
      await _ensureInit();

      // Evict LRU if needed to make room.
      await _evictIfNeeded(sizeBytes);

      final session = await auth.getSession();
      final uri =
          Uri.parse('${AppConstants.backendBaseUrl}/files/download/$messageId')
              .replace(queryParameters: {'session_string': session});

      // Stream download so we can track progress.
      final request = http.Request('GET', uri);
      final streamed = await request.send().timeout(const Duration(minutes: 30));

      if (streamed.statusCode >= 400) {
        throw Exception('Download failed: HTTP ${streamed.statusCode}');
      }

      final dest =
          File('${_cacheDir!.path}/${fileId}_${_sanitize(fileName)}');
      final sink = dest.openWrite();

      int received = 0;
      final total = streamed.contentLength ?? sizeBytes;

      await for (final chunk in streamed.stream) {
        if (_active[fileId] != true) {
          // Cancelled.
          await sink.close();
          await dest.delete().onError((_, __) => dest);
          _emit(fileId, 0.0, OfflineStatus.cloud);
          return;
        }
        sink.add(chunk);
        received += chunk.length;
        final pct = total > 0 ? received / total : 0.0;
        _emit(fileId, pct.clamp(0.0, 0.99), OfflineStatus.caching);
      }

      await sink.flush();
      await sink.close();

      final actualSize = await dest.length();
      final now = DateTime.now();

      await _db!.insert(
        'cache_records',
        CacheRecord(
          fileId: fileId,
          fileName: fileName,
          localPath: dest.path,
          sizeBytes: actualSize,
          cachedAt: now,
          lastAccessedAt: now,
        ).toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      _emit(fileId, 1.0, OfflineStatus.cached);
    } catch (e) {
      _emit(fileId, 0.0, OfflineStatus.failed, error: e.toString());
    } finally {
      _active.remove(fileId);
    }
  }

  /// Cancel an in-progress cache download.
  void cancelCache(String fileId) {
    _active[fileId] = false;
  }

  /// Remove a file from the local cache (but NOT from Telegram).
  Future<void> removeFromCache(String fileId) async {
    await _ensureInit();
    final rows = await _db!.query('cache_records',
        where: 'file_id = ?', whereArgs: [fileId], limit: 1);
    if (rows.isNotEmpty) {
      final rec = CacheRecord.fromMap(rows.first);
      await File(rec.localPath).delete().onError((_, __) => File(rec.localPath));
      await _db!.delete('cache_records',
          where: 'file_id = ?', whereArgs: [fileId]);
    }
    _emit(fileId, 0.0, OfflineStatus.cloud);
  }

  /// Clear the entire offline cache.
  Future<void> clearAll() async {
    await _ensureInit();
    final records = await listCached();
    for (final r in records) {
      await File(r.localPath).delete().onError((_, __) => File(r.localPath));
    }
    await _db!.delete('cache_records');
  }

  void dispose() {
    _progressController.close();
    _db?.close();
  }

  // ── Private ────────────────────────────────────────────────────────────────

  Future<void> _ensureInit() async {
    if (_db == null) await init();
  }

  void _emit(String fileId, double progress, OfflineStatus status,
      {String? error}) {
    if (!_progressController.isClosed) {
      _progressController.add(CacheProgress(
        fileId: fileId,
        progress: progress,
        status: status,
        error: error,
      ));
    }
  }

  /// LRU eviction: delete least-recently-used files until we are under quota.
  Future<void> _evictIfNeeded(int incomingBytes) async {
    final used = await totalCacheBytes();
    int available = maxCacheBytes - used;
    if (available >= incomingBytes) return;

    // Oldest records first.
    final rows = await _db!.query('cache_records',
        orderBy: 'last_accessed_at ASC');
    for (final row in rows) {
      final rec = CacheRecord.fromMap(row);
      await File(rec.localPath).delete().onError((_, __) => File(rec.localPath));
      await _db!.delete('cache_records',
          where: 'file_id = ?', whereArgs: [rec.fileId]);
      available += rec.sizeBytes;
      if (available >= incomingBytes) break;
    }
  }

  String _sanitize(String name) =>
      name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
}
