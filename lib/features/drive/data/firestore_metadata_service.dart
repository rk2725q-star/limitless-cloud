import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
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
      version: 6,
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
        if (oldVersion < 4) {
          // Track permanently deleted folder IDs so sync won't re-import them
          try {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS deleted_folders (
                id      TEXT NOT NULL,
                userId  TEXT NOT NULL,
                PRIMARY KEY (id, userId)
              )
            ''');
          } catch (_) {}
        }
        if (oldVersion < 5) {
          // Add chunkMessageIds column for chunked (>2 GB) file support
          try {
            await db.execute(
                'ALTER TABLE files ADD COLUMN chunkMessageIds TEXT DEFAULT ""');
          } catch (_) {}
        }
        if (oldVersion < 6) {
          try {
            await db.execute(
                'ALTER TABLE files ADD COLUMN telegramThumbnailId INTEGER');
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
        telegramThumbnailId INTEGER,
        isStarred          INTEGER DEFAULT 0,
        isTrashed          INTEGER DEFAULT 0,
        chunkMessageIds    TEXT DEFAULT "",
        uploadedAt         TEXT NOT NULL,
        updatedAt          TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS deleted_folders (
        id      TEXT NOT NULL,
        userId  TEXT NOT NULL,
        PRIMARY KEY (id, userId)
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
      telegramThumbnailId: m['telegramThumbnailId'] as int?,
      isStarred: (m['isStarred'] as int? ?? 0) == 1,
      isTrashed: (m['isTrashed'] as int? ?? 0) == 1,
      chunkMessageIds: CloudFile.parseChunkIds(m['chunkMessageIds'] as String?),
      uploadedAt: DateTime.parse(m['uploadedAt'] as String),
      updatedAt: DateTime.parse(m['updatedAt'] as String),
    );

// ── File category helper ──────────────────────────────────────────────────────

enum FileCategory { images, videos, audio, documents, others }

extension FileCategoryExt on FileCategory {
  String get label {
    switch (this) {
      case FileCategory.images:    return 'Gallery';
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
    await db.delete('files',          where: 'userId = ?', whereArgs: [userId]);
    await db.delete('folders',        where: 'userId = ?', whereArgs: [userId]);
    await db.delete('deleted_folders', where: 'userId = ?', whereArgs: [userId]);
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

  /// Returns all active folders for a user as a flat list
  Future<List<CloudFolder>> getAllFoldersList(String userId) async {
    final db = await _DB.instance;
    final rows = await db.query(
      'folders',
      where: 'userId = ? AND isTrashed = 0',
      whereArgs: [userId],
    );
    return rows.map(_folderFromMap).toList();
  }

  /// Ensures that all directory levels for [folderPath] exist in SQLite.
  /// Example: '/Anime/AOT/S01' -> ensures '/Anime', '/Anime/AOT', '/Anime/AOT/S01' exist.
  /// Returns the folder ID of the innermost folder, or null if [folderPath] is '/' or empty.
  Future<String?> ensureFolderHierarchyExists({
    required String userId,
    required String folderPath,
    Map<String, String>? pathCache,
  }) async {
    if (folderPath.isEmpty || folderPath == '/') return null;

    final trimmed = folderPath.replaceAll(RegExp(r'^/+|/+$'), '');
    if (trimmed.isEmpty) return null;

    final segments = trimmed.split('/');
    String currentPath = '';
    String? currentParentId;

    for (final seg in segments) {
      if (seg.trim().isEmpty) continue;
      currentPath = '$currentPath/$seg';

      if (pathCache != null && pathCache.containsKey(currentPath)) {
        currentParentId = pathCache[currentPath];
        continue;
      }

      final db = await _DB.instance;
      final existing = await db.query(
        'folders',
        where: 'userId = ? AND path = ? AND isTrashed = 0',
        whereArgs: [userId, currentPath],
        limit: 1,
      );

      if (existing.isNotEmpty) {
        currentParentId = existing.first['id'] as String;
      } else {
        final parentPath = currentPath.contains('/')
            ? (currentPath.substring(0, currentPath.lastIndexOf('/')).isEmpty
                ? '/'
                : currentPath.substring(0, currentPath.lastIndexOf('/')))
            : '/';
        final newFolder = await createFolder(
          userId: userId,
          name: seg,
          parentFolderId: currentParentId,
          parentPath: parentPath,
        );
        currentParentId = newFolder.id;
      }

      if (pathCache != null) {
        pathCache[currentPath] = currentParentId;
      }
    }

    return currentParentId;
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
    // Also delete all nested sub-folders recursively using a loop
    final stack = [folderId];
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      // Collect child folder IDs
      final children = await db.query('folders',
          columns: ['id'],
          where: 'parentId = ? AND userId = ?',
          whereArgs: [current, userId]);
      for (final c in children) { stack.add(c['id'] as String); }
      // Delete files in this folder
      await db.delete('files', where: 'folderId = ? AND userId = ?', whereArgs: [current, userId]);
      // Delete this folder
      await db.delete('folders', where: 'id = ? AND userId = ?', whereArgs: [current, userId]);
      // Record as permanently deleted
      await db.insert(
        'deleted_folders',
        {'id': current, 'userId': userId},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
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
    int? telegramThumbnailId,
    List<int> chunkMessageIds = const [],
  }) async {
    final db = await _DB.instance;
    final now = DateTime.now().toIso8601String();
    final id = _uuid();

    // Guard: Never save internal chunk parts as standalone file records
    if (name.startsWith('lc_chunk_') || (name.contains('.part') && name.contains('of'))) {
      return CloudFile(
        id: id,
        name: name,
        folderPath: folderPath,
        telegramMessageId: telegramMessageId,
        telegramFileId: telegramFileId,
        sizeBytes: sizeBytes,
        extension: extension,
        uploadedAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
    }

    // ── DEDUPLICATION CHECK 1: Existing Telegram Message ID ───────────────────
    if (telegramMessageId > 0) {
      final existingByMsg = await db.query(
        'files',
        where: 'userId = ? AND telegramMessageId = ? AND isTrashed = 0',
        whereArgs: [userId, telegramMessageId],
      );
      if (existingByMsg.isNotEmpty) {
        final existing = existingByMsg.first;
        final existingId = existing['id'] as String;
        final updates = <String, dynamic>{
          'name': name,
          'folderId': folderId,
          'folderPath': folderPath,
          'sizeBytes': sizeBytes,
          'mimeType': mimeType,
          'extension': extension,
          'updatedAt': now,
        };
        if (thumbnailPath != null && thumbnailPath.isNotEmpty) {
          updates['thumbnailPath'] = thumbnailPath;
        }
        if (telegramThumbnailId != null && telegramThumbnailId > 0) {
          updates['telegramThumbnailId'] = telegramThumbnailId;
        }
        if (chunkMessageIds.isNotEmpty) {
          updates['chunkMessageIds'] = jsonEncode(chunkMessageIds);
        }
        await db.update('files', updates, where: 'id = ?', whereArgs: [existingId]);
        final updated = await db.query('files', where: 'id = ?', whereArgs: [existingId]);
        return _fileFromMap(updated.first);
      }
    }

    // ── DEDUPLICATION CHECK 2: Existing Offline-Pending or Matching File ───────
    final existingByName = await db.query(
      'files',
      where: 'userId = ? AND name = ? AND folderPath = ? AND isTrashed = 0',
      whereArgs: [userId, name, folderPath],
    );
    if (existingByName.isNotEmpty) {
      final existing = existingByName.first;
      final existingId = existing['id'] as String;
      final existingMsgId = existing['telegramMessageId'] as int? ?? 0;

      // Update existing record if it is pending OR if incoming has cloud msgId
      if (existingMsgId <= 0 || telegramMessageId > 0) {
        final updates = <String, dynamic>{
          if (telegramMessageId > 0) 'telegramMessageId': telegramMessageId,
          if (telegramMessageId > 0) 'telegramFileId': telegramFileId,
          'folderId': folderId,
          'sizeBytes': sizeBytes,
          'mimeType': mimeType,
          'extension': extension,
          'updatedAt': now,
        };
        if (thumbnailPath != null && thumbnailPath.isNotEmpty) {
          updates['thumbnailPath'] = thumbnailPath;
        }
        if (telegramThumbnailId != null && telegramThumbnailId > 0) {
          updates['telegramThumbnailId'] = telegramThumbnailId;
        }
        if (chunkMessageIds.isNotEmpty) {
          updates['chunkMessageIds'] = jsonEncode(chunkMessageIds);
        }
        await db.update('files', updates, where: 'id = ?', whereArgs: [existingId]);
        final updated = await db.query('files', where: 'id = ?', whereArgs: [existingId]);
        return _fileFromMap(updated.first);
      }
    }

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
      'telegramThumbnailId': telegramThumbnailId,
      'isStarred': 0,
      'isTrashed': 0,
      'chunkMessageIds': CloudFile(
        id: id, name: name, folderPath: folderPath,
        telegramMessageId: telegramMessageId, telegramFileId: telegramFileId,
        sizeBytes: sizeBytes, extension: extension,
        uploadedAt: DateTime.now(), updatedAt: DateTime.now(),
        chunkMessageIds: chunkMessageIds,
      ).chunkIdsJson,
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
      telegramThumbnailId: telegramThumbnailId,
      uploadedAt: DateTime.parse(now),
      updatedAt: DateTime.parse(now),
      chunkMessageIds: chunkMessageIds,
    );
  }

  Future<void> updateThumbnailPath(String fileId, String localPath) async {
    final db = await _DB.instance;
    final now = DateTime.now().toIso8601String();
    await db.update(
      'files',
      {
        'thumbnailPath': localPath,
        'updatedAt': now,
      },
      where: 'id = ?',
      whereArgs: [fileId],
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
      await deduplicateFiles(userId);
      final db = await _DB.instance;
      final col = _sqlCol(sortBy);
      final dir = descending ? 'DESC' : 'ASC';
      List<Map<String, dynamic>> rows;
      if (folderId == null) {
        rows = await db.query(
          'files',
          where: "userId = ? AND folderId IS NULL AND isTrashed = 0 AND name NOT LIKE 'lc_chunk_%' AND name NOT LIKE '%.part%of%'",
          whereArgs: [userId],
          orderBy: '$col $dir',
        );
      } else {
        rows = await db.query(
          'files',
          where: "userId = ? AND folderId = ? AND isTrashed = 0 AND name NOT LIKE 'lc_chunk_%' AND name NOT LIKE '%.part%of%'",
          whereArgs: [userId, folderId],
          orderBy: '$col $dir',
        );
      }
      final rawList = rows.map(_fileFromMap).toList();
      final seen = <String>{};
      final deduped = <CloudFile>[];
      for (final f in rawList) {
        final key = '${f.folderPath}/${f.name}';
        if (seen.add(key)) {
          deduped.add(f);
        }
      }
      controller.add(deduped);
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
      await deduplicateFiles(userId);
      final db = await _DB.instance;
      List<Map<String, dynamic>> rows;
      if (starredOnly) {
        rows = await db.query('files',
            where: "userId = ? AND isStarred = 1 AND isTrashed = 0 AND name NOT LIKE 'lc_chunk_%' AND name NOT LIKE '%.part%of%'",
            whereArgs: [userId],
            orderBy: 'uploadedAt DESC');
      } else if (trashedOnly) {
        rows = await db.query('files',
            where: "userId = ? AND isTrashed = 1 AND name NOT LIKE 'lc_chunk_%' AND name NOT LIKE '%.part%of%'",
            whereArgs: [userId],
            orderBy: 'updatedAt DESC');
      } else {
        rows = await db.query('files',
            where: "userId = ? AND isTrashed = 0 AND name NOT LIKE 'lc_chunk_%' AND name NOT LIKE '%.part%of%'",
            whereArgs: [userId],
            orderBy: 'uploadedAt DESC');
      }
      final rawList = rows.map(_fileFromMap).toList();
      final seen = <String>{};
      final deduped = <CloudFile>[];
      for (final f in rawList) {
        final key = '${f.folderPath}/${f.name}';
        if (seen.add(key)) {
          deduped.add(f);
        }
      }
      controller.add(deduped);
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
      await deduplicateFiles(userId);
      final db = await _DB.instance;
      final mimeCond = category.mimeCondition;
      final rows = await db.rawQuery(
        "SELECT * FROM files WHERE userId = ? AND isTrashed = 0 AND name NOT LIKE 'lc_chunk_%' AND name NOT LIKE '%.part%of%' AND $mimeCond ORDER BY uploadedAt DESC",
        [userId],
      );
      final rawList = rows.map(_fileFromMap).toList();
      final seen = <String>{};
      final deduped = <CloudFile>[];
      for (final f in rawList) {
        final key = '${f.folderPath}/${f.name}';
        if (seen.add(key)) {
          deduped.add(f);
        }
      }
      controller.add(deduped);
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
        chunkMessageIds: sourceFile.chunkMessageIds,
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

  /// Returns all Telegram message IDs already stored locally for a user,
  /// including primary message IDs and chunk message IDs of multipart files.
  Future<Set<int>> getExistingMessageIds(String userId) async {
    final db = await _DB.instance;
    final rows = await db.query(
      'files',
      columns: ['telegramMessageId', 'chunkMessageIds'],
      where: 'userId = ?',
      whereArgs: [userId],
    );
    final ids = <int>{};
    for (final r in rows) {
      final primaryId = r['telegramMessageId'] as int?;
      if (primaryId != null) ids.add(primaryId);
      final rawChunks = r['chunkMessageIds'] as String?;
      if (rawChunks != null && rawChunks.isNotEmpty) {
        try {
          final list = (jsonDecode(rawChunks) as List<dynamic>).cast<int>();
          ids.addAll(list);
        } catch (_) {}
      }
    }
    return ids;
  }

  /// Returns all active file names already backed up for this user.
  Future<Set<String>> getExistingFileNames(String userId) async {
    final db = await _DB.instance;
    final rows = await db.query(
      'files',
      columns: ['name'],
      where: 'userId = ? AND isTrashed = 0',
      whereArgs: [userId],
    );
    return rows.map((r) => r['name'] as String).toSet();
  }

  /// Purges any accidentally imported chunk files from the local database.
  Future<int> purgeChunkGhostFiles(String userId) async {
    final db = await _DB.instance;
    // 1. Delete by name pattern lc_chunk_% or .part%of%
    final count1 = await db.delete(
      'files',
      where: "userId = ? AND (name LIKE 'lc_chunk_%' OR name LIKE '%.part%of%')",
      whereArgs: [userId],
    );
    // 2. Also delete any file record whose telegramMessageId is in another file's chunkMessageIds
    final chunkedFiles = await db.query(
      'files',
      columns: ['chunkMessageIds'],
      where: "userId = ? AND chunkMessageIds != '' AND chunkMessageIds IS NOT NULL",
      whereArgs: [userId],
    );
    final allChunkIds = <int>{};
    for (final row in chunkedFiles) {
      final raw = row['chunkMessageIds'] as String?;
      if (raw != null && raw.isNotEmpty) {
        try {
          final list = (jsonDecode(raw) as List<dynamic>).cast<int>();
          if (list.length > 1) {
            allChunkIds.addAll(list.sublist(1));
          }
        } catch (_) {}
      }
    }
    int count2 = 0;
    if (allChunkIds.isNotEmpty) {
      final placeholders = List.filled(allChunkIds.length, '?').join(',');
      count2 = await db.delete(
        'files',
        where: 'userId = ? AND telegramMessageId IN ($placeholders)',
        whereArgs: [userId, ...allChunkIds],
      );
    }
    final total = count1 + count2;
    if (total > 0) {
      await recalculateFolderItemCounts(userId);
    }
    return total;
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

  /// Returns folder IDs that were permanently deleted by this user.
  /// Used during sync to prevent re-importing folders deleted locally.
  Future<Set<String>> getDeletedFolderIds(String userId) async {
    final db = await _DB.instance;
    final rows = await db.query(
      'deleted_folders',
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

  /// Returns all files that were saved locally when offline and are pending cloud backup.
  Future<List<CloudFile>> getPendingOfflineFiles(String userId) async {
    final db = await _DB.instance;
    final rows = await db.query(
      'files',
      where: '(userId = ? OR userId = "" OR userId IS NULL) AND telegramMessageId <= 0 AND telegramFileId NOT LIKE "offline_uploading_%" AND isTrashed = 0',
      whereArgs: [userId],
      orderBy: 'uploadedAt ASC',
    );
    return rows.map(_fileFromMap).toList();
  }

  /// Returns an already-uploaded cloud file with matching userId, name, and folderPath.
  Future<CloudFile?> getUploadedFileByName({
    required String userId,
    required String name,
    required String folderPath,
  }) async {
    final db = await _DB.instance;
    final rows = await db.query(
      'files',
      where: '(userId = ? OR userId = "" OR userId IS NULL) AND name = ? AND folderPath = ? AND telegramMessageId > 0 AND isTrashed = 0',
      whereArgs: [userId, name, folderPath],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fileFromMap(rows.first);
  }

  /// Marks a file as currently uploading in background so other queries don't pick it up.
  Future<void> markFileUploading(String fileId) async {
    final db = await _DB.instance;
    await db.update(
      'files',
      {'telegramFileId': 'offline_uploading_$fileId'},
      where: 'id = ?',
      whereArgs: [fileId],
    );
  }

  /// Resets uploading files back to pending (e.g. if an upload failed or on app start).
  Future<void> resetUploadingFiles(String userId) async {
    final db = await _DB.instance;
    await db.rawUpdate('''
      UPDATE files
      SET telegramFileId = 'offline_pending_' || id
      WHERE userId = ? AND telegramMessageId <= 0 AND telegramFileId LIKE 'offline_uploading_%'
    ''', [userId]);
  }

  /// Scans files table for any duplicate rows (same userId + name + folderPath, or same msgId > 0)
  /// and purges duplicate rows so each file exists exactly once.
  Future<int> deduplicateFiles(String userId) async {
    try {
      final db = await _DB.instance;
      final rows = await db.rawQuery('''
        SELECT id, name, folderPath, telegramMessageId, thumbnailPath, updatedAt, uploadedAt
        FROM files
        WHERE userId = ? AND isTrashed = 0
        ORDER BY CASE WHEN telegramMessageId > 0 THEN 1 ELSE 0 END DESC,
                 CASE WHEN thumbnailPath IS NOT NULL AND thumbnailPath != '' THEN 1 ELSE 0 END DESC,
                 updatedAt DESC
      ''', [userId]);

      final seenKeys = <String>{};
      final seenMsgIds = <int>{};
      final idsToDelete = <String>[];

      for (final r in rows) {
        final id = r['id'] as String;
        final name = r['name'] as String;
        final folderPath = r['folderPath'] as String? ?? '/';
        final msgId = r['telegramMessageId'] as int? ?? 0;
        final nameKey = '$folderPath/$name';

        bool isDup = false;
        if (msgId > 0 && seenMsgIds.contains(msgId)) {
          isDup = true;
        } else if (seenKeys.contains(nameKey)) {
          isDup = true;
        }

        if (isDup) {
          idsToDelete.add(id);
        } else {
          seenKeys.add(nameKey);
          if (msgId > 0) seenMsgIds.add(msgId);
        }
      }

      for (final dupId in idsToDelete) {
        await db.delete('files', where: 'id = ?', whereArgs: [dupId]);
      }

      // ── Always reconcile folder counters after dedup ─────────────────────────
      // Prevents itemCount drift caused by sync retries, chunk ghost rows, or
      // duplicates being removed without adjusting the parent folder counter.
      if (idsToDelete.isNotEmpty) {
        await recalculateFolderItemCounts(userId);
      }

      return idsToDelete.length;
    } catch (e) {
      debugPrint('[LocalMetadataService] deduplicateFiles error: $e');
      return 0;
    }
  }

  /// Recalculates every folder's itemCount from actual files + subfolders.
  ///
  /// Counts both:
  ///  - Direct non-trashed files inside the folder (excluding chunk/part artifacts)
  ///  - Direct non-trashed subfolders inside the folder
  ///
  /// This is the authoritative fix for count drift — it never relies on
  /// incremental +1 / -1 counters that can de-sync after failed uploads,
  /// multi-device sync, chunk ghost rows, or interrupted operations.
  Future<void> recalculateFolderItemCounts(String userId) async {
    try {
      final db = await _DB.instance;
      await db.rawUpdate('''
        UPDATE folders
        SET itemCount = (
          SELECT COUNT(*)
          FROM files
          WHERE files.folderId = folders.id
            AND files.userId   = folders.userId
            AND files.isTrashed = 0
            AND files.name NOT LIKE 'lc_chunk_%'
            AND files.name NOT LIKE '%.part%of%'
        ) + (
          SELECT COUNT(*)
          FROM folders AS sub
          WHERE sub.parentId  = folders.id
            AND sub.userId    = folders.userId
            AND sub.isTrashed = 0
        )
        WHERE folders.userId = ?
      ''', [userId]);
    } catch (e) {
      debugPrint('[LocalMetadataService] recalculateFolderItemCounts error: $e');
    }
  }

  /// Updates an offline file record after it has been safely uploaded to Telegram.
  Future<void> markFileUploaded({
    required String fileId,
    required String userId,
    required int telegramMessageId,
    required String telegramFileId,
    List<int> chunkMessageIds = const [],
    String? permanentThumbPath,
  }) async {
    final db = await _DB.instance;
    final now = DateTime.now().toIso8601String();

    // 1. Check if another row already has this telegramMessageId (race condition with syncFromTelegram)
    final existingWithMsgId = await db.query(
      'files',
      where: 'userId = ? AND telegramMessageId = ? AND id != ? AND isTrashed = 0',
      whereArgs: [userId, telegramMessageId, fileId],
    );
    if (existingWithMsgId.isNotEmpty) {
      final winnerId = existingWithMsgId.first['id'] as String;
      if (permanentThumbPath != null) {
        await db.update(
          'files',
          {'thumbnailPath': permanentThumbPath, 'updatedAt': now},
          where: 'id = ?',
          whereArgs: [winnerId],
        );
      }
      await db.delete('files', where: 'id = ?', whereArgs: [fileId]);
      await deduplicateFiles(userId);
      return;
    }

    final updates = <String, dynamic>{
      'telegramMessageId': telegramMessageId,
      'telegramFileId': telegramFileId,
      'chunkMessageIds': jsonEncode(chunkMessageIds),
      'updatedAt': now,
    };
    if (permanentThumbPath != null) {
      updates['thumbnailPath'] = permanentThumbPath;
    }
    await db.update(
      'files',
      updates,
      where: 'id = ? AND userId = ?',
      whereArgs: [fileId, userId],
    );

    await deduplicateFiles(userId);
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
