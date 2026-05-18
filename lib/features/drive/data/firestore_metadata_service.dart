import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import './models/cloud_file.dart';
import './models/cloud_folder.dart';

// ── Database helper ───────────────────────────────────────────────────────────

class _DB {
  static Database? _db;

  static Future<Database> get instance async {
    _db ??= await _open();
    return _db!;
  }


  static Future<Database> _open() async {
    final dbPath = p.join(await getDatabasesPath(), 'limitless_cloud.db');
    return openDatabase(
      dbPath,
      version: 3,
      onCreate: (db, version) async {
        await _createTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          try {
            await db.execute(
                'ALTER TABLE folders ADD COLUMN metaMessageId INTEGER DEFAULT 0');
          } catch (_) {}
        }
        if (oldVersion < 3) {
          // Add index on mimeType for fast category queries
          try {
            await db.execute(
                'CREATE INDEX IF NOT EXISTS idx_files_mime ON files(userId, mimeType, isTrashed)');
          } catch (_) {}
        }
      },
    );
  }

  static Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE folders (
        id             TEXT PRIMARY KEY,
        userId         TEXT NOT NULL,
        name           TEXT NOT NULL,
        parentId       TEXT,
        path           TEXT NOT NULL,
        color          TEXT DEFAULT "#4F8CFF",
        itemCount      INTEGER DEFAULT 0,
        isTrashed      INTEGER DEFAULT 0,
        metaMessageId  INTEGER DEFAULT 0,
        createdAt      TEXT NOT NULL,
        updatedAt      TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE files (
        id                 TEXT PRIMARY KEY,
        userId             TEXT NOT NULL,
        name               TEXT NOT NULL,
        folderId           TEXT,
        folderPath         TEXT DEFAULT "/",
        telegramMessageId  INTEGER NOT NULL,
        telegramFileId     TEXT NOT NULL,
        mimeType           TEXT,
        sizeBytes          INTEGER DEFAULT 0,
        extension          TEXT DEFAULT "",
        thumbnailPath      TEXT,
        isStarred          INTEGER DEFAULT 0,
        isTrashed          INTEGER DEFAULT 0,
        uploadedAt         TEXT NOT NULL,
        updatedAt          TEXT NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_files_mime ON files(userId, mimeType, isTrashed)');
  }
}

// ── UUID helper ───────────────────────────────────────────────────────────────

String _uuid() =>
    DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
    (1000 + (DateTime.now().millisecond % 9000)).toString();

// ── Converters ────────────────────────────────────────────────────────────────

CloudFolder _folderFromMap(Map<String, dynamic> m) => CloudFolder(
      id: m['id'] as String,
      name: m['name'] as String,
      parentFolderId: m['parentId'] as String?,
      path: m['path'] as String,
      color: m['color'] as String? ?? '#4F8CFF',
      itemCount: m['itemCount'] as int? ?? 0,
      metaMessageId: m['metaMessageId'] as int? ?? 0,
      createdAt: DateTime.parse(m['createdAt'] as String),
      updatedAt: DateTime.parse(m['updatedAt'] as String),
    );

CloudFile _fileFromMap(Map<String, dynamic> m) => CloudFile(
      id: m['id'] as String,
      name: m['name'] as String,
      folderId: m['folderId'] as String?,
      folderPath: m['folderPath'] as String? ?? '/',
      telegramMessageId: m['telegramMessageId'] as int,
      telegramFileId: m['telegramFileId'] as String,
      mimeType: m['mimeType'] as String?,
      sizeBytes: m['sizeBytes'] as int? ?? 0,
      extension: m['extension'] as String? ?? '',
      thumbnailPath: m['thumbnailPath'] as String?,
      isStarred: (m['isStarred'] as int? ?? 0) == 1,
      isTrashed: (m['isTrashed'] as int? ?? 0) == 1,
      uploadedAt: DateTime.parse(m['uploadedAt'] as String),
      updatedAt: DateTime.parse(m['updatedAt'] as String),
    );

// ── File category helper ──────────────────────────────────────────────────────

enum FileCategory { images, videos, audio, documents, others }

extension FileCategoryExt on FileCategory {
  String get label {
    switch (this) {
      case FileCategory.images:    return 'Images';
      case FileCategory.videos:    return 'Videos';
      case FileCategory.audio:     return 'Audio';
      case FileCategory.documents: return 'Documents';
      case FileCategory.others:    return 'Others';
    }
  }

  /// SQL WHERE fragment that matches this category's mime-types.
  /// Must be used with [userId] and isTrashed=0 already applied.
  String get mimeCondition {
    switch (this) {
      case FileCategory.images:
        return "mimeType LIKE 'image/%'";
      case FileCategory.videos:
        return "mimeType LIKE 'video/%'";
      case FileCategory.audio:
        return "mimeType LIKE 'audio/%'";
      case FileCategory.documents:
        return "(mimeType LIKE 'application/pdf' OR "
            "mimeType LIKE 'application/msword' OR "
            "mimeType LIKE 'application/vnd.openxmlformats%' OR "
            "mimeType LIKE 'application/vnd.ms-%' OR "
            "mimeType LIKE 'text/%')";
      case FileCategory.others:
        return "(mimeType NOT LIKE 'image/%' AND "
            "mimeType NOT LIKE 'video/%' AND "
            "mimeType NOT LIKE 'audio/%' AND "
            "mimeType NOT LIKE 'application/pdf' AND "
            "mimeType NOT LIKE 'application/msword' AND "
            "mimeType NOT LIKE 'application/vnd.openxmlformats%' AND "
            "mimeType NOT LIKE 'application/vnd.ms-%' AND "
            "mimeType NOT LIKE 'text/%')";
    }
  }
}

// ── Service ───────────────────────────────────────────────────────────────────

class LocalMetadataService {

  // ── Re-login / logout support ──────────────────────────────────────────────

  /// Wipe ALL local data for [userId].  Called on logout or before a fresh
  /// sync so stale records from a previous install don't block re-import.
  Future<void> clearUserData(String userId) async {
    final db = await _DB.instance;
    await db.delete('files',   where: 'userId = ?', whereArgs: [userId]);
    await db.delete('folders', where: 'userId = ?', whereArgs: [userId]);
  }

  // ── Folders ────────────────────────────────────────────────────────────────

  Future<CloudFolder> createFolder({
    required String userId,
    required String name,
    String? parentFolderId,
    String parentPath = '/',
    String color = '#4F8CFF',
    int metaMessageId = 0,
  }) async {
    final db = await _DB.instance;
    final now = DateTime.now().toIso8601String();
    final id = _uuid();
    final path = parentPath == '/' ? '/$name' : '$parentPath/$name';

    await db.insert('folders', {
      'id': id,
      'userId': userId,
      'name': name,
      'parentId': parentFolderId,
      'path': path,
      'color': color,
      'itemCount': 0,
      'isTrashed': 0,
      'metaMessageId': metaMessageId,
      'createdAt': now,
      'updatedAt': now,
    });

    if (parentFolderId != null) {
      await db.rawUpdate(
        'UPDATE folders SET itemCount = itemCount + 1, updatedAt = ? WHERE id = ?',
        [now, parentFolderId],
      );
    }

    return CloudFolder(
      id: id,
      name: name,
      parentFolderId: parentFolderId,
      path: path,
      color: color,
      metaMessageId: metaMessageId,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
  }

  /// Upsert a folder (used during sync — insert or update if already exists)
  Future<CloudFolder> upsertFolder({
    required String userId,
    required String id,
    required String name,
    String? parentFolderId,
    String parentPath = '/',
    String color = '#4F8CFF',
    int metaMessageId = 0,
  }) async {
    final db = await _DB.instance;
    final now = DateTime.now().toIso8601String();
    final path = parentPath == '/' ? '/$name' : '$parentPath/$name';

    final existing = await db.query('folders',
        where: 'id = ? AND userId = ?', whereArgs: [id, userId]);
    if (existing.isEmpty) {
      await db.insert('folders', {
        'id': id,
        'userId': userId,
        'name': name,
        'parentId': parentFolderId,
        'path': path,
        'color': color,
        'itemCount': 0,
        'isTrashed': 0,
        'metaMessageId': metaMessageId,
        'createdAt': now,
        'updatedAt': now,
      });
    } else {
      await db.update(
        'folders',
        {
          'name': name,
          'parentId': parentFolderId,
          'path': path,
          'color': color,
          'metaMessageId': metaMessageId,
          'updatedAt': now,
        },
        where: 'id = ? AND userId = ?',
        whereArgs: [id, userId],
      );
    }

    return CloudFolder(
      id: id,
      name: name,
      parentFolderId: parentFolderId,
      path: path,
      color: color,
      metaMessageId: metaMessageId,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
  }

  Future<void> updateFolderMetaMessageId({
    required String userId,
    required String folderId,
    required int metaMessageId,
  }) async {
    final db = await _DB.instance;
    await db.update(
      'folders',
      {'metaMessageId': metaMessageId, 'updatedAt': DateTime.now().toIso8601String()},
      where: 'id = ? AND userId = ?',
      whereArgs: [folderId, userId],
    );
  }

  Stream<List<CloudFolder>> getFolders({
    required String userId,
    String? parentFolderId,
  }) async* {
    final controller = StreamController<List<CloudFolder>>();
    Future<void> emit() async {
      final db = await _DB.instance;
      List<Map<String, dynamic>> rows;
      if (parentFolderId == null) {
        rows = await db.query(
          'folders',
          where: 'userId = ? AND parentId IS NULL AND isTrashed = 0',
          whereArgs: [userId],
          orderBy: 'name ASC',
        );
      } else {
        rows = await db.query(
          'folders',
          where: 'userId = ? AND parentId = ? AND isTrashed = 0',
          whereArgs: [userId, parentFolderId],
          orderBy: 'name ASC',
        );
      }
      controller.add(rows.map(_folderFromMap).toList());
    }

    await emit();
    yield* controller.stream;
    await controller.close();
  }

  Future<void> renameFolder({
    required String userId,
    required String folderId,
    required String newName,
  }) async {
    final db = await _DB.instance;
    await db.update(
      'folders',
      {'name': newName, 'updatedAt': DateTime.now().toIso8601String()},
      where: 'id = ? AND userId = ?',
      whereArgs: [folderId, userId],
    );
  }

  Future<void> trashFolder({required String userId, required String folderId}) async {
    final db = await _DB.instance;
    await db.update(
      'folders',
      {'isTrashed': 1, 'updatedAt': DateTime.now().toIso8601String()},
      where: 'id = ? AND userId = ?',
      whereArgs: [folderId, userId],
    );
  }

  Future<CloudFolder?> getFolderById({
    required String userId,
    required String folderId,
  }) async {
    final db = await _DB.instance;
    final rows = await db.query('folders',
        where: 'id = ? AND userId = ?', whereArgs: [folderId, userId]);
    if (rows.isEmpty) return null;
    return _folderFromMap(rows.first);
  }

  Future<void> deleteFolder({required String userId, required String folderId}) async {
    final db = await _DB.instance;
    await db.delete('files', where: 'folderId = ? AND userId = ?', whereArgs: [folderId, userId]);
    await db.delete('folders', where: 'id = ? AND userId = ?', whereArgs: [folderId, userId]);
  }

  // ── Files ──────────────────────────────────────────────────────────────────

  Future<CloudFile> saveFileMetadata({
    required String userId,
    required String name,
    String? folderId,
    String folderPath = '/',
    required int telegramMessageId,
    required String telegramFileId,
    String? mimeType,
    required int sizeBytes,
    required String extension,
    String? thumbnailPath,
  }) async {
    final db = await _DB.instance;
    final now = DateTime.now().toIso8601String();
    final id = _uuid();

    await db.insert('files', {
      'id': id,
      'userId': userId,
      'name': name,
      'folderId': folderId,
      'folderPath': folderPath,
      'telegramMessageId': telegramMessageId,
      'telegramFileId': telegramFileId,
      'mimeType': mimeType,
      'sizeBytes': sizeBytes,
      'extension': extension,
      'thumbnailPath': thumbnailPath,
      'isStarred': 0,
      'isTrashed': 0,
      'uploadedAt': now,
      'updatedAt': now,
    });

    if (folderId != null) {
      await db.rawUpdate(
        'UPDATE folders SET itemCount = itemCount + 1, updatedAt = ? WHERE id = ?',
        [now, folderId],
      );
    }

    return CloudFile(
      id: id,
      name: name,
      folderId: folderId,
      folderPath: folderPath,
      telegramMessageId: telegramMessageId,
      telegramFileId: telegramFileId,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      extension: extension,
      thumbnailPath: thumbnailPath,
      uploadedAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
  }

  Stream<List<CloudFile>> getFiles({
    required String userId,
    String? folderId,
    String sortBy = 'uploadedAt',
    bool descending = true,
  }) async* {
    final controller = StreamController<List<CloudFile>>();
    Future<void> emit() async {
      final db = await _DB.instance;
      final col = _sqlCol(sortBy);
      final dir = descending ? 'DESC' : 'ASC';
      List<Map<String, dynamic>> rows;
      if (folderId == null) {
        rows = await db.query(
          'files',
          where: 'userId = ? AND folderId IS NULL AND isTrashed = 0',
          whereArgs: [userId],
          orderBy: '$col $dir',
        );
      } else {
        rows = await db.query(
          'files',
          where: 'userId = ? AND folderId = ? AND isTrashed = 0',
          whereArgs: [userId, folderId],
          orderBy: '$col $dir',
        );
      }
      controller.add(rows.map(_fileFromMap).toList());
    }

    await emit();
    yield* controller.stream;
    await controller.close();
  }

  Stream<List<CloudFile>> getAllFiles({
    required String userId,
    bool starredOnly = false,
    bool trashedOnly = false,
  }) async* {
    final controller = StreamController<List<CloudFile>>();
    Future<void> emit() async {
      final db = await _DB.instance;
      List<Map<String, dynamic>> rows;
      if (starredOnly) {
        rows = await db.query('files',
            where: 'userId = ? AND isStarred = 1 AND isTrashed = 0',
            whereArgs: [userId],
            orderBy: 'uploadedAt DESC');
      } else if (trashedOnly) {
        rows = await db.query('files',
            where: 'userId = ? AND isTrashed = 1',
            whereArgs: [userId],
            orderBy: 'updatedAt DESC');
      } else {
        rows = await db.query('files',
            where: 'userId = ? AND isTrashed = 0',
            whereArgs: [userId],
            orderBy: 'uploadedAt DESC');
      }
      controller.add(rows.map(_fileFromMap).toList());
    }

    await emit();
    yield* controller.stream;
    await controller.close();
  }

  /// Get files filtered by category (images / videos / audio / docs / others)
  Stream<List<CloudFile>> getFilesByCategory({
    required String userId,
    required FileCategory category,
  }) async* {
    final controller = StreamController<List<CloudFile>>();
    Future<void> emit() async {
      final db = await _DB.instance;
      final mimeCond = category.mimeCondition;
      final rows = await db.rawQuery(
        'SELECT * FROM files WHERE userId = ? AND isTrashed = 0 AND $mimeCond ORDER BY uploadedAt DESC',
        [userId],
      );
      controller.add(rows.map(_fileFromMap).toList());
    }

    await emit();
    yield* controller.stream;
    await controller.close();
  }

  Future<void> moveFile({
    required String userId,
    required String fileId,
    required String? oldFolderId,
    required String? newFolderId,
    required String newFolderPath,
    required int fileSizeBytes,
  }) async {
    final db = await _DB.instance;
    final now = DateTime.now().toIso8601String();
    await db.update(
      'files',
      {'folderId': newFolderId, 'folderPath': newFolderPath, 'updatedAt': now},
      where: 'id = ? AND userId = ?',
      whereArgs: [fileId, userId],
    );
    if (oldFolderId != null) {
      await db.rawUpdate(
          'UPDATE folders SET itemCount = MAX(0, itemCount - 1), updatedAt = ? WHERE id = ?',
          [now, oldFolderId]);
    }
    if (newFolderId != null) {
      await db.rawUpdate(
          'UPDATE folders SET itemCount = itemCount + 1, updatedAt = ? WHERE id = ?',
          [now, newFolderId]);
    }
  }

  Future<CloudFile> copyFile({
    required String userId,
    required CloudFile sourceFile,
    required String? destinationFolderId,
    required String destinationFolderPath,
  }) =>
      saveFileMetadata(
        userId: userId,
        name: 'Copy of ${sourceFile.name}',
        folderId: destinationFolderId,
        folderPath: destinationFolderPath,
        telegramMessageId: sourceFile.telegramMessageId,
        telegramFileId: sourceFile.telegramFileId,
        mimeType: sourceFile.mimeType,
        sizeBytes: sourceFile.sizeBytes,
        extension: sourceFile.extension,
      );

  Future<void> toggleStar({
    required String userId,
    required String fileId,
    required bool isStarred,
  }) async {
    final db = await _DB.instance;
    await db.update(
      'files',
      {'isStarred': isStarred ? 1 : 0, 'updatedAt': DateTime.now().toIso8601String()},
      where: 'id = ? AND userId = ?',
      whereArgs: [fileId, userId],
    );
  }

  Future<void> renameFile({
    required String userId,
    required String fileId,
    required String newName,
  }) async {
    final db = await _DB.instance;
    await db.update(
      'files',
      {'name': newName, 'updatedAt': DateTime.now().toIso8601String()},
      where: 'id = ? AND userId = ?',
      whereArgs: [fileId, userId],
    );
  }

  Future<void> trashFile({
    required String userId,
    required String fileId,
    required String? folderId,
  }) async {
    final db = await _DB.instance;
    final now = DateTime.now().toIso8601String();
    await db.update(
      'files',
      {'isTrashed': 1, 'updatedAt': now},
      where: 'id = ? AND userId = ?',
      whereArgs: [fileId, userId],
    );
    if (folderId != null) {
      await db.rawUpdate(
          'UPDATE folders SET itemCount = MAX(0, itemCount - 1), updatedAt = ? WHERE id = ?',
          [now, folderId]);
    }
  }

  Future<void> deleteFile({
    required String userId,
    required String fileId,
    required int fileSizeBytes,
  }) async {
    final db = await _DB.instance;
    await db.delete('files', where: 'id = ? AND userId = ?', whereArgs: [fileId, userId]);
  }

  Future<List<CloudFile>> searchFiles({
    required String userId,
    required String query,
  }) async {
    final db = await _DB.instance;
    final rows = await db.query(
      'files',
      where: 'userId = ? AND isTrashed = 0 AND name LIKE ?',
      whereArgs: [userId, '%$query%'],
      orderBy: 'name ASC',
    );
    return rows.map(_fileFromMap).toList();
  }

  /// Returns all Telegram message IDs already stored locally for a user.
  Future<Set<int>> getExistingMessageIds(String userId) async {
    final db = await _DB.instance;
    final rows = await db.query(
      'files',
      columns: ['telegramMessageId'],
      where: 'userId = ?',
      whereArgs: [userId],
    );
    return rows.map((r) => r['telegramMessageId'] as int).toSet();
  }

  /// Returns all existing folder IDs for a user.
  Future<Set<String>> getExistingFolderIds(String userId) async {
    final db = await _DB.instance;
    final rows = await db.query(
      'folders',
      columns: ['id'],
      where: 'userId = ?',
      whereArgs: [userId],
    );
    return rows.map((r) => r['id'] as String).toSet();
  }

  Future<Map<String, dynamic>> getUserStats(String userId) async {
    final db = await _DB.instance;
    final result = await db.rawQuery(
      'SELECT COALESCE(SUM(sizeBytes), 0) as totalStorageUsed, COUNT(*) as fileCount FROM files WHERE userId = ? AND isTrashed = 0',
      [userId],
    );
    return result.isNotEmpty ? Map<String, dynamic>.from(result.first) : {};
  }

  // ── SQL column name mapper ─────────────────────────────────────────────────
  static String _sqlCol(String sortBy) {
    switch (sortBy) {
      case 'name': return 'name';
      case 'sizeBytes': return 'sizeBytes';
      case 'extension': return 'extension';
      default: return 'uploadedAt';
    }
  }
}

// ── Provider ──────────────────────────────────────────────────────────────────

typedef FirestoreMetadataService = LocalMetadataService;

final firestoreServiceProvider = Provider<LocalMetadataService>((ref) {
  return LocalMetadataService();
});
