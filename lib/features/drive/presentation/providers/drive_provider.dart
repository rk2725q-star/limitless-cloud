import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../auth/data/telegram_auth_service.dart';
import '../../data/models/cloud_file.dart';
import '../../data/models/cloud_folder.dart';
import '../../data/firestore_metadata_service.dart';
import '../../data/telegram_storage_service.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/utils/file_utils.dart';
import 'package:mime/mime.dart';

// ── Upload State ──────────────────────────────────────────────────────────────

class UploadTask {
  final String fileName;
  final double progress;
  final bool isComplete;
  final bool hasError;
  final String? error;

  UploadTask({
    required this.fileName,
    required this.progress,
    this.isComplete = false,
    this.hasError = false,
    this.error,
  });

  UploadTask copyWith({
    String? fileName,
    double? progress,
    bool? isComplete,
    bool? hasError,
    String? error,
  }) {
    return UploadTask(
      fileName: fileName ?? this.fileName,
      progress: progress ?? this.progress,
      isComplete: isComplete ?? this.isComplete,
      hasError: hasError ?? this.hasError,
      error: error ?? this.error,
    );
  }
}

// ── Drive State ────────────────────────────────────────────────────────────────

class DriveState {
  final bool isGridView;
  final String sortBy;
  final bool sortDescending;
  final List<UploadTask> uploadTasks;
  final List<String> selectedFileIds;
  final bool isSelectionMode;
  final bool isSyncing;

  DriveState({
    this.isGridView = true,
    this.sortBy = 'uploadedAt',
    this.sortDescending = true,
    this.uploadTasks = const [],
    this.selectedFileIds = const [],
    this.isSelectionMode = false,
    this.isSyncing = false,
  });

  DriveState copyWith({
    bool? isGridView,
    String? sortBy,
    bool? sortDescending,
    List<UploadTask>? uploadTasks,
    List<String>? selectedFileIds,
    bool? isSelectionMode,
    bool? isSyncing,
  }) {
    return DriveState(
      isGridView: isGridView ?? this.isGridView,
      sortBy: sortBy ?? this.sortBy,
      sortDescending: sortDescending ?? this.sortDescending,
      uploadTasks: uploadTasks ?? this.uploadTasks,
      selectedFileIds: selectedFileIds ?? this.selectedFileIds,
      isSelectionMode: isSelectionMode ?? this.isSelectionMode,
      isSyncing: isSyncing ?? this.isSyncing,
    );
  }
}

// ── Drive Notifier ─────────────────────────────────────────────────────────────

class DriveNotifier extends StateNotifier<DriveState> {
  final FirestoreMetadataService _firestoreService;
  final TelegramStorageService _telegramService;
  final Ref _ref;

  DriveNotifier(this._firestoreService, this._telegramService, this._ref)
      : super(DriveState()) {
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final viewMode = prefs.getString(AppConstants.keyViewMode);
    final sortMode = prefs.getString(AppConstants.keySortMode) ?? 'uploadedAt';
    state = state.copyWith(
      isGridView: viewMode != 'list',
      sortBy: sortMode,
    );
  }

  Future<String?> get _userId async {
    final authService = _ref.read(telegramAuthServiceProvider);
    final profile = await authService.getProfile();
    final uid = profile['userId'] ?? '';
    return uid.isEmpty ? null : uid;
  }

  // ── View Mode ─────────────────────────────────────────────────────────────

  Future<void> toggleViewMode() async {
    final newMode = !state.isGridView;
    state = state.copyWith(isGridView: newMode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.keyViewMode, newMode ? 'grid' : 'list');
  }

  // ── Sort ──────────────────────────────────────────────────────────────────

  Future<void> setSortBy(String sortBy) async {
    final descending = sortBy == state.sortBy ? !state.sortDescending : true;
    state = state.copyWith(sortBy: sortBy, sortDescending: descending);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.keySortMode, sortBy);
  }

  // ── Selection Mode ────────────────────────────────────────────────────────

  void toggleSelection(String fileId) {
    final selected = [...state.selectedFileIds];
    if (selected.contains(fileId)) {
      selected.remove(fileId);
    } else {
      selected.add(fileId);
    }
    state = state.copyWith(
      selectedFileIds: selected,
      isSelectionMode: selected.isNotEmpty,
    );
  }

  void clearSelection() {
    state = state.copyWith(selectedFileIds: [], isSelectionMode: false);
  }

  void selectAll(List<CloudFile> files) {
    state = state.copyWith(
      selectedFileIds: files.map((f) => f.id).toList(),
      isSelectionMode: true,
    );
  }

  // ── Upload ────────────────────────────────────────────────────────────────

  Future<void> uploadFiles({
    String? folderId,
    String folderPath = '/',
  }) async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) return;

    final userId = await _userId;
    if (userId == null) return;

    for (final pickedFile in result.files) {
      if (pickedFile.path == null) continue;
      final file = File(pickedFile.path!);
      final fileName = pickedFile.name;
      final extension = FileUtils.getExtension(fileName);
      final mimeType = lookupMimeType(pickedFile.path!) ?? 'application/octet-stream';

      final task = UploadTask(fileName: fileName, progress: 0.0);
      state = state.copyWith(uploadTasks: [...state.uploadTasks, task]);

      try {
        final messageId = await _telegramService.uploadFile(
          file,
          folderId: folderId,
          folderPath: folderPath,
          onProgress: (progress) {
            final tasks = state.uploadTasks.toList();
            final idx = tasks.indexWhere((t) => t.fileName == fileName);
            if (idx >= 0) {
              tasks[idx] = tasks[idx].copyWith(progress: progress);
              state = state.copyWith(uploadTasks: tasks);
            }
          },
        );

        await _firestoreService.saveFileMetadata(
          userId: userId,
          name: fileName,
          folderId: folderId,
          folderPath: folderPath,
          telegramMessageId: messageId,
          telegramFileId: messageId.toString(),
          mimeType: mimeType,
          sizeBytes: pickedFile.size,
          extension: extension,
        );

        final tasks = state.uploadTasks.toList();
        final idx = tasks.indexWhere((t) => t.fileName == fileName);
        if (idx >= 0) {
          tasks[idx] = tasks[idx].copyWith(isComplete: true, progress: 1.0);
          state = state.copyWith(uploadTasks: tasks);
        }

        _invalidateAll(folderId);
      } catch (e) {
        final tasks = state.uploadTasks.toList();
        final idx = tasks.indexWhere((t) => t.fileName == fileName);
        if (idx >= 0) {
          tasks[idx] = tasks[idx].copyWith(hasError: true, error: e.toString());
          state = state.copyWith(uploadTasks: tasks);
        }
      }

      await Future.delayed(const Duration(seconds: 2));
      final tasks = state.uploadTasks.toList();
      tasks.removeWhere((t) => t.fileName == fileName && (t.isComplete || t.hasError));
      state = state.copyWith(uploadTasks: tasks);
    }
  }

  // ── Sync from Telegram ────────────────────────────────────────────────────

  /// Full sync: restores both folder structure AND files from Telegram.
  ///
  /// Strategy:
  ///   • Always fetch the full file list from Telegram (source of truth).
  ///   • Compare against local DB to find NEW files/folders only.
  ///   • On fresh login (DB empty for this user) perform a complete wipe +
  ///     reimport so a user re-logging in with the same number always
  ///     sees their complete drive.
  ///   • On subsequent opens, only import what is missing (incremental).
  ///
  /// Returns: (foldersImported, filesImported)
  Future<({int folders, int files})> syncFromTelegram() async {
    final userId = await _userId;
    if (userId == null) return (folders: 0, files: 0);

    state = state.copyWith(isSyncing: true);

    try {
      int foldersImported = 0;
      int filesImported = 0;

      final authService = _ref.read(telegramAuthServiceProvider);

      // ── If user just logged in (after logout), wipe stale local DB ─────────
      final needsWipe = await authService.needsDbResync();
      if (needsWipe) {
        await _firestoreService.clearUserData(userId);
        await authService.clearResyncFlag();
      }

      // ── Check current DB state ─────────────────────────────────────────────
      final existingMsgIds     = await _firestoreService.getExistingMessageIds(userId);
      final existingFolderIds  = await _firestoreService.getExistingFolderIds(userId);

      // ── STEP 1: Restore folder structure ─────────────────────────────────
      final folderMetas = await _telegramService.listFolderMeta();
      if (folderMetas.isNotEmpty) {
        final sorted = _sortFoldersByDepth(folderMetas);
        for (final meta in sorted) {
          if (existingFolderIds.contains(meta.id)) continue;

          String parentPath = '/';
          if (meta.parentId != null && meta.parentId!.isNotEmpty) {
            final parentFolder = await _firestoreService.getFolderById(
              userId: userId, folderId: meta.parentId!);
            if (parentFolder != null) parentPath = parentFolder.path;
          }

          await _firestoreService.upsertFolder(
            userId: userId, id: meta.id, name: meta.name,
            parentFolderId: meta.parentId, parentPath: parentPath,
            color: meta.color, metaMessageId: meta.metaMessageId,
          );
          foldersImported++;
        }
      }

      // ── STEP 2: Restore files ─────────────────────────────────────────────
      final telegramFiles = await _telegramService.listFiles();
      if (telegramFiles.isNotEmpty) {
        for (final tf in telegramFiles) {
          if (existingMsgIds.contains(tf.messageId)) continue;

          String? folderId;
          String folderPath = '/';
          final meta = TelegramStorageService.parseFileCaption(tf.caption);
          if (meta != null) {
            folderId   = meta['fi'] as String?;
            folderPath = meta['fp'] as String? ?? '/';
          }

          if (folderId != null) {
            final folder = await _firestoreService.getFolderById(
                userId: userId, folderId: folderId);
            if (folder == null) { folderId = null; folderPath = '/'; }
          }

          final ext = tf.fileName.contains('.')
              ? tf.fileName.split('.').last.toLowerCase() : '';

          await _firestoreService.saveFileMetadata(
            userId: userId, name: tf.fileName,
            folderId: folderId, folderPath: folderPath,
            telegramMessageId: tf.messageId,
            telegramFileId: tf.messageId.toString(),
            mimeType: tf.mimeType, sizeBytes: tf.fileSize, extension: ext,
          );
          filesImported++;
        }
      }

      if (foldersImported > 0 || filesImported > 0) _invalidateAll(null);
      return (folders: foldersImported, files: filesImported);
    } catch (_) {
      return (folders: 0, files: 0);
    } finally {
      if (mounted) state = state.copyWith(isSyncing: false);
    }
  }

  /// Sort folders so parents come before children (topological sort by depth).
  List<TelegramFolderMeta> _sortFoldersByDepth(List<TelegramFolderMeta> folders) {
    final result = <TelegramFolderMeta>[];
    final remaining = List<TelegramFolderMeta>.from(folders);
    final addedIds = <String>{};

    int maxIterations = folders.length * 2;
    while (remaining.isNotEmpty && maxIterations > 0) {
      maxIterations--;
      final toAdd = remaining.where((f) =>
          f.parentId == null || addedIds.contains(f.parentId)).toList();
      if (toAdd.isEmpty) {
        result.addAll(remaining);
        break;
      }
      for (final f in toAdd) {
        result.add(f);
        addedIds.add(f.id);
        remaining.remove(f);
      }
    }
    return result;
  }

  // ── Folder Operations ─────────────────────────────────────────────────────

  Future<CloudFolder?> createFolder({
    required String name,
    String? parentFolderId,
    String parentPath = '/',
  }) async {
    final userId = await _userId;
    if (userId == null) return null;

    final folder = await _firestoreService.createFolder(
      userId: userId,
      name: name,
      parentFolderId: parentFolderId,
      parentPath: parentPath,
    );

    _persistFolderToTelegram(userId, folder);

    _ref.invalidate(foldersProvider(parentFolderId));
    _ref.invalidate(foldersProvider(null));
    _ref.invalidate(userStatsProvider);

    return folder;
  }

  Future<void> _persistFolderToTelegram(String userId, CloudFolder folder) async {
    try {
      final meta = TelegramFolderMeta(
        metaMessageId: 0,
        id: folder.id,
        name: folder.name,
        parentId: folder.parentFolderId,
        path: folder.path,
        color: folder.color,
      );
      final msgId = await _telegramService.saveFolderMeta(meta);
      await _firestoreService.updateFolderMetaMessageId(
        userId: userId,
        folderId: folder.id,
        metaMessageId: msgId,
      );
    } catch (_) {}
  }

  Future<void> renameFolder(String folderId, String newName) async {
    final userId = await _userId;
    if (userId == null) return;
    await _firestoreService.renameFolder(userId: userId, folderId: folderId, newName: newName);
    _ref.invalidate(foldersProvider(null));
  }

  Future<void> trashFolder(String folderId) async {
    final userId = await _userId;
    if (userId == null) return;
    await _firestoreService.trashFolder(userId: userId, folderId: folderId);
    _ref.invalidate(foldersProvider(null));
  }

  // ── File Operations ────────────────────────────────────────────────────────

  Future<void> toggleStar(CloudFile file) async {
    final userId = await _userId;
    if (userId == null) return;
    await _firestoreService.toggleStar(
      userId: userId,
      fileId: file.id,
      isStarred: !file.isStarred,
    );
  }

  Future<void> renameFile(String fileId, String newName) async {
    final userId = await _userId;
    if (userId == null) return;
    await _firestoreService.renameFile(userId: userId, fileId: fileId, newName: newName);
  }

  Future<void> moveFile(CloudFile file, CloudFolder destinationFolder) async {
    final userId = await _userId;
    if (userId == null) return;
    await _firestoreService.moveFile(
      userId: userId,
      fileId: file.id,
      oldFolderId: file.folderId,
      newFolderId: destinationFolder.id,
      newFolderPath: destinationFolder.path,
      fileSizeBytes: file.sizeBytes,
    );
  }

  Future<void> copyFile(CloudFile file, CloudFolder destinationFolder) async {
    final userId = await _userId;
    if (userId == null) return;
    await _firestoreService.copyFile(
      userId: userId,
      sourceFile: file,
      destinationFolderId: destinationFolder.id,
      destinationFolderPath: destinationFolder.path,
    );
  }

  Future<void> trashFile(CloudFile file) async {
    final userId = await _userId;
    if (userId == null) return;
    await _firestoreService.trashFile(
      userId: userId,
      fileId: file.id,
      folderId: file.folderId,
    );
  }

  Future<bool> deleteFile(CloudFile file) async {
    final userId = await _userId;
    if (userId == null) return false;
    await _telegramService.deleteFile(file.telegramMessageId);
    await _firestoreService.deleteFile(
      userId: userId,
      fileId: file.id,
      fileSizeBytes: file.sizeBytes,
    );
    return true;
  }

  Future<String?> downloadFile(
    CloudFile file, {
    required Function(double) onProgress,
  }) async {
    try {
      final localFile = await _telegramService.downloadFile(
        file.telegramMessageId,
        file.name,
      );
      return localFile.path;
    } catch (_) {
      return null;
    }
  }

  Future<String?> getShareLink(CloudFile file) async {
    return 'https://t.me/saved_messages/${file.telegramMessageId}';
  }

  Future<List<CloudFile>> searchFiles(String query) async {
    final userId = await _userId;
    if (userId == null || query.isEmpty) return [];
    return _firestoreService.searchFiles(userId: userId, query: query);
  }

  /// Clear all local data for the current user (call on logout)
  Future<void> clearLocalData() async {
    final userId = await _userId;
    if (userId == null) return;
    await _firestoreService.clearUserData(userId);
    _invalidateAll(null);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _invalidateAll(String? folderId) {
    _ref.invalidate(foldersProvider(folderId));
    _ref.invalidate(foldersProvider(null));
    _ref.invalidate(filesProvider((folderId: folderId, sortBy: state.sortBy, descending: state.sortDescending)));
    _ref.invalidate(filesProvider((folderId: null, sortBy: state.sortBy, descending: state.sortDescending)));
    _ref.invalidate(allFilesProvider((starredOnly: false, trashedOnly: false)));
    _ref.invalidate(allFilesProvider((starredOnly: true, trashedOnly: false)));
    for (final cat in FileCategory.values) {
      _ref.invalidate(filesByCategoryProvider(cat));
    }
    _ref.invalidate(userStatsProvider);
  }
}

// ── Providers ─────────────────────────────────────────────────────────────────

final driveProvider = StateNotifierProvider<DriveNotifier, DriveState>((ref) {
  final firestoreService = ref.read(firestoreServiceProvider);
  final authService = ref.read(telegramAuthServiceProvider);
  final telegramService = TelegramStorageService(authService);
  return DriveNotifier(firestoreService, telegramService, ref);
});

final foldersProvider = StreamProvider.family<List<CloudFolder>, String?>((ref, parentFolderId) async* {
  final authService = ref.read(telegramAuthServiceProvider);
  final profile = await authService.getProfile();
  final userId = profile['userId'];
  if (userId == null || userId.isEmpty) { yield []; return; }

  final firestoreService = ref.read(firestoreServiceProvider);
  yield* firestoreService.getFolders(userId: userId, parentFolderId: parentFolderId);
});

final filesProvider = StreamProvider.family<List<CloudFile>, ({String? folderId, String sortBy, bool descending})>(
  (ref, params) async* {
    final authService = ref.read(telegramAuthServiceProvider);
    final profile = await authService.getProfile();
    final userId = profile['userId'];
    if (userId == null || userId.isEmpty) { yield []; return; }

    final firestoreService = ref.read(firestoreServiceProvider);
    yield* firestoreService.getFiles(
      userId: userId,
      folderId: params.folderId,
      sortBy: params.sortBy,
      descending: params.descending,
    );
  },
);

final allFilesProvider = StreamProvider.family<List<CloudFile>, ({bool starredOnly, bool trashedOnly})>(
  (ref, params) async* {
    final authService = ref.read(telegramAuthServiceProvider);
    final profile = await authService.getProfile();
    final userId = profile['userId'];
    if (userId == null || userId.isEmpty) { yield []; return; }

    final firestoreService = ref.read(firestoreServiceProvider);
    yield* firestoreService.getAllFiles(
      userId: userId,
      starredOnly: params.starredOnly,
      trashedOnly: params.trashedOnly,
    );
  },
);

/// Category-filtered file provider — only returns files matching one mime category.
final filesByCategoryProvider = StreamProvider.family<List<CloudFile>, FileCategory>(
  (ref, category) async* {
    final authService = ref.read(telegramAuthServiceProvider);
    final profile = await authService.getProfile();
    final userId = profile['userId'];
    if (userId == null || userId.isEmpty) { yield []; return; }

    final firestoreService = ref.read(firestoreServiceProvider);
    yield* firestoreService.getFilesByCategory(userId: userId, category: category);
  },
);

final userStatsProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final authService = ref.read(telegramAuthServiceProvider);
  final profile = await authService.getProfile();
  final userId = profile['userId'] ?? '';
  if (userId.isEmpty) return {};
  final firestoreService = ref.read(firestoreServiceProvider);
  return firestoreService.getUserStats(userId);
});
