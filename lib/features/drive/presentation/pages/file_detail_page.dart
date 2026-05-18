import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_routes.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/file_utils.dart';
import '../../../../core/utils/date_utils.dart';
import '../../data/models/cloud_file.dart';
import '../../data/offline_cache_service.dart';
import '../providers/drive_provider.dart';
import '../providers/offline_cache_provider.dart';

/// Smart file opener — routes each file type to the correct built-in viewer.
/// Also shows the Spotify-style "Available Offline" toggle.
class FileDetailPage extends ConsumerStatefulWidget {
  final Map<String, dynamic> args;
  const FileDetailPage({super.key, required this.args});

  @override
  ConsumerState<FileDetailPage> createState() => _FileDetailPageState();
}

class _FileDetailPageState extends ConsumerState<FileDetailPage> {
  CloudFile get _file => widget.args['file'] as CloudFile;

  bool get _isImage =>
      const ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'tiff']
          .contains(_file.extension.toLowerCase());
  bool get _isVideo =>
      const ['mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'm4v', '3gp']
          .contains(_file.extension.toLowerCase());
  bool get _isAudio =>
      const ['mp3', 'wav', 'aac', 'flac', 'ogg', 'm4a', 'wma', 'opus']
          .contains(_file.extension.toLowerCase());
  bool get _isDocument =>
      const [
        'pdf', 'doc', 'docx', 'odt', 'rtf', 'txt', 'md',
        'dart', 'py', 'js', 'ts', 'html', 'css', 'java', 'kt',
        'swift', 'go', 'rs', 'cpp', 'c', 'h', 'json', 'xml',
        'yaml', 'yml', 'sh', 'xls', 'xlsx', 'ods', 'csv',
      ].contains(_file.extension.toLowerCase());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _openViewer());
  }

  void _openViewer() {
    final offlineState = ref.read(fileOfflineStateProvider(_file.id));
    final fileArgs = {'file': _file};

    // If file is cached offline, open from local path
    if (offlineState.isAvailableOffline && offlineState.localPath != null) {
      final cachedArgs = {
        'file': _file,
        'localPath': offlineState.localPath,
      };
      if (_isImage) {
        Navigator.pushReplacementNamed(context, AppRoutes.imageViewer,
            arguments: cachedArgs);
      } else if (_isVideo) {
        Navigator.pushReplacementNamed(context, AppRoutes.videoPlayer,
            arguments: cachedArgs);
      } else if (_isAudio) {
        Navigator.pushReplacementNamed(context, AppRoutes.musicPlayer,
            arguments: cachedArgs);
      } else if (_isDocument) {
        Navigator.pushReplacementNamed(context, AppRoutes.documentViewer,
            arguments: cachedArgs);
      }
      return;
    }

    // Stream from Telegram
    if (_isImage) {
      Navigator.pushReplacementNamed(context, AppRoutes.imageViewer,
          arguments: fileArgs);
    } else if (_isVideo) {
      Navigator.pushReplacementNamed(context, AppRoutes.videoPlayer,
          arguments: fileArgs);
    } else if (_isAudio) {
      Navigator.pushReplacementNamed(context, AppRoutes.musicPlayer,
          arguments: fileArgs);
    } else if (_isDocument) {
      Navigator.pushReplacementNamed(context, AppRoutes.documentViewer,
          arguments: fileArgs);
    }
    // Unknown type — stay on this page
  }

  @override
  Widget build(BuildContext context) {
    final offlineState = ref.watch(fileOfflineStateProvider(_file.id));
    final color = FileUtils.getFileColor(_file.extension);
    final icon = FileUtils.getFileIcon(_file.extension);
    final isKnownType = _isImage || _isVideo || _isAudio || _isDocument;

    // Transit screen while routing
    if (isKnownType) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: color, size: 64),
            const SizedBox(height: 16),
            const CircularProgressIndicator(),
          ]),
        ),
      );
    }

    // Unknown file type — show info + offline toggle
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
            onPressed: () =>
                ref.read(driveProvider.notifier).toggleStar(_file),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // File icon card
          Center(
            child: Container(
              width: 120, height: 120,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                    color: color.withValues(alpha: 0.3), width: 1.5),
              ),
              child: Icon(icon, color: color, size: 60),
            ),
          ),
          const SizedBox(height: 20),
          Text(_file.name,
              style: AppTheme.titleLarge,
              textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text(FileUtils.getMimeDisplayName(_file.mimeType),
              style: AppTheme.bodyMedium,
              textAlign: TextAlign.center),

          const SizedBox(height: 28),

          // ── Offline toggle card (Spotify style) ────────────────────────────
          _OfflineToggleCard(file: _file, state: offlineState),

          const SizedBox(height: 20),

          // ── Metadata ──────────────────────────────────────────────────────
          _MetaRow(label: 'Size',
              value: FileUtils.formatFileSize(_file.sizeBytes)),
          _MetaRow(label: 'Uploaded',
              value: AppDateUtils.formatDateTime(_file.uploadedAt)),
          if (_file.folderPath != '/')
            _MetaRow(label: 'Location', value: _file.folderPath),

          const SizedBox(height: 28),

          // ── Actions ───────────────────────────────────────────────────────
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
                onTap: () =>
                    ref.read(driveProvider.notifier).toggleStar(_file),
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

  Future<void> _shareFile() async {
    final link =
        await ref.read(driveProvider.notifier).getShareLink(_file);
    if (mounted && link != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Link: $link'),
        action: SnackBarAction(label: 'OK', onPressed: () {}),
      ));
    }
  }
}

// ── Offline toggle card ───────────────────────────────────────────────────────

class _OfflineToggleCard extends ConsumerWidget {
  final CloudFile file;
  final FileOfflineState state;
  const _OfflineToggleCard({required this.file, required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCached = state.status == OfflineStatus.cached;
    final isCaching = state.status == OfflineStatus.caching;
    final isFailed = state.status == OfflineStatus.failed;

    Color cardColor;
    Color borderColor;
    IconData statusIcon;
    String statusLabel;
    String statusSub;

    if (isCached) {
      cardColor = AppTheme.success.withValues(alpha: 0.08);
      borderColor = AppTheme.success.withValues(alpha: 0.3);
      statusIcon = Icons.check_circle_rounded;
      statusLabel = 'Available Offline';
      statusSub = 'Stored in app-private cache · invisible to Files app';
    } else if (isCaching) {
      cardColor = AppTheme.primary.withValues(alpha: 0.08);
      borderColor = AppTheme.primary.withValues(alpha: 0.3);
      statusIcon = Icons.downloading_rounded;
      statusLabel = 'Caching… ${(state.progress * 100).toInt()}%';
      statusSub =
          'Downloading to app cache · Tap toggle to cancel';
    } else if (isFailed) {
      cardColor = AppTheme.error.withValues(alpha: 0.08);
      borderColor = AppTheme.error.withValues(alpha: 0.3);
      statusIcon = Icons.error_outline_rounded;
      statusLabel = 'Cache failed';
      statusSub = state.error ?? 'Tap toggle to retry';
    } else {
      cardColor = AppTheme.card;
      borderColor = AppTheme.cardBorder;
      statusIcon = Icons.cloud_rounded;
      statusLabel = 'Stream only';
      statusSub =
          'Enable to access offline · uses app-private space';
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
                    : isFailed
                        ? AppTheme.error
                        : AppTheme.primary,
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
            ]),
          ),
          // Spotify-style toggle
          GestureDetector(
            onTap: () =>
                ref.read(offlineCacheProvider.notifier).toggle(file),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 52, height: 28,
              decoration: BoxDecoration(
                color: isCached
                    ? AppTheme.success
                    : isCaching
                        ? AppTheme.primary
                        : AppTheme.surfaceVariant,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: isCached
                        ? AppTheme.success
                        : AppTheme.cardBorder),
              ),
              child: Stack(children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 200),
                  left: isCached || isCaching ? 26 : 2,
                  top: 2,
                  child: Container(
                    width: 24, height: 24,
                    decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle),
                    child: isCaching
                        ? const Padding(
                            padding: EdgeInsets.all(4),
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppTheme.primary),
                          )
                        : null,
                  ),
                ),
              ]),
            ),
          ),
        ]),

        // Progress bar during caching
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
            style: const TextStyle(
                color: AppTheme.textSecondary, fontSize: 11),
          ),
        ],
      ]),
    );
  }
}

// ── Helper widgets ────────────────────────────────────────────────────────────

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
            style: AppTheme.bodyMedium
                .copyWith(color: AppTheme.textSecondary)),
        const Spacer(),
        Text(value, style: AppTheme.bodyMedium),
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
      {required this.icon,
      required this.label,
      required this.color,
      required this.onTap});

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
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
