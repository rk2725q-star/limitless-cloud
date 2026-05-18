import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/file_utils.dart';
import '../../../../core/utils/date_utils.dart';
import '../../data/models/cloud_file.dart';
import '../../data/offline_cache_service.dart';
import '../../data/telegram_storage_service.dart';
import '../../../auth/data/telegram_auth_service.dart';
import '../providers/drive_provider.dart';
import '../providers/offline_cache_provider.dart';

/// File detail page — shows info, offline toggle, star/share/delete.
/// Tapping "Open" downloads the file to a temp dir and hands it to
/// whatever native app the user picks (Gallery, VLC, Docs, etc.).
class FileDetailPage extends ConsumerStatefulWidget {
  final Map<String, dynamic> args;
  const FileDetailPage({super.key, required this.args});

  @override
  ConsumerState<FileDetailPage> createState() => _FileDetailPageState();
}

class _FileDetailPageState extends ConsumerState<FileDetailPage> {
  CloudFile get _file => widget.args['file'] as CloudFile;

  bool _isOpening = false;
  String? _openError;

  // ── Open with native device app ──────────────────────────────────────────

  Future<void> _openWithNativeApp() async {
    setState(() { _isOpening = true; _openError = null; });
    try {
      // 1. Check offline cache first
      final offlineState = ref.read(fileOfflineStateProvider(_file.id));
      String? localPath = offlineState.localPath;

      // 2. If not cached, download to temp folder
      if (localPath == null || !File(localPath).existsSync()) {
        final authService = ref.read(telegramAuthServiceProvider);
        final telegramService = TelegramStorageService(authService);

        final tmpDir = await getTemporaryDirectory();
        final tmpFile = File('${tmpDir.path}/${_file.name}');

        // Stream download from Telegram
        final downloaded = await telegramService.downloadFile(
          _file.telegramMessageId,
          _file.name,
        );
        await downloaded.copy(tmpFile.path);
        localPath = tmpFile.path;
      }

      // 3. Hand off to device — triggers "Open With" chooser
      final result = await OpenFilex.open(localPath, type: _file.mimeType);

      if (result.type == ResultType.noAppToOpen) {
        setState(() => _openError =
            'No app found to open this file type.\nTry installing an app that supports .${_file.extension}');
      } else if (result.type == ResultType.error ||
                 result.type == ResultType.permissionDenied) {
        setState(() => _openError = result.message);
      }
    } catch (e) {
      setState(() => _openError = 'Could not open file: $e');
    } finally {
      if (mounted) setState(() => _isOpening = false);
    }
  }

  // ── Share ────────────────────────────────────────────────────────────────

  Future<void> _shareFile() async {
    final link = await ref.read(driveProvider.notifier).getShareLink(_file);
    if (mounted && link != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Link: $link'),
        action: SnackBarAction(label: 'OK', onPressed: () {}),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final offlineState = ref.watch(fileOfflineStateProvider(_file.id));
    final color = FileUtils.getFileColor(_file.extension);
    final icon  = FileUtils.getFileIcon(_file.extension);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: Text(_file.name,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15)),
        actions: [
          IconButton(
            icon: Icon(
                _file.isStarred
                    ? Icons.star_rounded
                    : Icons.star_border_rounded,
                color: AppTheme.warning),
            onPressed: () => ref.read(driveProvider.notifier).toggleStar(_file),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [

          // ── File icon ──────────────────────────────────────────────────────
          Center(
            child: Container(
              width: 120, height: 120,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: color.withValues(alpha: 0.3), width: 1.5),
              ),
              child: Icon(icon, color: color, size: 60),
            ),
          ),
          const SizedBox(height: 16),

          Text(_file.name,
              style: AppTheme.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text(FileUtils.getMimeDisplayName(_file.mimeType),
              style: AppTheme.bodyMedium, textAlign: TextAlign.center),

          const SizedBox(height: 28),

          // ── Open button ────────────────────────────────────────────────────
          _OpenButton(
            isLoading: _isOpening,
            error: _openError,
            fileExt: _file.extension,
            onOpen: _openWithNativeApp,
          ),

          const SizedBox(height: 20),

          // ── Offline toggle (Spotify-style) ─────────────────────────────────
          _OfflineToggleCard(file: _file, state: offlineState),

          const SizedBox(height: 20),

          // ── Metadata ──────────────────────────────────────────────────────
          _MetaRow(label: 'Size',
              value: FileUtils.formatFileSize(_file.sizeBytes)),
          _MetaRow(label: 'Type',
              value: _file.mimeType ?? _file.extension.toUpperCase()),
          _MetaRow(label: 'Uploaded',
              value: AppDateUtils.formatDateTime(_file.uploadedAt)),
          if (_file.folderPath != '/')
            _MetaRow(label: 'Location', value: _file.folderPath),

          const SizedBox(height: 28),

          // ── Action buttons ─────────────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _ActionChip(
                icon: Icons.share_rounded,
                label: 'Share',
                color: AppTheme.accent,
                onTap: _shareFile,
              ),
              _ActionChip(
                icon: _file.isStarred
                    ? Icons.star_rounded
                    : Icons.star_border_rounded,
                label: _file.isStarred ? 'Unstar' : 'Star',
                color: AppTheme.warning,
                onTap: () => ref.read(driveProvider.notifier).toggleStar(_file),
              ),
              _ActionChip(
                icon: Icons.delete_outline_rounded,
                label: 'Delete',
                color: AppTheme.error,
                onTap: () {
                  ref.read(driveProvider.notifier).trashFile(_file);
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Open button ───────────────────────────────────────────────────────────────

class _OpenButton extends StatelessWidget {
  final bool isLoading;
  final String? error;
  final String fileExt;
  final VoidCallback onOpen;

  const _OpenButton({
    required this.isLoading,
    required this.error,
    required this.fileExt,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 54,
          child: ElevatedButton.icon(
            onPressed: isLoading ? null : onOpen,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              disabledBackgroundColor: AppTheme.primary.withValues(alpha: 0.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            ),
            icon: isLoading
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.open_in_new_rounded, color: Colors.white),
            label: Text(
              isLoading
                  ? 'Downloading…'
                  : 'Open with Device App',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ),

        if (error != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.error.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.error.withValues(alpha: 0.3)),
            ),
            child: Row(children: [
              const Icon(Icons.warning_amber_rounded,
                  color: AppTheme.error, size: 18),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(error!,
                      style: const TextStyle(
                          color: AppTheme.error, fontSize: 12))),
            ]),
          ),
        ],

        const SizedBox(height: 6),
        Text(
          'The file will be handed to your device\'s default '
          '${_appHint(fileExt)} — you can also choose a different app.',
          style: const TextStyle(
              color: AppTheme.textHint, fontSize: 11, height: 1.5),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  static String _appHint(String ext) {
    final e = ext.toLowerCase();
    if (['jpg','jpeg','png','gif','webp','bmp','heic','tiff'].contains(e)) {
      return 'Gallery / Photos app';
    }
    if (['mp4','mkv','avi','mov','wmv','flv','webm','m4v','3gp'].contains(e)) {
      return 'Video Player';
    }
    if (['mp3','wav','aac','flac','ogg','m4a','wma','opus'].contains(e)) {
      return 'Music Player';
    }
    if (['pdf','doc','docx','xls','xlsx','ppt','pptx'].contains(e)) {
      return 'Document Viewer';
    }
    return 'compatible app';
  }
}

// ── Offline toggle card ───────────────────────────────────────────────────────

class _OfflineToggleCard extends ConsumerWidget {
  final CloudFile file;
  final FileOfflineState state;
  const _OfflineToggleCard({required this.file, required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCached  = state.status == OfflineStatus.cached;
    final isCaching = state.status == OfflineStatus.caching;
    final isFailed  = state.status == OfflineStatus.failed;

    final Color cardColor;
    final Color borderColor;
    final IconData statusIcon;
    final String statusLabel;
    final String statusSub;

    if (isCached) {
      cardColor   = AppTheme.success.withValues(alpha: 0.08);
      borderColor = AppTheme.success.withValues(alpha: 0.3);
      statusIcon  = Icons.check_circle_rounded;
      statusLabel = 'Available Offline';
      statusSub   = 'Stored in app cache · opens instantly without network';
    } else if (isCaching) {
      cardColor   = AppTheme.primary.withValues(alpha: 0.08);
      borderColor = AppTheme.primary.withValues(alpha: 0.3);
      statusIcon  = Icons.downloading_rounded;
      statusLabel = 'Caching… ${(state.progress * 100).toInt()}%';
      statusSub   = 'Downloading to app cache · Tap toggle to cancel';
    } else if (isFailed) {
      cardColor   = AppTheme.error.withValues(alpha: 0.08);
      borderColor = AppTheme.error.withValues(alpha: 0.3);
      statusIcon  = Icons.error_outline_rounded;
      statusLabel = 'Cache failed';
      statusSub   = state.error ?? 'Tap toggle to retry';
    } else {
      cardColor   = AppTheme.card;
      borderColor = AppTheme.cardBorder;
      statusIcon  = Icons.cloud_rounded;
      statusLabel = 'Cloud only';
      statusSub   = 'Enable to open instantly offline (uses app cache)';
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Column(children: [
        Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: isCached
                  ? AppTheme.success.withValues(alpha: 0.15)
                  : AppTheme.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(statusIcon,
                color: isCached
                    ? AppTheme.success
                    : isFailed ? AppTheme.error : AppTheme.primary,
                size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(statusLabel, style: AppTheme.titleMedium),
                const SizedBox(height: 2),
                Text(statusSub,
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 11)),
              ],
            ),
          ),
          // Toggle
          GestureDetector(
            onTap: () => ref.read(offlineCacheProvider.notifier).toggle(file),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 52, height: 28,
              decoration: BoxDecoration(
                color: isCached
                    ? AppTheme.success
                    : isCaching ? AppTheme.primary : AppTheme.surfaceVariant,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: isCached ? AppTheme.success : AppTheme.cardBorder),
              ),
              child: Stack(children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 200),
                  left: isCached || isCaching ? 26 : 2,
                  top: 2,
                  child: Container(
                    width: 24, height: 24,
                    decoration: const BoxDecoration(
                        color: Colors.white, shape: BoxShape.circle),
                    child: isCaching
                        ? const Padding(
                            padding: EdgeInsets.all(4),
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: AppTheme.primary))
                        : null,
                  ),
                ),
              ]),
            ),
          ),
        ]),

        if (isCaching) ...[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: state.progress,
              backgroundColor: AppTheme.surfaceVariant,
              valueColor: const AlwaysStoppedAnimation(AppTheme.primary),
              minHeight: 4,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${FileUtils.formatFileSize((file.sizeBytes * state.progress).toInt())} '
            '/ ${FileUtils.formatFileSize(file.sizeBytes)}',
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
          ),
        ],
      ]),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

class _MetaRow extends StatelessWidget {
  final String label;
  final String value;
  const _MetaRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(children: [
        Text(label,
            style: AppTheme.bodyMedium.copyWith(color: AppTheme.textSecondary)),
        const Spacer(),
        Flexible(child: Text(value, style: AppTheme.bodyMedium,
            overflow: TextOverflow.ellipsis)),
      ]),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionChip(
      {required this.icon, required this.label,
       required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 52, height: 52,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            shape: BoxShape.circle,
            border: Border.all(color: color.withValues(alpha: 0.25)),
          ),
          child: Icon(icon, color: color, size: 24),
        ),
        const SizedBox(height: 6),
        Text(label,
            style: TextStyle(
                color: color, fontSize: 11, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
