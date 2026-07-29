import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import '../../../auth/data/telegram_auth_service.dart';
import '../../data/models/cloud_file.dart';
import '../../data/models/cloud_folder.dart';
import '../../data/firestore_metadata_service.dart';
import '../../data/telegram_storage_service.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/utils/file_utils.dart';
import '../../../../core/services/tdlib_service.dart';
import '../../../../core/services/upload_background_service.dart';
import 'package:mime/mime.dart';

// ── Upload State ──────────────────────────────────────────────────────────────

class UploadTask {
  /// Unique ID for this task — avoids matching by filename when two files
  /// with the same name are uploading concurrently.
  final String taskId;
  final String fileName;
  final double progress;
  final bool isComplete;
  final bool hasError;
  final String? error;
  final int totalBytes;
  final int totalChunks;
  final int currentChunk;

  UploadTask({
    required this.taskId,
    required this.fileName,
    required this.progress,
    this.isComplete = false,
    this.hasError = false,
    this.error,
    this.totalBytes = 0,
    this.totalChunks = 1,
    this.currentChunk = 1,
  });

  UploadTask copyWith({
    String? taskId,
    String? fileName,
    double? progress,
    bool? isComplete,
    bool? hasError,
    String? error,
    int? totalBytes,
    int? totalChunks,
    int? currentChunk,
  }) {
    return UploadTask(
      taskId: taskId ?? this.taskId,
      fileName: fileName ?? this.fileName,
      progress: progress ?? this.progress,
      isComplete: isComplete ?? this.isComplete,
      hasError: hasError ?? this.hasError,
      error: error ?? this.error,
      totalBytes: totalBytes ?? this.totalBytes,
      totalChunks: totalChunks ?? this.totalChunks,
      currentChunk: currentChunk ?? this.currentChunk,
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
    var uid = profile['userId'] ?? '';

    // Fallback: if profile not stored yet, fetch from TDLib directly
    if (uid.isEmpty) {
      try {
        await authService.saveProfileFromTdlib();
        final refreshed = await authService.getProfile();
        uid = refreshed['userId'] ?? '';
      } catch (_) {}
    }

    return uid.isEmpty ? null : uid;
  }

  // ── TDLib readiness guard ─────────────────────────────────────────────────────────

  /// Waits until TDLib reaches [authorizationStateReady].
  ///
  /// Every operation that talks to Telegram (upload, sync, listing) MUST
  /// call this first.  TDLib is initialised ~100ms after runApp() and needs
  /// several more seconds to negotiate with Telegram servers.  Without this
  /// guard, operations fired before the handshake completes hang forever
  /// (2-hour upload timeout) or fail silently (sync catch block).
  Future<void> _waitForTdlib({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final tdlib = TdlibService.instance;
    final deadline = DateTime.now().add(timeout);
    bool retried = false;

    while (tdlib.authState != 'authorizationStateReady') {
      if (tdlib.initError != null) {
        if (!retried && tdlib.initError!.contains('lock file')) {
          retried = true;
          await tdlib.retryInit();
          continue;
        }
        throw Exception(
            'Telegram core failed to load: ${tdlib.initError}. Please force-close the app and reopen.');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw Exception(
            'Telegram is stuck connecting (State: "${tdlib.authState}"). Please clear app data and log in again.');
      }
      final s = tdlib.authState;
      if (s == 'authorizationStateWaitPhoneNumber' ||
          s == 'authorizationStateClosed' ||
          s == 'authorizationStateClosing') {
        throw Exception(
            'Not logged in to Telegram. Please log in again.');
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }
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

  /// Dismiss a failed/completed upload task from the UI.
  void dismissUploadTask(String taskId) {
    if (!mounted) return;
    final tasks = state.uploadTasks.where((t) => t.taskId != taskId).toList();
    state = state.copyWith(uploadTasks: tasks);
  }

  Future<void> uploadFiles({
    String? folderId,
    String folderPath = '/',
  }) async {
    // ── Step 1: Ensure storage permissions ────────────────────────────────────
    // Without proper permissions, file_picker may return inaccessible paths.
    final permOk = await _requestStoragePermission();
    if (!permOk) {
      // Still try — file_picker uses SAF which works even without permissions
      // on Android 10+. We just warn but don't block.
    }

    // ── Step 2: Pick files ────────────────────────────────────────────────────
    // CRITICAL: Do NOT use withReadStream:true — it skips file_picker's internal
    // SAF→cache resolution and returns an unusable content:// URI as the path.
    // withData:false prevents loading the entire file into RAM (safe for 2GB+).
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
      type: FileType.any,
    );
    if (result == null || result.files.isEmpty) return;

    final userId = await _userId;
    if (userId == null) return;

    // ── Step 3: Upload each file ───────────────────────────────────────────────
    // file_picker on Android uses the Storage Access Framework (SAF) internally.
    // For content:// URIs it ALREADY copies the file to its own cache directory
    // and returns that cache path. The returned pickedFile.path is ALWAYS a real,
    // accessible file path by the time pickFiles() completes.
    for (final pickedFile in result.files) {
      final fileName = pickedFile.name;

      if (pickedFile.path == null) {
        // Very rare: path is null only on Web (not Android). Skip.
        _markError(null, fileName, 'File path unavailable. Please try again.');
        continue;
      }

      final file = File(pickedFile.path!);

      // Verify the file is accessible — file_picker guarantees this, but guard anyway.
      if (!await file.exists()) {
        _markError(null, fileName,
            'File not accessible. Check storage permission in Settings > Apps > Limitless Cloud > Permissions.');
        continue;
      }

      await _runUpload(
        file: file,
        fileName: fileName,
        folderId: folderId,
        folderPath: folderPath,
        userId: userId,
        // file_picker copies content:// URIs to its own cache dir.
        // We mark those as cache files so we can clean them up after upload.
        isCacheFile: file.path.contains('/cache/'),
      );
    }
  }

  /// Requests storage permissions appropriate for the Android version.
  /// Returns true if at least one useful permission is granted.
  Future<bool> _requestStoragePermission() async {
    if (!Platform.isAndroid) return true;

    // Android 13+ (API 33): granular media permissions
    // We request all three so the user can pick any file type.
    final photos  = await Permission.photos.status;
    final videos  = await Permission.videos.status;
    final audio   = await Permission.audio.status;

    // Also try MANAGE_EXTERNAL_STORAGE (Android 11+) for full access.
    // On Android 9-10 this silently returns denied, which is fine.
    final manageStatus = await Permission.manageExternalStorage.status;

    // Classic READ_EXTERNAL_STORAGE for Android 9-12.
    final storageStatus = await Permission.storage.status;

    // Only request what is not yet granted.
    final toRequest = <Permission>[];
    if (!photos.isGranted)  toRequest.add(Permission.photos);
    if (!videos.isGranted)  toRequest.add(Permission.videos);
    if (!audio.isGranted)   toRequest.add(Permission.audio);
    if (!storageStatus.isGranted && !manageStatus.isGranted) {
      toRequest.add(Permission.storage);
    }

    if (toRequest.isNotEmpty) {
      await toRequest.request();
    }

    // Even if denied, SAF-based file picker still works on Android 10+.
    return true;
  }

  /// Show an error task card for a file that couldn't be opened.
  void _markError(String? taskId, String fileName, String error) {
    final id = taskId ?? '${fileName}_${DateTime.now().microsecondsSinceEpoch}';
    if (!mounted) return;
    state = state.copyWith(uploadTasks: [
      ...state.uploadTasks,
      UploadTask(
        taskId: id,
        fileName: fileName,
        progress: 0,
        hasError: true,
        error: error,
      ),
    ]);
  }

  /// Internal: run a single file upload, adding/updating the task in state.
  /// [isCacheFile] — if true the temp cache copy is deleted after upload.
  Future<void> _runUpload({
    required File file,
    required String fileName,
    required String? folderId,
    required String folderPath,
    required String userId,
    bool isCacheFile = false,
  }) async {
    final extension = FileUtils.getExtension(fileName);
    final mimeType = lookupMimeType(file.path) ?? 'application/octet-stream';
    final fileSize = await file.length();

    // Mirrors chunk logic in TelegramStorageService.
    const telegramLimit = 2 * 1024 * 1024 * 1024; // 2 GB
    const maxChunkBytes = 1.95 * 1024 * 1024 * 1024; // 1.95 GB
    final totalChunks = fileSize < telegramLimit
        ? 1
        : (fileSize / maxChunkBytes).ceil();

    final taskId = '${fileName}_${DateTime.now().microsecondsSinceEpoch}';

    // Add task immediately at 0% so it is visible right away.
    final task = UploadTask(
      taskId: taskId,
      fileName: fileName,
      progress: 0.0,
      totalBytes: fileSize,
      totalChunks: totalChunks,
      currentChunk: 1,
    );
    if (mounted) state = state.copyWith(uploadTasks: [...state.uploadTasks, task]);

    // ── Start background foreground service so upload continues when app is closed
    await UploadBackgroundService.startUpload(fileName);

    try {
      // ── Guard: wait for TDLib before uploading ───────────────────────────
      // Without this, sendMessage fires before authorizationStateReady and the
      // upload hangs at 0% forever (2-hour _send timeout).
      await _waitForTdlib();

      final uploadResult = await _telegramService.uploadFileChunked(
        file,
        folderId: folderId,
        folderPath: folderPath,
        onProgress: (progress) {
          if (!mounted) return;
          final tasks = state.uploadTasks.toList();
          final idx = tasks.indexWhere((t) => t.taskId == taskId);
          if (idx >= 0) {
            final currentChunk = totalChunks > 1
                ? ((progress * totalChunks).floor() + 1).clamp(1, totalChunks)
                : 1;
            tasks[idx] = tasks[idx].copyWith(
              progress: progress,
              currentChunk: currentChunk,
            );
            state = state.copyWith(uploadTasks: tasks);
          }
          // Update foreground service notification with current %
          UploadBackgroundService.updateProgress(fileName, progress);
        },
      );

      String? finalThumbPath;
      if (['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(extension.toLowerCase())) {
        try {
          final docDir = await getApplicationDocumentsDirectory();
          final thumbDir = io.Directory('${docDir.path}/thumbnails');
          if (!await thumbDir.exists()) await thumbDir.create(recursive: true);
          final ext = extension.isNotEmpty ? '.$extension' : '';
          final newPath = '${thumbDir.path}/thumb_${uploadResult.primaryMessageId}$ext';
          await file.copy(newPath);
          finalThumbPath = newPath;
        } catch (_) {
          finalThumbPath = file.path;
        }
      }

      await _firestoreService.saveFileMetadata(
        userId: userId,
        name: fileName,
        folderId: folderId,
        folderPath: folderPath,
        telegramMessageId: uploadResult.primaryMessageId,
        telegramFileId: uploadResult.primaryMessageId.toString(),
        mimeType: mimeType,
        sizeBytes: fileSize,
        extension: extension,
        chunkMessageIds: uploadResult.allMessageIds,
        thumbnailPath: finalThumbPath,
      );

      // Mark complete.
      if (mounted) {
        final tasks = state.uploadTasks.toList();
        final idx = tasks.indexWhere((t) => t.taskId == taskId);
        if (idx >= 0) {
          tasks[idx] = tasks[idx].copyWith(isComplete: true, progress: 1.0);
          state = state.copyWith(uploadTasks: tasks);
        }
        _invalidateAll(folderId);
      }

      // Auto-dismiss success tile after 4 seconds.
      await Future.delayed(const Duration(seconds: 4));
      if (mounted) {
        final tasks = state.uploadTasks.where((t) => t.taskId != taskId || !t.isComplete).toList();
        state = state.copyWith(uploadTasks: tasks);
      }
      // Clean up temp cache file to free device storage.
      if (isCacheFile) {
        try { await file.delete(); } catch (_) {}
      }
      // Stop background service notification (all done)
      await UploadBackgroundService.stopUpload();
    } catch (e) {
      // Clean up temp cache file even on failure.
      if (isCacheFile) {
        try { await file.delete(); } catch (_) {}
      }
      // Mark as failed — tile stays visible until user explicitly dismisses it.
      if (mounted) {
        final tasks = state.uploadTasks.toList();
        final idx = tasks.indexWhere((t) => t.taskId == taskId);
        if (idx >= 0) {
          tasks[idx] = tasks[idx].copyWith(
            hasError: true,
            error: _friendlyError(e.toString()),
          );
          state = state.copyWith(uploadTasks: tasks);
        }
      }
      // Stop background service notification on failure too
      await UploadBackgroundService.stopUpload();
    }
  }

  /// Convert raw exception messages into user-friendly strings.
  String _friendlyError(String raw) {
    if (raw.contains('SocketException') || raw.contains('Connection')) {
      return 'Connection lost. Tap Retry.';
    }
    if (raw.contains('TimeoutException') || raw.contains('timeout')) {
      return 'Upload timed out. Tap Retry.';
    }
    if (raw.contains('DioException') || raw.contains('dio')) {
      return 'Network error. Tap Retry.';
    }
    return raw.replaceAll('Exception: ', '');
  }

  /// Retry a failed upload task by taskId.
  /// The original file path, folder info, and userId must still be accessible.
  Future<void> retryUpload({
    required String taskId,
    required File file,
    required String? folderId,
    required String folderPath,
    required String userId,
  }) async {
    // Reset the failed task to uploading state.
    if (mounted) {
      final tasks = state.uploadTasks.toList();
      final idx = tasks.indexWhere((t) => t.taskId == taskId);
      if (idx >= 0) {
        tasks[idx] = tasks[idx].copyWith(
          hasError: false,
          error: null,
          progress: 0.0,
          isComplete: false,
        );
        state = state.copyWith(uploadTasks: tasks);
      }
    }
    // Dismiss old task and run a fresh upload (gets a new taskId).
    dismissUploadTask(taskId);
    await _runUpload(
      file: file,
      fileName: p.basename(file.path),
      folderId: folderId,
      folderPath: folderPath,
      userId: userId,
    );
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
      // ── Guard: wait for TDLib before ANY Telegram API call ────────────────
      // Without this, listFolderMeta + listFiles throw before auth is ready,
      // the catch block swallowed it, and the user saw an empty drive.
      await _waitForTdlib(timeout: const Duration(seconds: 45));

      int foldersImported = 0;
      int filesImported = 0;

      final authService = _ref.read(telegramAuthServiceProvider);

      // ── If user just logged in (after logout), wipe stale local DB ──────────
      // IMPORTANT: Do NOT clear the resync flag here. We clear it ONLY after
      // the sync completes successfully. If sync fails mid-way, the flag must
      // remain so the next app open retries the wipe + full reimport.
      final needsWipe = await authService.needsDbResync();
      if (needsWipe) {
        await _firestoreService.clearUserData(userId);
        // flag cleared below, AFTER successful sync
      }

      // ── Check current DB state ───────────────────────────────────────────────
      final existingMsgIds     = await _firestoreService.getExistingMessageIds(userId);
      final existingFolderIds  = await _firestoreService.getExistingFolderIds(userId);
      final deletedFolderIds   = await _firestoreService.getDeletedFolderIds(userId);

      // ── STEP 1: Restore folder structure ───────────────────────────────────
      final folderMetas = await _telegramService.listFolderMeta();
      if (folderMetas.isNotEmpty) {
        final sorted = _sortFoldersByDepth(folderMetas);
        for (final meta in sorted) {
          // Skip folders that already exist locally OR were permanently deleted.
          if (existingFolderIds.contains(meta.id)) continue;
          if (deletedFolderIds.contains(meta.id)) continue;

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

          // Only validate folder exists if we have a folderId.
          // If folder is missing locally (e.g. folder sync failed), keep the
          // file in its original folderPath so it still appears — just not
          // inside the folder widget until the folder syncs on next open.
          if (folderId != null) {
            final folder = await _firestoreService.getFolderById(
                userId: userId, folderId: folderId);
            if (folder == null) {
              // Folder missing locally — keep folderId+path so it will resolve
              // correctly once the folder syncs. We do NOT silently drop to root.
              // The file will appear under folderId once that folder is imported.
            }
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

      // ── STEP 3: Only clear resync flag after everything succeeded ───────────
      // If an exception was thrown above, we never reach here and the flag
      // persists — the next app open will retry the wipe + full reimport.
      if (needsWipe) {
        await authService.clearResyncFlag();
      }

      if (foldersImported > 0 || filesImported > 0) _invalidateAll(null);
      return (folders: foldersImported, files: filesImported);
    } catch (e) {
      // Rethrow so the calling widget can show a user-visible error banner
      // instead of silently returning an empty drive.
      rethrow;
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

  Future<void> deleteFolder(String folderId) async {
    final userId = await _userId;
    if (userId == null) return;

    // Fetch folder before deleting so we can remove its Telegram meta message.
    final folder = await _firestoreService.getFolderById(
        userId: userId, folderId: folderId);

    // Delete from local DB first so UI updates immediately.
    await _firestoreService.deleteFolder(userId: userId, folderId: folderId);

    // Invalidate ALL folder-related providers so UI refreshes instantly
    _invalidateAll(null);
    if (folder?.parentFolderId != null) {
      _ref.invalidate(foldersProvider(folder!.parentFolderId));
    }

    // Also delete the LIMITLESS_FOLDER: text message from Telegram Saved
    // Messages — without this the folder reappears on next sync.
    if (folder != null && folder.metaMessageId > 0) {
      try {
        await _telegramService.deleteFolderMeta(folder.metaMessageId);
      } catch (_) {
        // Non-fatal: local DB is already updated; worst case a re-sync will
        // see the orphaned meta message but the folder won't match any files.
      }
    }
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

  Future<void> renameFile(CloudFile file, String newName) async {
    final userId = await _userId;
    if (userId == null) return;
    // 1. Update local SQLite immediately
    await _firestoreService.renameFile(userId: userId, fileId: file.id, newName: newName);
    // 2. Refresh all providers so the UI updates instantly (no app restart needed)
    _invalidateAll(file.folderId);
    // 3. Fire-and-forget Telegram caption update so Saved Messages also shows new name
    unawaited(_telegramService.renameFileTelegram(file.telegramMessageId, newName));
  }

  Future<void> moveFile(CloudFile file, CloudFolder destinationFolder) async {
    final userId = await _userId;
    if (userId == null) return;
    // Empty id means root
    final destId = destinationFolder.id.isEmpty ? null : destinationFolder.id;
    final destPath = destinationFolder.path.isEmpty ? '/' : destinationFolder.path;
    await _firestoreService.moveFile(
      userId: userId,
      fileId: file.id,
      oldFolderId: file.folderId,
      newFolderId: destId,
      newFolderPath: destPath,
      fileSizeBytes: file.sizeBytes,
    );
    _invalidateAll(file.folderId);
    _invalidateAll(destId);
  }

  Future<void> copyFile(CloudFile file, CloudFolder destinationFolder) async {
    final userId = await _userId;
    if (userId == null) return;
    final destId = destinationFolder.id.isEmpty ? null : destinationFolder.id;
    final destPath = destinationFolder.path.isEmpty ? '/' : destinationFolder.path;
    await _firestoreService.copyFile(
      userId: userId,
      sourceFile: file,
      destinationFolderId: destId,
      destinationFolderPath: destPath,
    );
    _invalidateAll(destId);
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
    // Always delete from local DB first — Telegram delete is best-effort.
    try {
      if (file.isChunked) {
        await _telegramService.deleteChunkedFile(file.chunkMessageIds);
      } else {
        await _telegramService.deleteFile(file.telegramMessageId);
      }
    } catch (_) {
      // Telegram delete failed. Continue anyway — local record must still be removed.
    }
    try {
      await _firestoreService.deleteFile(
        userId: userId,
        fileId: file.id,
        fileSizeBytes: file.sizeBytes,
      );
    } catch (_) {
      return false;
    }
    _invalidateAll(file.folderId);
    return true;
  }

  Future<String?> downloadFile(
    CloudFile file, {
    required Function(double) onProgress,
  }) async {
    try {
      final File localFile;
      if (file.isChunked) {
        localFile = await _telegramService.downloadChunkedFile(
          file.chunkMessageIds,
          file.name,
          onProgress: onProgress,
        );
      } else {
        localFile = await _telegramService.downloadFile(
          file.telegramMessageId,
          file.name,
        );
      }
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

/// Exposes the authenticated Telegram session string so widgets can build
/// backend-authenticated thumbnail / stream URLs directly.
final sessionProvider = FutureProvider<String>((ref) async {
  final authService = ref.read(telegramAuthServiceProvider);
  return authService.getSession();
});
