import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/file_utils.dart';
import '../../../../core/services/upload_background_service.dart';
import '../../data/models/cloud_file.dart';
import '../../data/telegram_storage_service.dart';
import '../../../auth/data/telegram_auth_service.dart';
import '../providers/drive_provider.dart';

export '../../data/offline_cache_service.dart' show OfflineStatus;
export '../providers/offline_cache_provider.dart'
    show offlineCacheProvider, fileOfflineStateProvider, FileOfflineState;

// ── Download task model ───────────────────────────────────────────────────────

enum DlStatus { queued, downloading, done, failed }

class DlTask {
  final String id;
  final String name;
  final String url;
  final String ext;
  DlStatus status;
  double progress;
  String? savedPath;
  String? error;
  int totalBytes;
  final CloudFile? cloudFile; // stored for retry on failed cloud downloads

  DlTask({
    required this.id,
    required this.name,
    required this.url,
    required this.ext,
    this.status = DlStatus.queued,
    this.progress = 0,
    this.savedPath,
    this.error,
    this.totalBytes = 0,
    this.cloudFile,
  });
}

// ── Download Manager State ────────────────────────────────────────────────────

class DlManagerNotifier extends StateNotifier<List<DlTask>> {
  DlManagerNotifier() : super([]);

  final _dio = Dio();

  /// Get public Downloads directory (visible in file manager & gallery)
  Future<Directory> _downloadsDir() async {
    if (Platform.isAndroid) {
      final dir = Directory('/storage/emulated/0/Download/LimitlessCloud');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/Downloads');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Returns a unique file path — if [base] already exists, appends (1), (2) … until free.
  String _uniquePath(String dirPath, String fileName) {
    final file = File('$dirPath/$fileName');
    if (!file.existsSync()) return file.path;

    // Split name and extension
    final dotIdx = fileName.lastIndexOf('.');
    final name = dotIdx >= 0 ? fileName.substring(0, dotIdx) : fileName;
    final ext  = dotIdx >= 0 ? fileName.substring(dotIdx) : '';

    int counter = 1;
    while (true) {
      final candidate = File('$dirPath/$name ($counter)$ext');
      if (!candidate.existsSync()) return candidate.path;
      counter++;
    }
  }

  Future<bool> _requestPermission() async {
    if (Platform.isAndroid) {
      // Android 13+ uses READ_MEDIA_* instead of WRITE_EXTERNAL_STORAGE
      final sdk = await _getSdkInt();
      if (sdk >= 33) return true; // Scoped storage — no permission needed for own folder
      final status = await Permission.storage.request();
      return status.isGranted;
    }
    return true;
  }

  Future<int> _getSdkInt() async {
    try {
      final result = await Process.run('getprop', ['ro.build.version.sdk']);
      return int.tryParse(result.stdout.toString().trim()) ?? 30;
    } catch (_) {
      return 30;
    }
  }

  /// Download a Telegram cloud file to public Downloads folder.
  ///
  /// Routing:
  ///   • Single-message file (sizeBytes < 2 GB or chunkMessageIds empty)
  ///     → GET  /files/download/{message_id}          (parallel stream)
  ///   • Multi-part file (chunkMessageIds has 2+ IDs)
  ///     → POST /files/download-chunked               (stitched stream)
  ///
  /// Reliability:
  ///   • receiveTimeout = Duration.zero (no timeout — large files take time)
  ///   • Up to 3 automatic retries with 5 s / 15 s / 30 s back-off
  ///   • Foreground notification keeps download alive when app is closed
  Future<void> downloadCloudFile(CloudFile file, TelegramStorageService tg) async {
    final taskId = file.id;
    if (state.any((t) => t.id == taskId && t.status == DlStatus.downloading)) return;
    state = state.where((t) => t.id != taskId || t.status == DlStatus.downloading).toList();

    state = [...state, DlTask(
      id: taskId, name: file.name, url: '', ext: file.extension,
      totalBytes: file.sizeBytes, cloudFile: file,
    )];
    _updateTask(taskId, status: DlStatus.downloading, progress: 0);

    const maxRetries = 3;
    final backoffs = [5, 15, 30]; // seconds between retries

    // Start foreground service so download continues when app is closed
    await UploadBackgroundService.startUpload('Downloading ${file.name}');

    for (var attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final ok = await _requestPermission();
        if (!ok) throw Exception('Storage permission denied');

        final dir  = await _downloadsDir();
        final dest = _uniquePath(dir.path, file.name);
        final session = await tg.authService.getSession();
        final base    = tg.backendBaseUrl;

        // ── Route: chunked (>2 GB multi-part) vs single message ──────────────
        if (file.isChunked && file.chunkMessageIds.length > 1) {
          // POST /files/download-chunked with all part message IDs
          await _dio.download(
            '$base/files/download-chunked',
            dest,
            deleteOnError: true,
            data: jsonEncode({
              'session_string': session,
              'message_ids': file.chunkMessageIds,
            }),
            options: Options(
              method: 'POST',
              headers: {'Content-Type': 'application/json'},
              receiveTimeout: Duration.zero,   // no timeout — large files
              sendTimeout: const Duration(seconds: 30),
              responseType: ResponseType.stream,
            ),
            onReceiveProgress: (received, total) {
              final t = total > 0 ? total : file.sizeBytes;
              _updateTask(taskId,
                progress: t > 0 ? received / t : -1,
                totalBytes: t > 0 ? t : received);
              UploadBackgroundService.updateProgress(file.name, t > 0 ? received / t : 0);
            },
          );
        } else {
          // GET /files/download/{message_id} — single Telegram message
          await _dio.download(
            '$base/files/download/${file.telegramMessageId}',
            dest,
            deleteOnError: true,
            queryParameters: {'session_string': session},
            options: Options(
              receiveTimeout: Duration.zero,   // no timeout — large files
              sendTimeout: const Duration(seconds: 30),
              responseType: ResponseType.stream,
            ),
            onReceiveProgress: (received, total) {
              final t = total > 0 ? total : file.sizeBytes;
              _updateTask(taskId,
                progress: t > 0 ? received / t : -1,
                totalBytes: t > 0 ? t : received);
              UploadBackgroundService.updateProgress(file.name, t > 0 ? received / t : 0);
            },
          );
        }

        _updateTask(taskId, status: DlStatus.done, progress: 1.0, savedPath: dest);
        await UploadBackgroundService.stopUpload();
        return; // success — exit retry loop

      } on DioException catch (e) {
        final isLast = attempt == maxRetries;
        if (isLast) {
          final msg = _friendlyDlError(e);
          _updateTask(taskId, status: DlStatus.failed, error: msg);
          await UploadBackgroundService.stopUpload();
          return;
        }
        // Wait then retry
        _updateTask(taskId,
          status: DlStatus.downloading,
          error: 'Retrying ($attempt/$maxRetries)…');
        await Future.delayed(Duration(seconds: backoffs[attempt - 1]));

      } catch (e) {
        final isLast = attempt == maxRetries;
        if (isLast) {
          _updateTask(taskId, status: DlStatus.failed,
            error: e.toString().replaceFirst('Exception: ', ''));
          await UploadBackgroundService.stopUpload();
          return;
        }
        _updateTask(taskId,
          status: DlStatus.downloading,
          error: 'Retrying ($attempt/$maxRetries)…');
        await Future.delayed(Duration(seconds: backoffs[attempt - 1]));
      }
    }
  }

  /// Human-friendly download error message
  String _friendlyDlError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
        return 'Connection timed out. Check internet and retry.';
      case DioExceptionType.receiveTimeout:
        return 'Download timed out mid-stream. Tap retry.';
      case DioExceptionType.connectionError:
        return 'Connection lost. Tap retry when back online.';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode ?? 0;
        if (code == 404) return 'File not found on server (404).';
        if (code == 401) return 'Session expired. Please log out and log in again.';
        if (code >= 500) return 'Server error ($code). Try again in a moment.';
        return 'Server returned $code.';
      default:
        return e.message ?? 'Download failed. Tap retry.';
    }
  }

  /// Download any URL to device with max speed Dio settings.
  Future<void> downloadUrl(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return;

    final segments = uri.pathSegments;
    String name = segments.isNotEmpty ? segments.last : 'download_${DateTime.now().millisecondsSinceEpoch}';
    if (!name.contains('.')) name += '.bin';
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';

    final taskId = DateTime.now().microsecondsSinceEpoch.toString();
    state = [...state, DlTask(id: taskId, name: name, url: url, ext: ext)];
    _updateTask(taskId, status: DlStatus.downloading);

    const maxRetries = 3;
    final backoffs = [5, 15, 30];

    await UploadBackgroundService.startUpload('Downloading $name');

    for (var attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final ok = await _requestPermission();
        if (!ok) throw Exception('Storage permission denied');

        final dir  = await _downloadsDir();
        final dest = _uniquePath(dir.path, name);

        await _dio.download(
          url, dest,
          deleteOnError: true,
          options: Options(
            receiveTimeout: Duration.zero, // no timeout — large files
            sendTimeout: const Duration(seconds: 30),
            responseType: ResponseType.stream,
            headers: {
              'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120.0',
              'Accept-Encoding': 'identity',
            },
          ),
          onReceiveProgress: (received, total) {
            if (total > 0) {
              _updateTask(taskId, progress: received / total, totalBytes: total);
              UploadBackgroundService.updateProgress(name, received / total);
            } else {
              _updateTask(taskId, progress: -1, totalBytes: received);
            }
          },
        );
        _updateTask(taskId, status: DlStatus.done, progress: 1.0, savedPath: dest);
        await UploadBackgroundService.stopUpload();
        return;

      } on DioException catch (e) {
        if (attempt == maxRetries) {
          _updateTask(taskId, status: DlStatus.failed, error: _friendlyDlError(e));
          await UploadBackgroundService.stopUpload();
          return;
        }
        _updateTask(taskId, status: DlStatus.downloading, error: 'Retrying ($attempt/$maxRetries)…');
        await Future.delayed(Duration(seconds: backoffs[attempt - 1]));
      } catch (e) {
        if (attempt == maxRetries) {
          _updateTask(taskId, status: DlStatus.failed, error: e.toString().replaceFirst('Exception: ', ''));
          await UploadBackgroundService.stopUpload();
          return;
        }
        _updateTask(taskId, status: DlStatus.downloading, error: 'Retrying ($attempt/$maxRetries)…');
        await Future.delayed(Duration(seconds: backoffs[attempt - 1]));
      }
    }
  }


  /// Upload URL content → Telegram Saved Messages via chunked upload with live % progress.
  ///
  /// Flow:
  ///   1. HTTP HEAD to get Content-Length (for progress calc)
  ///   2. Stream-download URL to a temp file with progress (0%→50%)
  ///   3. Chunked-upload temp file to Telegram with progress (50%→100%)
  ///   4. Delete temp file
  Future<void> uploadUrl(String url, TelegramStorageService tg) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return;

    final segments = uri.pathSegments;
    String name = segments.isNotEmpty
        ? segments.last
        : 'upload_${DateTime.now().millisecondsSinceEpoch}';
    if (!name.contains('.')) name += '.bin';
    final ext = name.split('.').last.toLowerCase();

    final taskId = 'ul_${DateTime.now().microsecondsSinceEpoch}';
    state = [...state, DlTask(
      id: taskId, name: '☁ $name', url: url, ext: ext,
    )];
    _updateTask(taskId, status: DlStatus.downloading, progress: 0);

    // Temp file named with the REAL filename so Telegram stores it correctly
    final tmpDir = Directory.systemTemp;
    final tmpFile = File('${tmpDir.path}/$name');

    try {
      // ── Phase 1: stream-download URL → temp file (progress 0%→50%) ──────
      await _dio.download(
        url,
        tmpFile.path,
        deleteOnError: true,
        options: Options(
          receiveTimeout: const Duration(minutes: 60),
          sendTimeout: const Duration(seconds: 30),
          responseType: ResponseType.stream,
          headers: {
            'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120.0',
            'Accept-Encoding': 'identity',
          },
        ),
        onReceiveProgress: (received, total) {
          if (total > 0) {
            // Map phase 1 to 0→50%
            _updateTask(taskId, progress: (received / total) * 0.5, totalBytes: total);
          } else {
            _updateTask(taskId, progress: -1, totalBytes: received);
          }
        },
      );

      _updateTask(taskId, progress: 0.5);

      // ── Phase 2: chunked-upload temp file → Telegram (progress 50%→100%) ──
      await tg.uploadFileChunked(
        tmpFile,
        onProgress: (p) {
          // Map phase 2 to 50→100%
          _updateTask(taskId, progress: 0.5 + p * 0.5);
        },
      );

      _updateTask(taskId, status: DlStatus.done, progress: 1.0,
          savedPath: 'telegram://saved');
    } on DioException catch (e) {
      _updateTask(taskId, status: DlStatus.failed,
          error: e.message ?? 'Download failed (${e.type.name})');
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      _updateTask(taskId, status: DlStatus.failed, error: msg);
    } finally {
      // Clean up temp file regardless of success/failure
      try { await tmpFile.delete(); } catch (_) {}
    }
  }

  void removeTask(String id) {
    state = state.where((t) => t.id != id).toList();
  }

  void _updateTask(String id, {
    DlStatus? status, double? progress, String? savedPath,
    String? error, int? totalBytes,
  }) {
    state = state.map((t) {
      if (t.id != id) return t;
      if (status != null)    t.status    = status;
      if (progress != null)  t.progress  = progress;
      if (savedPath != null) t.savedPath = savedPath;
      if (error != null)     t.error     = error;
      if (totalBytes != null && totalBytes > 0) t.totalBytes = totalBytes;
      return t;
    }).toList();
  }
}

final dlManagerProvider =
    StateNotifierProvider<DlManagerNotifier, List<DlTask>>(
  (_) => DlManagerNotifier(),
);

/// Set this to true to signal the DownloadManagerPage to jump to the Active tab.
/// Automatically resets to false after the jump.
final dlManagerJumpToActiveProvider = StateProvider<bool>((_) => false);

// ── Page ──────────────────────────────────────────────────────────────────────

class DownloadManagerPage extends ConsumerStatefulWidget {
  final Map<String, dynamic>? args;
  const DownloadManagerPage({super.key, this.args});
  @override
  ConsumerState<DownloadManagerPage> createState() => _DownloadManagerPageState();
}

class _DownloadManagerPageState extends ConsumerState<DownloadManagerPage>
    with SingleTickerProviderStateMixin {
  late TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);

    // If a CloudFile was passed (from file detail), start downloading it
    final file = args?['file'] as CloudFile?;
    if (file != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _startCloudDownload(file));
    }

    // Check if we should jump to Active tab immediately on build
    // (dlManagerJumpToActiveProvider may already be true before this widget builds)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final shouldJump = ref.read(dlManagerJumpToActiveProvider);
      if (shouldJump) {
        _tab.animateTo(1);
        ref.read(dlManagerJumpToActiveProvider.notifier).state = false;
      }
    });
  }

  Map<String, dynamic>? get args => widget.args;

  Future<void> _startCloudDownload(CloudFile file) async {
    final auth = ref.read(telegramAuthServiceProvider);
    final tg = TelegramStorageService(auth);
    ref.read(dlManagerProvider.notifier).downloadCloudFile(file, tg);
    _tab.animateTo(1); // switch to Active tab
  }

  @override
  void dispose() { _tab.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    // Also listen for changes WHILE widget is already visible
    // (e.g. user starts a download and taps View while already on Downloads page)
    ref.listen<bool>(dlManagerJumpToActiveProvider, (_, shouldJump) {
      if (shouldJump) {
        _tab.animateTo(1);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ref.read(dlManagerJumpToActiveProvider.notifier).state = false;
          }
        });
      }
    });

    final tasks = ref.watch(dlManagerProvider);
    final active   = tasks.where((t) => t.status == DlStatus.downloading || t.status == DlStatus.queued).length;
    final done     = tasks.where((t) => t.status == DlStatus.done).length;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: Row(children: [
          Container(
            width: 30, height: 30,
            decoration: BoxDecoration(
              gradient: AppTheme.primaryGradient,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.download_for_offline_rounded, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          Text('Download Manager', style: AppTheme.titleLarge),
        ]),
        bottom: TabBar(
          controller: _tab,
          indicatorColor: AppTheme.primary,
          labelColor: AppTheme.primary,
          unselectedLabelColor: AppTheme.textHint,
          tabs: [
            const Tab(icon: Icon(Icons.cloud_download_rounded, size: 18), text: 'My Files'),
            Tab(icon: const Icon(Icons.downloading_rounded, size: 18), text: 'Active ($active)'),
            Tab(icon: const Icon(Icons.folder_rounded, size: 18), text: 'Done ($done)'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _MyFilesTab(onDownload: _startCloudDownload),
          _ActiveTab(tasks: tasks),
          _DoneTab(tasks: tasks),
        ],
      ),
      // URL download FAB
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppTheme.primary,
        icon: const Icon(Icons.link_rounded, color: Colors.white),
        label: const Text('Add URL', style: TextStyle(color: Colors.white)),
        onPressed: _showUrlDialog,
      ),
    );
  }

  void _showUrlDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          backgroundColor: AppTheme.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(children: [
            Icon(Icons.link_rounded, color: AppTheme.primary),
            SizedBox(width: 8),
            Text('URL Action', style: TextStyle(color: Colors.white, fontSize: 16)),
          ]),
          actions: null,
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(
              'Paste a direct URL. Choose where the file goes:',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: ctrl,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                hintText: 'https://example.com/file.mp4',
                prefixIcon: Icon(Icons.public_rounded, color: AppTheme.textHint),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 16),
            // ── Upload to Telegram ──────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.cloud_upload_rounded, size: 16),
                label: const Text('Save to Telegram  (progress shown live)'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.lightBlueAccent,
                  side: const BorderSide(color: Colors.lightBlueAccent),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: () {
                  final url = ctrl.text.trim();
                  if (url.isNotEmpty) {
                    final auth = ref.read(telegramAuthServiceProvider);
                    final tg = TelegramStorageService(auth);
                    ref.read(dlManagerProvider.notifier).uploadUrl(url, tg);
                    Navigator.pop(ctx);
                    _tab.animateTo(1);
                  }
                },
              ),
            ),
            const SizedBox(height: 8),
            // ── Download to device ──────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.download_rounded, size: 16),
                label: const Text('Save to Device Downloads'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: () {
                  final url = ctrl.text.trim();
                  if (url.isNotEmpty) {
                    ref.read(dlManagerProvider.notifier).downloadUrl(url);
                    Navigator.pop(ctx);
                    _tab.animateTo(1);
                  }
                },
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
          ]),
        ),
      ),
    ).whenComplete(() => ctrl.dispose());
  }
}

// ── My Files Tab — shows all drive files with download button ─────────────────

class _MyFilesTab extends ConsumerWidget {
  final Future<void> Function(CloudFile) onDownload;
  const _MyFilesTab({required this.onDownload});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filesAsync = ref.watch(allFilesProvider((starredOnly: false, trashedOnly: false)));
    return filesAsync.when(
      data: (files) {
        if (files.isEmpty) {
          return const _EmptyState(
            icon: Icons.cloud_off_rounded,
            title: 'No files yet',
            subtitle: 'Upload files to Limitless Cloud\nthen download them to your device here.',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
          itemCount: files.length,
          itemBuilder: (_, i) => _CloudFileTile(file: files[i], onDownload: onDownload),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
    );
  }
}

class _CloudFileTile extends StatelessWidget {
  final CloudFile file;
  final Future<void> Function(CloudFile) onDownload;
  const _CloudFileTile({required this.file, required this.onDownload});

  @override
  Widget build(BuildContext context) {
    final color = FileUtils.getFileColor(file.extension);
    final icon  = FileUtils.getFileIcon(file.extension);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(children: [
        Container(
          width: 42, height: 42,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(file.name, style: AppTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(FileUtils.formatFileSize(file.sizeBytes),
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
        ])),
        IconButton(
          icon: const Icon(Icons.download_rounded, color: AppTheme.primary),
          tooltip: 'Save to device',
          onPressed: () => onDownload(file),
        ),
      ]),
    );
  }
}

// ── Active Tab ────────────────────────────────────────────────────────────────

class _ActiveTab extends ConsumerWidget {
  final List<DlTask> tasks;
  const _ActiveTab({required this.tasks});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = tasks.where((t) =>
        t.status == DlStatus.downloading ||
        t.status == DlStatus.queued ||
        t.status == DlStatus.failed).toList();

    if (active.isEmpty) {
      return const _EmptyState(
        icon: Icons.check_circle_outline_rounded,
        title: 'No active downloads',
        subtitle: 'Downloads in progress appear here.',
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: active.map((t) => _TaskTile(
        task: t,
        onCancel: () => ref.read(dlManagerProvider.notifier).removeTask(t.id),
        showProgress: true,
        onRetry: t.status == DlStatus.failed
            ? () {
                ref.read(dlManagerProvider.notifier).removeTask(t.id);
                if (t.cloudFile != null) {
                  // Retry cloud file download
                  final auth = ref.read(telegramAuthServiceProvider);
                  final tg = TelegramStorageService(auth);
                  ref.read(dlManagerProvider.notifier).downloadCloudFile(t.cloudFile!, tg);
                } else if (t.url.isNotEmpty) {
                  // Retry URL download
                  ref.read(dlManagerProvider.notifier).downloadUrl(t.url);
                }
              }
            : null,
      )).toList(),
    );
  }
}

// ── Done Tab ──────────────────────────────────────────────────────────────────

class _DoneTab extends ConsumerWidget {
  final List<DlTask> tasks;
  const _DoneTab({required this.tasks});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final done = tasks.where((t) => t.status == DlStatus.done).toList();

    if (done.isEmpty) {
      return const _EmptyState(
        icon: Icons.folder_open_rounded,
        title: 'No completed downloads',
        subtitle: 'Finished files appear here.\nThey are saved in your device Downloads folder.',
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.success.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.success.withValues(alpha: 0.25)),
          ),
          child: const Row(children: [
            Icon(Icons.folder_rounded, color: AppTheme.success, size: 18),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Saved to: Downloads/LimitlessCloud\nVisible in your Files app & Gallery',
                style: TextStyle(color: AppTheme.success, fontSize: 11, height: 1.5),
              ),
            ),
          ]),
        ),
        ...done.map((t) => _TaskTile(
          task: t,
          onCancel: () => ref.read(dlManagerProvider.notifier).removeTask(t.id),
          showProgress: false,
          onOpen: (t.savedPath != null && t.savedPath != 'telegram://saved')
              ? () => OpenFilex.open(t.savedPath!)
              : null,
        )),
      ],
    );
  }
}

// ── Task Tile ─────────────────────────────────────────────────────────────────

class _TaskTile extends StatelessWidget {
  final DlTask task;
  final VoidCallback onCancel;
  final VoidCallback? onOpen;
  final VoidCallback? onRetry;
  final bool showProgress;
  const _TaskTile({required this.task, required this.onCancel,
      this.onOpen, this.onRetry, required this.showProgress});

  @override
  Widget build(BuildContext context) {
    final color = task.ext.isEmpty
        ? AppTheme.fileColorDefault : FileUtils.getFileColor(task.ext);
    final icon  = task.ext.isEmpty
        ? Icons.insert_drive_file_rounded : FileUtils.getFileIcon(task.ext);
    final isFailed = task.status == DlStatus.failed;
    final isDone   = task.status == DlStatus.done;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isFailed
            ? AppTheme.error.withValues(alpha: 0.3) : AppTheme.cardBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 42, height: 42,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(task.name, style: AppTheme.titleMedium,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              isFailed
                  ? task.error ?? 'Failed'
                  : isDone
                      ? (task.savedPath == 'telegram://saved'
                          ? '✓ Saved to Telegram Saved Messages'
                          : '✓ Saved to device Downloads')
                      : task.progress < 0
                          ? 'Fetching…${task.totalBytes > 0 ? '  ${FileUtils.formatFileSize(task.totalBytes)}' : ''}'
                          : task.name.startsWith('☁')
                              ? task.progress < 0.5
                                  ? 'Fetching URL… ${(task.progress * 200).toInt()}%'
                                  : 'Uploading to Telegram… ${((task.progress - 0.5) * 200).toInt()}%'
                              : '${(task.progress * 100).toInt()}%'
                                  '${task.totalBytes > 0 ? '  ·  ${FileUtils.formatFileSize(task.totalBytes)}' : ''}',
              style: TextStyle(
                  color: isFailed
                      ? AppTheme.error
                      : isDone ? AppTheme.success : AppTheme.textSecondary,
                  fontSize: 11),
            ),
          ])),
          if (onOpen != null)
            IconButton(
              icon: const Icon(Icons.open_in_new_rounded, size: 20, color: AppTheme.primary),
              onPressed: onOpen,
              tooltip: 'Open file',
            ),
          if (onRetry != null)
            IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 20, color: AppTheme.warning),
              onPressed: onRetry,
              tooltip: 'Retry download',
            ),
          IconButton(
            icon: Icon(
              isDone ? Icons.close_rounded : Icons.cancel_rounded,
              size: 20,
              color: AppTheme.error,
            ),
            onPressed: onCancel,
            tooltip: isDone ? 'Remove from list' : 'Cancel',
          ),
        ]),

        if (showProgress && !isFailed && !isDone) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              // progress < 0 → indeterminate; 0 queued → also indeterminate
              value: task.progress > 0 ? task.progress : null,
              backgroundColor: AppTheme.surfaceVariant,
              valueColor: AlwaysStoppedAnimation(
                task.progress < 0 ? Colors.lightBlueAccent : AppTheme.primary,
              ),
              minHeight: 4,
            ),
          ),
        ],
      ]),
    );
  }
}

// ── Empty State ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _EmptyState({required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 80, height: 80,
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: AppTheme.primary, size: 40),
          ),
          const SizedBox(height: 20),
          Text(title, style: AppTheme.titleLarge),
          const SizedBox(height: 8),
          Text(subtitle,
              style: AppTheme.bodyMedium.copyWith(height: 1.6),
              textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}
