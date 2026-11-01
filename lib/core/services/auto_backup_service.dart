import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../features/auth/data/telegram_auth_service.dart';
import '../../../features/drive/data/firestore_metadata_service.dart';
import '../../../features/drive/data/telegram_storage_service.dart';
import '../../../features/drive/presentation/providers/drive_provider.dart';
import 'face_detection_service.dart';
import 'upload_background_service.dart';

// ── Auto Backup Configuration & State ────────────────────────────────────────

class AutoBackupConfig {
  final bool isEnabled;
  final String cameraFolderPath;
  final bool backupVideos;
  final int dailyLimitMB; // 0 = unlimited
  final bool wifiOnly;
  final int todayUsageBytes;
  final String todayDateStr;
  final DateTime? lastBackupTime;
  final String lastDailyCompletedDate;
  final int scheduledHour; // 2 = 2:00 AM (Overnight default)

  const AutoBackupConfig({
    this.isEnabled = false,
    this.cameraFolderPath = '/storage/emulated/0/DCIM/Camera',
    this.backupVideos = false,
    this.dailyLimitMB = 100,
    this.wifiOnly = false,
    this.todayUsageBytes = 0,
    this.todayDateStr = '',
    this.lastBackupTime,
    this.lastDailyCompletedDate = '',
    this.scheduledHour = 2,
  });

  int get dailyLimitBytes => dailyLimitMB * 1024 * 1024;
  bool get hasReachedDailyLimit =>
      dailyLimitMB > 0 && todayUsageBytes >= dailyLimitBytes;

  /// Returns true if today's daily backup has already run and terminated.
  bool get isCompletedForToday => lastDailyCompletedDate == todayDateStr;

  double get usagePercent => dailyLimitMB <= 0
      ? 0.0
      : (todayUsageBytes / dailyLimitBytes).clamp(0.0, 1.0);

  String get scheduleLabel {
    switch (scheduledHour) {
      case 2:
        return 'Overnight (02:00 AM) — Idle & Sleep';
      case 6:
        return 'Early Morning (06:00 AM)';
      case 9:
        return 'Morning (09:00 AM)';
      case 14:
        return 'Afternoon (02:00 PM)';
      case 21:
        return 'Night (09:00 PM)';
      default:
        return '${scheduledHour.toString().padLeft(2, '0')}:00';
    }
  }

  AutoBackupConfig copyWith({
    bool? isEnabled,
    String? cameraFolderPath,
    bool? backupVideos,
    int? dailyLimitMB,
    bool? wifiOnly,
    int? todayUsageBytes,
    String? todayDateStr,
    DateTime? lastBackupTime,
    String? lastDailyCompletedDate,
    int? scheduledHour,
  }) {
    return AutoBackupConfig(
      isEnabled: isEnabled ?? this.isEnabled,
      cameraFolderPath: cameraFolderPath ?? this.cameraFolderPath,
      backupVideos: backupVideos ?? this.backupVideos,
      dailyLimitMB: dailyLimitMB ?? this.dailyLimitMB,
      wifiOnly: wifiOnly ?? this.wifiOnly,
      todayUsageBytes: todayUsageBytes ?? this.todayUsageBytes,
      todayDateStr: todayDateStr ?? this.todayDateStr,
      lastBackupTime: lastBackupTime ?? this.lastBackupTime,
      lastDailyCompletedDate: lastDailyCompletedDate ?? this.lastDailyCompletedDate,
      scheduledHour: scheduledHour ?? this.scheduledHour,
    );
  }
}

enum AutoBackupStatus {
  idle,
  scanning,
  backingUp,
  limitReached,
  completed,
  error,
}

class AutoBackupProgress {
  final AutoBackupStatus status;
  final int totalFiles;
  final int processedFiles;
  final String currentFileName;
  final double currentFileProgress;
  final String message;

  const AutoBackupProgress({
    this.status = AutoBackupStatus.idle,
    this.totalFiles = 0,
    this.processedFiles = 0,
    this.currentFileName = '',
    this.currentFileProgress = 0.0,
    this.message = '',
  });
}

// ── Auto Backup Service ──────────────────────────────────────────────────────

class AutoBackupService {
  static const _kEnabled = 'autobackup_enabled';
  static const _kFolder = 'autobackup_folder';
  static const _kVideos = 'autobackup_videos';
  static const _kLimitMB = 'autobackup_daily_limit_mb';
  static const _kWifiOnly = 'autobackup_wifi_only';
  static const _kUsageBytes = 'autobackup_today_usage_bytes';
  static const _kUsageDate = 'autobackup_today_usage_date';
  static const _kLastTime = 'autobackup_last_time';
  static const _kLastDailyDone = 'autobackup_last_daily_done_date';
  static const _kScheduledHour = 'autobackup_scheduled_hour';

  static final AutoBackupService instance = AutoBackupService._();
  AutoBackupService._();

  final _progressController = StreamController<AutoBackupProgress>.broadcast();
  Stream<AutoBackupProgress> get progressStream => _progressController.stream;

  AutoBackupProgress _currentProgress = const AutoBackupProgress();
  AutoBackupProgress get currentProgress => _currentProgress;

  bool _isCancelled = false;
  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;

  Timer? _dailyTimer;
  dynamic _ref;

  void _emit(AutoBackupProgress p) {
    _currentProgress = p;
    _progressController.add(p);
  }

  // ── Lifecycle Initialization ───────────────────────────────────────────────

  void init(dynamic ref) {
    _ref = ref;

    // Smart check once on startup: if today's backup is not completed yet, run once and terminate
    Timer(const Duration(seconds: 4), () {
      checkAndRunDailyBackup();
    });

    // Schedule next daily run at the scheduled hour (e.g. 2:00 AM)
    _scheduleNextDailyRun();
  }

  void _scheduleNextDailyRun() async {
    _dailyTimer?.cancel();
    final config = await loadConfig();
    final now = DateTime.now();
    DateTime target = DateTime(now.year, now.month, now.day, config.scheduledHour, 0);
    if (now.isAfter(target)) {
      target = target.add(const Duration(days: 1));
    }
    final delay = target.difference(now);
    debugPrint('[AutoBackup] Intelligent daily backup scheduled in ${delay.inHours}h ${delay.inMinutes % 60}m (at ${config.scheduledHour}:00)');
    _dailyTimer = Timer(delay, () async {
      await checkAndRunDailyBackup();
      _scheduleNextDailyRun();
    });
  }

  void dispose() {
    _dailyTimer?.cancel();
  }

  // ── Load Settings ──────────────────────────────────────────────────────────

  Future<AutoBackupConfig> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());

    int usageBytes = prefs.getInt(_kUsageBytes) ?? 0;
    final savedDate = prefs.getString(_kUsageDate) ?? '';

    // Reset usage counter if it's a new day
    if (savedDate != todayStr) {
      usageBytes = 0;
      await prefs.setInt(_kUsageBytes, 0);
      await prefs.setString(_kUsageDate, todayStr);
    }

    final lastMs = prefs.getInt(_kLastTime);
    final lastTime = lastMs != null ? DateTime.fromMillisecondsSinceEpoch(lastMs) : null;
    final lastDailyDone = prefs.getString(_kLastDailyDone) ?? '';
    final scheduledHour = prefs.getInt(_kScheduledHour) ?? 2;

    return AutoBackupConfig(
      isEnabled: prefs.getBool(_kEnabled) ?? false,
      cameraFolderPath: prefs.getString(_kFolder) ?? '/storage/emulated/0/DCIM/Camera',
      backupVideos: prefs.getBool(_kVideos) ?? false,
      dailyLimitMB: prefs.getInt(_kLimitMB) ?? 100,
      wifiOnly: prefs.getBool(_kWifiOnly) ?? false,
      todayUsageBytes: usageBytes,
      todayDateStr: todayStr,
      lastBackupTime: lastTime,
      lastDailyCompletedDate: lastDailyDone,
      scheduledHour: scheduledHour,
    );
  }

  // ── Save Settings ──────────────────────────────────────────────────────────

  Future<void> updateConfig({
    bool? isEnabled,
    String? cameraFolderPath,
    bool? backupVideos,
    int? dailyLimitMB,
    bool? wifiOnly,
    int? scheduledHour,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (isEnabled != null) await prefs.setBool(_kEnabled, isEnabled);
    if (cameraFolderPath != null) await prefs.setString(_kFolder, cameraFolderPath);
    if (backupVideos != null) await prefs.setBool(_kVideos, backupVideos);
    if (dailyLimitMB != null) await prefs.setInt(_kLimitMB, dailyLimitMB);
    if (wifiOnly != null) await prefs.setBool(_kWifiOnly, wifiOnly);
    if (scheduledHour != null) {
      await prefs.setInt(_kScheduledHour, scheduledHour);
      _scheduleNextDailyRun();
    }
  }

  Future<void> recordBytesBackedUp(int bytes) async {
    final prefs = await SharedPreferences.getInstance();
    final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final current = (prefs.getString(_kUsageDate) == todayStr)
        ? (prefs.getInt(_kUsageBytes) ?? 0)
        : 0;
    await prefs.setInt(_kUsageBytes, current + bytes);
    await prefs.setString(_kUsageDate, todayStr);
    await prefs.setInt(_kLastTime, DateTime.now().millisecondsSinceEpoch);
  }

  // ── Intelligent Once-Per-Day Backup Runner ─────────────────────────────────

  /// Checks if today's daily backup has run. If not, runs once and terminates cleanly.
  /// Zero 24/7 background drain!
  Future<void> checkAndRunDailyBackup({bool isManual = false}) async {
    if (_isSyncing) return;
    try {
      final config = await loadConfig();
      if (!config.isEnabled && !isManual) return;

      // If today is already backed up, DO NOT run again today. Battery stays 100% saved!
      if (!isManual && config.isCompletedForToday) {
        debugPrint('[AutoBackup] Today\'s daily backup is already completed. Sleeping until tomorrow.');
        return;
      }

      if (config.hasReachedDailyLimit && !isManual) {
        debugPrint('[AutoBackup] Daily data limit reached for today. Sleeping.');
        return;
      }

      // Check Wi-Fi constraint
      if (config.wifiOnly && !isManual) {
        final connectivityResults = await Connectivity().checkConnectivity();
        final onWifi = connectivityResults.contains(ConnectivityResult.wifi);
        if (!onWifi) {
          debugPrint('[AutoBackup] Wi-Fi only enabled, waiting for Wi-Fi connection.');
          return;
        }
      }

      if (_ref == null) return;
      final authService = (_ref is WidgetRef)
          ? _ref.read(telegramAuthServiceProvider)
          : (_ref as Ref).read(telegramAuthServiceProvider);
      final metadataService = LocalMetadataService();

      await runBackup(
        authService: authService,
        metadataService: metadataService,
        isManual: isManual,
      );
    } catch (e) {
      debugPrint('[AutoBackup] Error in checkAndRunDailyBackup: $e');
    }
  }

  // ── Core Backup Execution ──────────────────────────────────────────────────

  Future<void> runBackup({
    required TelegramAuthService authService,
    required LocalMetadataService metadataService,
    bool isManual = false,
  }) async {
    if (_isSyncing) {
      debugPrint('[AutoBackup] Backup already in progress. Skipping.');
      return;
    }

    final config = await loadConfig();
    if (!config.isEnabled && !isManual) {
      _emit(const AutoBackupProgress(status: AutoBackupStatus.idle));
      return;
    }

    _isSyncing = true;
    _isCancelled = false;
    bool foregroundStarted = false;

    _emit(const AutoBackupProgress(
      status: AutoBackupStatus.scanning,
      message: 'Scanning camera folder for new media…',
    ));

    try {
      final profile = await authService.getProfile();
      final userId = profile['userId'] ?? '';
      if (userId.isEmpty) {
        _emit(const AutoBackupProgress(
          status: AutoBackupStatus.error,
          message: 'Not logged in to Telegram',
        ));
        return;
      }

      // 1. Locate Camera Directory
      final dir = Directory(config.cameraFolderPath);
      final targetDir = await dir.exists() ? dir : Directory('/storage/emulated/0/DCIM');
      if (!await targetDir.exists()) {
        _emit(AutoBackupProgress(
          status: AutoBackupStatus.error,
          message: 'Camera directory not found: ${config.cameraFolderPath}',
        ));
        return;
      }

      // 2. Allowed extensions
      final photoExts = {'jpg', 'jpeg', 'png', 'heic', 'webp', 'dng'};
      final videoExts = {'mp4', 'mov', 'mkv', '3gp'};

      final allowedExts = <String>{...photoExts};
      if (config.backupVideos) {
        allowedExts.addAll(videoExts);
      }

      // 3. Scan local files
      final localFiles = <File>[];
      try {
        await for (final entity in targetDir.list(recursive: false, followLinks: false)) {
          if (entity is File) {
            final ext = entity.path.split('.').last.toLowerCase();
            if (allowedExts.contains(ext)) {
              localFiles.add(entity);
            }
          }
        }
      } catch (e) {
        debugPrint('[AutoBackup] Error scanning directory: $e');
      }

      localFiles.sort((a, b) {
        try {
          return b.lastModifiedSync().compareTo(a.lastModifiedSync());
        } catch (_) {
          return 0;
        }
      });

      final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());

      if (localFiles.isEmpty) {
        // Mark today as completed so no continuous wakeups happen
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kLastDailyDone, todayStr);

        _emit(const AutoBackupProgress(
          status: AutoBackupStatus.completed,
          message: 'No camera media found to back up',
        ));
        return;
      }

      // 4. Filter out already backed-up files from database
      final existingNames = await metadataService.getExistingFileNames(userId);
      final pendingFiles = localFiles.where((f) {
        final name = f.path.split(Platform.pathSeparator).last;
        return !existingNames.contains(name);
      }).toList();

      if (pendingFiles.isEmpty) {
        // All photos are already backed up! Mark today as done and terminate immediately
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kLastDailyDone, todayStr);

        _emit(const AutoBackupProgress(
          status: AutoBackupStatus.completed,
          message: 'Today\'s photos are completely backed up! ✓',
        ));
        return;
      }

      // Start Android Foreground Service ONLY while active uploading happens
      await UploadBackgroundService.startUpload('Daily Auto Backup');
      foregroundStarted = true;

      // 5. Upload files respecting daily data budget
      final tgStorage = TelegramStorageService(authService);
      int backedUpCount = 0;
      int currentUsage = config.todayUsageBytes;
      final limitBytes = config.dailyLimitBytes;

      for (int i = 0; i < pendingFiles.length; i++) {
        if (_isCancelled) {
          _emit(const AutoBackupProgress(
            status: AutoBackupStatus.idle,
            message: 'Backup paused',
          ));
          return;
        }

        final file = pendingFiles[i];
        final fileName = file.path.split(Platform.pathSeparator).last;
        final fileSize = await file.length();

        // Check Daily Budget
        if (config.dailyLimitMB > 0 && (currentUsage + fileSize) > limitBytes) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_kLastDailyDone, todayStr);

          _emit(AutoBackupProgress(
            status: AutoBackupStatus.limitReached,
            totalFiles: pendingFiles.length,
            processedFiles: backedUpCount,
            currentFileName: fileName,
            message: 'Daily limit reached (${config.dailyLimitMB} MB). Resumes tomorrow.',
          ));
          return;
        }

        _emit(AutoBackupProgress(
          status: AutoBackupStatus.backingUp,
          totalFiles: pendingFiles.length,
          processedFiles: backedUpCount,
          currentFileName: fileName,
          currentFileProgress: 0.0,
          message: 'Backing up $fileName (${i + 1}/${pendingFiles.length})',
        ));

        try {
          final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
          final mime = lookupMimeType(file.path) ?? 'application/octet-stream';

          final uploadResult = await tgStorage.uploadFileChunked(
            file,
            folderPath: '/Camera',
            onProgress: (p) {
              UploadBackgroundService.updateProgress(fileName, p);
              _emit(AutoBackupProgress(
                status: AutoBackupStatus.backingUp,
                totalFiles: pendingFiles.length,
                processedFiles: backedUpCount,
                currentFileName: fileName,
                currentFileProgress: p,
                message: 'Uploading $fileName: ${(p * 100).toInt()}%',
              ));
            },
          );

          // 1. Create a local persistent thumbnail for the backed-up photo
          String? thumbPath;
          if (photoExts.contains(ext)) {
            try {
              final appDocDir = await getApplicationDocumentsDirectory();
              final thumbDir = Directory(p.join(appDocDir.path, 'thumbnails'));
              if (!await thumbDir.exists()) await thumbDir.create(recursive: true);
              thumbPath = p.join(thumbDir.path, 'thumb_${DateTime.now().microsecondsSinceEpoch}_$fileName');
              await file.copy(thumbPath);
            } catch (e) {
              debugPrint('[AutoBackup] Error creating thumbnail copy: $e');
            }
          }

          // 2. Save metadata with thumbnailPath
          final savedCloudFile = await metadataService.saveFileMetadata(
            userId: userId,
            name: fileName,
            folderPath: '/Camera',
            telegramMessageId: uploadResult.primaryMessageId,
            telegramFileId: uploadResult.primaryMessageId.toString(),
            mimeType: mime,
            sizeBytes: fileSize,
            extension: ext,
            thumbnailPath: thumbPath,
            chunkMessageIds: uploadResult.allMessageIds,
          );

          // 3. Trigger face detection immediately on the backed up photo
          if (thumbPath != null && File(thumbPath).existsSync()) {
            try {
              await FaceDetectionService.instance.scanSingleFile(userId, savedCloudFile, thumbPath);
            } catch (e) {
              debugPrint('[AutoBackup] Face detection error on $fileName: $e');
            }
          }

          // Invalidate gallery streams so photo and thumbnail appear in Gallery right away
          if (_ref != null) {
            try {
              final driveNotifier = (_ref is WidgetRef)
                  ? _ref.read(driveProvider.notifier)
                  : (_ref as Ref).read(driveProvider.notifier);
              driveNotifier.invalidateCategoryStreams();
            } catch (_) {}
          }

          currentUsage += fileSize;
          await recordBytesBackedUp(fileSize);
          backedUpCount++;
        } catch (e) {
          debugPrint('[AutoBackup] Failed to back up $fileName: $e');
        }
      }

      // Mark today's daily backup as successfully completed
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLastDailyDone, todayStr);

      _emit(AutoBackupProgress(
        status: AutoBackupStatus.completed,
        totalFiles: pendingFiles.length,
        processedFiles: backedUpCount,
        message: backedUpCount > 0
            ? 'Successfully backed up $backedUpCount items for today!'
            : 'Today\'s backup complete',
      ));
    } catch (e) {
      _emit(AutoBackupProgress(
        status: AutoBackupStatus.error,
        message: 'Backup error: $e',
      ));
    } finally {
      // Cleanly stop and terminate foreground service as soon as daily backup finishes
      if (foregroundStarted) {
        await UploadBackgroundService.stopUpload();
      }
      _isSyncing = false;
      debugPrint('[AutoBackup] Daily backup terminated. Background services completely shut down.');
    }
  }

  void cancel() {
    _isCancelled = true;
  }
}
