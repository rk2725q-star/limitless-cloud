import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../features/auth/data/telegram_auth_service.dart';
import '../../features/drive/data/firestore_metadata_service.dart';
import '../../features/drive/data/models/cloud_file.dart';
import '../../features/drive/data/telegram_storage_service.dart';
import '../../features/drive/presentation/providers/drive_provider.dart';
import '../services/tdlib_service.dart';
import '../services/upload_background_service.dart';

/// OfflineSyncService
///
/// Handles offline photo/video captures and background cloud auto-sync:
/// 1. Saves captured photos/videos locally into an offline directory and SQLite.
/// 2. Ensures photos appear IMMEDIATELY in the Gallery even when completely offline.
/// 3. Monitors network connectivity via [Connectivity].
/// 4. As soon as internet is detected, auto-uploads pending files in the background,
///    protected by Android's TransferForegroundService.
/// 5. Automatically deletes temporary local copies after safe Telegram cloud confirmation.
class OfflineSyncService {
  OfflineSyncService._();
  static final OfflineSyncService instance = OfflineSyncService._();

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  WidgetRef? _ref;
  Ref? _containerRef;
  bool _isSyncing = false;

  void init(dynamic ref) {
    if (ref is WidgetRef) {
      _ref = ref;
    } else if (ref is Ref) {
      _containerRef = ref;
    }

    _connectivitySub?.cancel();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final isOnline = results.any((r) => r != ConnectivityResult.none);
      if (isOnline) {
        debugPrint('[OfflineSyncService] Internet connection restored. Triggering auto-backup…');
        syncPendingFiles();
      }
    });

    // Initial check on launch
    syncPendingFiles();
  }

  void dispose() {
    _connectivitySub?.cancel();
    _connectivitySub = null;
  }

  // ── Helper to read providers dynamically ────────────────────────────────────

  T? _read<T>(ProviderListenable<T> provider) {
    if (_ref != null) return _ref!.read(provider);
    if (_containerRef != null) return _containerRef!.read(provider);
    return null;
  }

  // ── Save captured photo/video locally (works offline & online) ─────────────

  Future<CloudFile> saveCapturedFile({
    required File file,
    required String fileName,
    String? folderId,
    String folderPath = '/',
  }) async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final offlineDir = Directory(p.join(appDocDir.path, 'offline_pending'));
    if (!await offlineDir.exists()) {
      await offlineDir.create(recursive: true);
    }

    // 1. Copy original to safe persistent local storage
    final persistentPath = p.join(offlineDir.path, fileName);
    final savedFile = await file.copy(persistentPath);
    try { await file.delete(); } catch (_) {}

    // 2. Create local thumbnail copy so Gallery renders with zero latency
    final thumbDir = Directory(p.join(appDocDir.path, 'thumbnails'));
    if (!await thumbDir.exists()) {
      await thumbDir.create(recursive: true);
    }
    final thumbPath = p.join(thumbDir.path, 'local_${DateTime.now().microsecondsSinceEpoch}_$fileName');
    await savedFile.copy(thumbPath);

    // 3. Resolve user ID
    final authService = _read(telegramAuthServiceProvider);
    String userId = '';
    if (authService != null) {
      final profile = await authService.getProfile();
      userId = profile['userId'] ?? '';
    }

    final fileSize = await savedFile.length();
    final ext = p.extension(fileName).replaceAll('.', '');
    final mimeType = lookupMimeType(savedFile.path) ?? (ext == 'mp4' ? 'video/mp4' : 'image/jpeg');

    // 4. Insert into local SQLite database immediately (telegramMessageId = 0 = pending)
    final firestoreService = _read(firestoreServiceProvider) ?? LocalMetadataService();
    final cloudFile = await firestoreService.saveFileMetadata(
      userId: userId,
      name: fileName,
      folderId: folderId,
      folderPath: folderPath,
      telegramMessageId: 0,
      telegramFileId: 'offline_pending_${DateTime.now().microsecondsSinceEpoch}',
      mimeType: mimeType,
      sizeBytes: fileSize,
      extension: ext,
      thumbnailPath: thumbPath,
    );

    // Invalidate UI streams so photo appears in Gallery immediately
    _read(driveProvider.notifier)?.invalidateCategoryStreams();

    // 5. If online, trigger auto-backup to cloud right away
    syncPendingFiles();

    return cloudFile;
  }

  // ── Sync all pending offline files to Telegram Cloud ────────────────────────

  Future<void> syncPendingFiles() async {
    if (_isSyncing) return;

    final results = await Connectivity().checkConnectivity();
    final isOnline = results.any((r) => r != ConnectivityResult.none);
    if (!isOnline) {
      debugPrint('[OfflineSyncService] Device is offline. Pending photos remain safe in local gallery.');
      return;
    }

    final authService = _read(telegramAuthServiceProvider);
    if (authService == null) return;
    final profile = await authService.getProfile();
    final userId = profile['userId'] ?? '';
    if (userId.isEmpty) return;

    final firestoreService = _read(firestoreServiceProvider) ?? LocalMetadataService();
    final pendingFiles = await firestoreService.getPendingOfflineFiles(userId);
    if (pendingFiles.isEmpty) return;

    _isSyncing = true;
    debugPrint('[OfflineSyncService] Starting auto-backup for ${pendingFiles.length} pending files…');

    try {
      // Ensure TDLib client is ready
      var waitTries = 0;
      while (!TdlibService.instance.isReady && waitTries < 40) {
        await Future.delayed(const Duration(milliseconds: 300));
        waitTries++;
      }
      if (!TdlibService.instance.isReady) {
        debugPrint('[OfflineSyncService] TDLib client not ready yet. Postponing auto-backup.');
        return;
      }

      final appDocDir = await getApplicationDocumentsDirectory();
      final offlineDir = Directory(p.join(appDocDir.path, 'offline_pending'));
      final telegramService = TelegramStorageService(authService);

      for (final pending in pendingFiles) {
        // Resolve local file path
        File? uploadSource;
        final targetPath = p.join(offlineDir.path, pending.name);
        if (await File(targetPath).exists()) {
          uploadSource = File(targetPath);
        } else if (pending.thumbnailPath != null && await File(pending.thumbnailPath!).exists()) {
          uploadSource = File(pending.thumbnailPath!);
        }

        if (uploadSource == null || !await uploadSource.exists()) {
          debugPrint('[OfflineSyncService] Pending file not found on disk: ${pending.name}');
          continue;
        }

        debugPrint('[OfflineSyncService] Uploading ${pending.name} (${uploadSource.lengthSync()} bytes) to Telegram…');

        // Start Android foreground service to guarantee upload completes in background
        await UploadBackgroundService.startUpload(pending.name);

        try {
          final uploadResult = await telegramService.uploadFileChunked(
            uploadSource,
            folderId: pending.folderId,
            folderPath: pending.folderPath,
            onProgress: (progress) {
              UploadBackgroundService.updateProgress(pending.name, progress);
            },
          );

          // Build permanent thumbnail path if image
          String? permThumbPath;
          if (['jpg', 'jpeg', 'png', 'webp', 'gif'].contains(pending.extension.toLowerCase())) {
            try {
              final permDir = Directory(p.join(appDocDir.path, 'thumbnails'));
              if (!await permDir.exists()) await permDir.create(recursive: true);
              permThumbPath = p.join(permDir.path, 'thumb_${uploadResult.primaryMessageId}.${pending.extension}');
              await uploadSource.copy(permThumbPath);
            } catch (_) {}
          }

          // Update SQLite record with real Telegram cloud IDs
          await firestoreService.markFileUploaded(
            fileId: pending.id,
            userId: userId,
            telegramMessageId: uploadResult.primaryMessageId,
            telegramFileId: uploadResult.primaryMessageId.toString(),
            chunkMessageIds: uploadResult.allMessageIds,
            permanentThumbPath: permThumbPath,
          );

          // Auto-delete local temporary copy to free phone memory
          try {
            if (await uploadSource.exists()) {
              await uploadSource.delete();
              debugPrint('[OfflineSyncService] Deleted local copy for ${pending.name}. Storage freed.');
            }
          } catch (_) {}

          debugPrint('[OfflineSyncService] Successfully backed up ${pending.name} to cloud.');
        } catch (e) {
          debugPrint('[OfflineSyncService] Failed to upload ${pending.name}: $e');
        } finally {
          await UploadBackgroundService.stopUpload();
        }
      }

      // Purge any duplicates that may have arisen during parallel sync
      await firestoreService.deduplicateFiles(userId);

      // Refresh drive and gallery state
      _read(driveProvider.notifier)?.invalidateCategoryStreams();
    } catch (e) {
      debugPrint('[OfflineSyncService] Error during auto-backup: $e');
    } finally {
      _isSyncing = false;
    }
  }
}
