import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/file_utils.dart';
import '../../data/models/cloud_file.dart';
import '../../data/offline_cache_service.dart';
import '../providers/offline_cache_provider.dart';
import '../providers/drive_provider.dart';

// ── Re-export for home_page _DownloadsTab ─────────────────────────────────────
export '../../data/offline_cache_service.dart' show OfflineStatus;
export '../providers/offline_cache_provider.dart'
    show offlineCacheProvider, fileOfflineStateProvider, FileOfflineState;

// ── Download Manager Page ─────────────────────────────────────────────────────

class DownloadManagerPage extends ConsumerStatefulWidget {
  final Map<String, dynamic>? args;
  const DownloadManagerPage({super.key, this.args});

  @override
  ConsumerState<DownloadManagerPage> createState() =>
      _DownloadManagerPageState();
}

class _DownloadManagerPageState extends ConsumerState<DownloadManagerPage>
    with SingleTickerProviderStateMixin {
  late TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);

    // If a file was passed as arg, trigger cache immediately.
    final file = widget.args?['file'] as CloudFile?;
    if (file != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(offlineCacheProvider.notifier).toggle(file);
      });
    }
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final offlineMap = ref.watch(offlineCacheProvider);
    final caching = offlineMap.values
        .where((s) => s.status == OfflineStatus.caching)
        .length;
    final cached = offlineMap.values
        .where((s) => s.status == OfflineStatus.cached)
        .length;

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
            child: const Icon(Icons.download_for_offline_rounded,
                color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          Text('Offline Cache', style: AppTheme.titleLarge),
        ]),
        actions: [
          if (cached > 0)
            TextButton(
              onPressed: _confirmClearAll,
              child: const Text('Clear all',
                  style: TextStyle(color: AppTheme.error, fontSize: 13)),
            ),
        ],
        bottom: TabBar(
          controller: _tab,
          indicatorColor: AppTheme.primary,
          indicatorWeight: 2,
          labelColor: AppTheme.primary,
          unselectedLabelColor: AppTheme.textHint,
          tabs: [
            Tab(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.cloud_done_rounded, size: 16),
                const SizedBox(width: 6),
                Text('Cached ($cached)'),
              ]),
            ),
            Tab(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.downloading_rounded, size: 16),
                const SizedBox(width: 6),
                Text('Active ($caching)'),
              ]),
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _CachedTab(offlineMap: offlineMap),
          _ActiveTab(offlineMap: offlineMap),
        ],
      ),
    );
  }

  void _confirmClearAll() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Clear all offline files?'),
        content: const Text(
          'All cached files will be removed from your device.\n'
          'They remain safely stored on Telegram.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            onPressed: () {
              Navigator.pop(context);
              ref.read(offlineCacheProvider.notifier).clearAll();
            },
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
  }
}

// ── Cached Tab ────────────────────────────────────────────────────────────────

class _CachedTab extends ConsumerWidget {
  final Map<String, FileOfflineState> offlineMap;
  const _CachedTab({required this.offlineMap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cachedEntries = offlineMap.entries
        .where((e) => e.value.status == OfflineStatus.cached)
        .toList();

    if (cachedEntries.isEmpty) {
      return const _EmptyState(
        icon: Icons.cloud_download_outlined,
        title: 'No offline files',
        subtitle:
            'Tap ☁️ → "Make available offline"\nto access files without internet.',
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _StorageBar(offlineMap: offlineMap),
        const SizedBox(height: 16),
        ...cachedEntries.map((entry) {
          final fileState = entry.value;
        final allFilesAsync = ref.watch(allFilesProvider(
            (starredOnly: false, trashedOnly: false)));
        final allFiles = allFilesAsync.valueOrNull ?? [];
        final file =
            allFiles.where((f) => f.id == entry.key).firstOrNull;
          return _CachedFileTile(
            fileId: entry.key,
            fileName: file?.name ?? 'Unknown file',
            extension: file?.extension ?? '',
            sizeBytes: file?.sizeBytes ?? 0,
            state: fileState,
            localPath: fileState.localPath,
            onOpen: () {
              if (fileState.localPath != null) {
                OpenFilex.open(fileState.localPath!);
              }
            },
            onRemove: () =>
                ref.read(offlineCacheProvider.notifier).remove(entry.key),
          );
        }),
      ],
    );
  }
}

// ── Active Tab ────────────────────────────────────────────────────────────────

class _ActiveTab extends ConsumerWidget {
  final Map<String, FileOfflineState> offlineMap;
  const _ActiveTab({required this.offlineMap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = offlineMap.entries
        .where((e) =>
            e.value.status == OfflineStatus.caching ||
            e.value.status == OfflineStatus.failed)
        .toList();

    if (active.isEmpty) {
      return const _EmptyState(
        icon: Icons.check_circle_outline_rounded,
        title: 'No active downloads',
        subtitle: 'Downloads in progress will appear here.',
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: active.map((entry) {
        final allFilesAsync = ref.watch(
            allFilesProvider((starredOnly: false, trashedOnly: false)));
        final allFiles = allFilesAsync.valueOrNull ?? [];
        final file =
            allFiles.where((f) => f.id == entry.key).firstOrNull;
        return _ActiveDownloadTile(
          fileId: entry.key,
          fileName: file?.name ?? 'Downloading...',
          extension: file?.extension ?? '',
          sizeBytes: file?.sizeBytes ?? 0,
          state: entry.value,
          onCancel: () =>
              ref.read(offlineCacheProvider.notifier).remove(entry.key),
          onRetry: file == null
              ? null
              : () =>
                  ref.read(offlineCacheProvider.notifier).toggle(file),
        );
      }).toList(),
    );
  }
}

// ── Storage bar ───────────────────────────────────────────────────────────────

class _StorageBar extends StatelessWidget {
  final Map<String, FileOfflineState> offlineMap;
  const _StorageBar({required this.offlineMap});

  @override
  Widget build(BuildContext context) {
    final count =
        offlineMap.values.where((s) => s.status == OfflineStatus.cached).length;
    const maxBytes = OfflineCacheService.maxCacheBytes;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1A2040), Color(0xFF1A1535)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.phone_android_rounded,
              color: AppTheme.accent, size: 18),
          const SizedBox(width: 8),
          Text('Offline Cache', style: AppTheme.titleMedium),
          const Spacer(),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
              border:
                  Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
            ),
            child: Text(
              '$count file${count == 1 ? '' : 's'}',
              style: const TextStyle(
                  color: AppTheme.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          const Icon(Icons.cloud_rounded, color: AppTheme.success, size: 14),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Max cache: ${FileUtils.formatFileSize(maxBytes)}  ·  '
              'LRU auto-eviction enabled',
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 11),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        const Row(children: [
          Icon(Icons.visibility_off_rounded,
              color: AppTheme.success, size: 14),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              'Invisible to Files app  ·  Not counted in storage stats',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
            ),
          ),
        ]),
      ]),
    );
  }
}

// ── Cached file tile ──────────────────────────────────────────────────────────

class _CachedFileTile extends StatelessWidget {
  final String fileId;
  final String fileName;
  final String extension;
  final int sizeBytes;
  final FileOfflineState state;
  final String? localPath;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  const _CachedFileTile({
    required this.fileId,
    required this.fileName,
    required this.extension,
    required this.sizeBytes,
    required this.state,
    required this.localPath,
    required this.onOpen,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final color = extension.isEmpty
        ? AppTheme.fileColorDefault
        : FileUtils.getFileColor(extension);
    final icon = extension.isEmpty
        ? Icons.insert_drive_file_rounded
        : FileUtils.getFileIcon(extension);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(children: [
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(fileName,
                style: AppTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 3),
            Row(children: [
              const Icon(Icons.check_circle_rounded,
                  color: AppTheme.success, size: 12),
              const SizedBox(width: 4),
              Text(
                'Available offline  ·  ${FileUtils.formatFileSize(sizeBytes)}',
                style: const TextStyle(
                    color: AppTheme.success,
                    fontSize: 11,
                    fontWeight: FontWeight.w500),
              ),
            ]),
          ]),
        ),
        const SizedBox(width: 8),
        // Open
        _IconBtn(
          icon: Icons.open_in_new_rounded,
          color: AppTheme.primary,
          tooltip: 'Open',
          onTap: onOpen,
        ),
        const SizedBox(width: 4),
        // Remove from cache
        _IconBtn(
          icon: Icons.delete_outline_rounded,
          color: AppTheme.error,
          tooltip: 'Remove offline copy',
          onTap: onRemove,
        ),
      ]),
    );
  }
}

// ── Active download tile ──────────────────────────────────────────────────────

class _ActiveDownloadTile extends StatelessWidget {
  final String fileId;
  final String fileName;
  final String extension;
  final int sizeBytes;
  final FileOfflineState state;
  final VoidCallback onCancel;
  final VoidCallback? onRetry;

  const _ActiveDownloadTile({
    required this.fileId,
    required this.fileName,
    required this.extension,
    required this.sizeBytes,
    required this.state,
    required this.onCancel,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final color = extension.isEmpty
        ? AppTheme.fileColorDefault
        : FileUtils.getFileColor(extension);
    final icon = extension.isEmpty
        ? Icons.insert_drive_file_rounded
        : FileUtils.getFileIcon(extension);

    final isFailed = state.status == OfflineStatus.failed;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: isFailed
                ? AppTheme.error.withValues(alpha: 0.3)
                : AppTheme.cardBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(fileName,
                  style: AppTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 3),
              Text(
                isFailed
                    ? state.error ?? 'Download failed'
                    : '${(state.progress * 100).toInt()}%  ·  ${FileUtils.formatFileSize(sizeBytes)}',
                style: TextStyle(
                    color: isFailed ? AppTheme.error : AppTheme.textSecondary,
                    fontSize: 11),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ]),
          ),
          const SizedBox(width: 8),
          if (isFailed && onRetry != null)
            _IconBtn(
                icon: Icons.refresh_rounded,
                color: AppTheme.warning,
                tooltip: 'Retry',
                onTap: onRetry!),
          const SizedBox(width: 4),
          _IconBtn(
              icon: Icons.close_rounded,
              color: AppTheme.error,
              tooltip: 'Cancel',
              onTap: onCancel),
        ]),

        // Progress bar (caching only)
        if (!isFailed) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: state.progress,
              backgroundColor: AppTheme.surfaceVariant,
              valueColor: const AlwaysStoppedAnimation(AppTheme.primary),
              minHeight: 4,
            ),
          ),
        ],
      ]),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _EmptyState(
      {required this.icon, required this.title, required this.subtitle});

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

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  const _IconBtn(
      {required this.icon,
      required this.color,
      required this.tooltip,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.25)),
          ),
          child: Icon(icon, color: color, size: 18),
        ),
      ),
    );
  }
}
