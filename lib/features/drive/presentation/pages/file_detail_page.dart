import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/file_utils.dart';
import '../../../../core/utils/date_utils.dart';
import '../../data/models/cloud_file.dart';
import '../../data/models/cloud_folder.dart';
import '../../data/telegram_storage_service.dart';
import '../../../auth/data/telegram_auth_service.dart';
import '../providers/drive_provider.dart';
import './download_manager_page.dart';
import './home_page.dart' show homeNavIndexProvider;

/// File detail page.
/// ▶ Open   → streams to temp dir → native "Open With" chooser (zero permanent storage)
/// ⬇ Save   → streams to Downloads/LimitlessCloud → visible in Gallery & Files app
class FileDetailPage extends ConsumerStatefulWidget {
  final Map<String, dynamic> args;
  const FileDetailPage({super.key, required this.args});

  @override
  ConsumerState<FileDetailPage> createState() => _FileDetailPageState();
}

class _FileDetailPageState extends ConsumerState<FileDetailPage> {
  CloudFile get _file => widget.args['file'] as CloudFile;

  bool _opening  = false;
  String? _openError;

  // ── Temp stream → native app (zero permanent storage) ─────────────────────

  Future<void> _openWithNativeApp() async {
    setState(() { _opening = true; _openError = null; });
    try {
      final auth = ref.read(telegramAuthServiceProvider);
      final tg   = TelegramStorageService(auth);

      final tmpDir  = await getTemporaryDirectory();
      final tmpFile = File('${tmpDir.path}/${_file.name}');

      // Stream from Telegram to temp (temp is cleared by OS)
      final downloaded = await tg.downloadFile(_file.telegramMessageId, _file.name);
      await downloaded.copy(tmpFile.path);

      final result = await OpenFilex.open(tmpFile.path, type: _file.mimeType);

      if (result.type == ResultType.noAppToOpen) {
        setState(() => _openError =
            'No app found for .${_file.extension}\nInstall a compatible app and try again.');
      } else if (result.type == ResultType.error ||
                 result.type == ResultType.permissionDenied) {
        setState(() => _openError = result.message);
      }
    } catch (e) {
      setState(() => _openError = 'Could not open: $e');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  // ── Save to public Downloads/LimitlessCloud via Download Manager ──────────

  Future<void> _saveToDevice() async {
    // Kick off download through the Download Manager (shows progress in DL tab)
    final auth = ref.read(telegramAuthServiceProvider);
    final tg   = TelegramStorageService(auth);
    ref.read(dlManagerProvider.notifier).downloadCloudFile(_file, tg);

    if (!mounted) return;

    // Show a brief snackbar with a "View" button
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [
          const Icon(Icons.download_rounded, color: Colors.white, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Downloading ${_file.name}…',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
        backgroundColor: AppTheme.primary,
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'View',
          textColor: Colors.white,
          onPressed: () {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            ref.read(homeNavIndexProvider.notifier).state = 3;
            Navigator.of(context).popUntil((r) => r.isFirst);
          },
        ),
      ),
    );
  }

  // ── Share ─────────────────────────────────────────────────────────────────

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
            icon: Icon(_file.isStarred
                ? Icons.star_rounded : Icons.star_border_rounded,
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
          Text(_file.name, style: AppTheme.titleLarge, textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text(FileUtils.getMimeDisplayName(_file.mimeType),
              style: AppTheme.bodyMedium, textAlign: TextAlign.center),
          const SizedBox(height: 28),

          // ── Primary action buttons ─────────────────────────────────────────
          _ActionButtons(
            isOpening: _opening,
            openError: _openError,
            fileExt: _file.extension,
            onOpen: _openWithNativeApp,
            onSave: _saveToDevice,
          ),

          const SizedBox(height: 24),

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

          // ── Secondary actions ───────────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _Chip(icon: Icons.share_rounded, label: 'Share',
                  color: AppTheme.accent, onTap: _shareFile),
              _Chip(
                icon: _file.isStarred
                    ? Icons.star_rounded : Icons.star_border_rounded,
                label: _file.isStarred ? 'Unstar' : 'Star',
                color: AppTheme.warning,
                onTap: () => ref.read(driveProvider.notifier).toggleStar(_file),
              ),
              _Chip(
                icon: Icons.drive_file_move_rounded,
                label: 'Move',
                color: AppTheme.secondary,
                onTap: () => _showFolderPicker(mode: 'move'),
              ),
              _Chip(
                icon: Icons.copy_rounded,
                label: 'Copy',
                color: AppTheme.accent,
                onTap: () => _showFolderPicker(mode: 'copy'),
              ),
              _Chip(icon: Icons.delete_forever_rounded, label: 'Delete',
                  color: AppTheme.error, onTap: _confirmDelete),
            ],
          ),
        ],
      ),
    );
  }

  void _confirmDelete() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Delete File'),
        content: Text('Permanently delete "${_file.name}"? This will remove it from Telegram and cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            onPressed: () async {
              Navigator.pop(context);
              await ref.read(driveProvider.notifier).deleteFile(_file);
              if (mounted) Navigator.pop(context);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showFolderPicker({required String mode}) {
    final foldersAsync = ref.read(foldersProvider(null));
    final allFolders = foldersAsync.valueOrNull ?? [];
    final isMove = mode == 'move';

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Row(
          children: [
            Icon(isMove ? Icons.drive_file_move_rounded : Icons.copy_rounded,
                color: isMove ? AppTheme.secondary : AppTheme.accent, size: 22),
            const SizedBox(width: 10),
            Text(isMove ? 'Move to Folder' : 'Copy to Folder'),
          ],
        ),
        contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: ListView.builder(
            itemCount: allFolders.length + 1,
            itemBuilder: (_, i) {
              final isRoot = i == 0;
              final f = isRoot
                  ? CloudFolder(
                      id: '__root__', name: 'My Drive (Root)',
                      parentFolderId: null, path: '/', color: '#4F8CFF',
                      metaMessageId: 0, createdAt: DateTime.now(), updatedAt: DateTime.now())
                  : allFolders[i - 1];
              final isCurrent = f.id == (_file.folderId ?? '__root__');
              return ListTile(
                leading: Icon(
                  isRoot ? Icons.cloud_rounded : Icons.folder_rounded,
                  color: isCurrent ? AppTheme.textHint : const Color(0xFF4F8CFF),
                ),
                title: Text(f.name, style: TextStyle(
                    color: isCurrent ? AppTheme.textHint : AppTheme.textPrimary,
                    fontWeight: isCurrent ? FontWeight.normal : FontWeight.w500)),
                subtitle: isCurrent ? const Text('Current location', style: TextStyle(fontSize: 11)) : null,
                trailing: isCurrent ? null : Icon(
                  isMove ? Icons.drive_file_move_rounded : Icons.copy_rounded,
                  color: isMove ? AppTheme.secondary : AppTheme.accent, size: 18,
                ),
                enabled: !isCurrent,
                onTap: isCurrent ? null : () async {
                  Navigator.pop(context);
                  final destId = f.id == '__root__' ? null : f.id;
                  final destPath = f.id == '__root__' ? '/' : f.path;
                  final dest = CloudFolder(
                    id: destId ?? '', name: f.name,
                    parentFolderId: f.parentFolderId, path: destPath,
                    color: f.color, metaMessageId: f.metaMessageId,
                    createdAt: f.createdAt, updatedAt: f.updatedAt,
                  );
                  if (mode == 'move') {
                    await ref.read(driveProvider.notifier).moveFile(_file, dest);
                  } else {
                    await ref.read(driveProvider.notifier).copyFile(_file, dest);
                  }
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(mode == 'move' ? 'Moved to ${f.name}' : 'Copied to ${f.name}'),
                      backgroundColor: mode == 'move' ? AppTheme.secondary : AppTheme.accent,
                    ));
                    if (mode == 'move') Navigator.pop(context);
                  }
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ],
      ),
    );
  }
}

// ── Action Buttons (Open + Save) ──────────────────────────────────────────────

class _ActionButtons extends StatelessWidget {
  final bool isOpening;
  final String? openError, fileExt;
  final VoidCallback onOpen, onSave;

  const _ActionButtons({
    required this.isOpening,
    required this.openError,
    required this.fileExt,
    required this.onOpen, required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // ── Open button ─────────────────────────────────────────────────────────
      SizedBox(
        height: 52,
        child: ElevatedButton.icon(
          onPressed: isOpening ? null : onOpen,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primary,
            disabledBackgroundColor: AppTheme.primary.withValues(alpha: 0.4),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          icon: isOpening
              ? const SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : const Icon(Icons.play_circle_rounded, color: Colors.white),
          label: Text(isOpening ? 'Streaming\u2026' : 'Open  (stream, zero storage)',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        ),
      ),

      if (openError != null) ...[
        const SizedBox(height: 8),
        _ErrorBanner(openError!),
      ],

      const SizedBox(height: 10),

      // ── Save to device button (queues in Download Manager) ───────────────────
      SizedBox(
        height: 52,
        child: ElevatedButton.icon(
          onPressed: onSave,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.accent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          icon: const Icon(Icons.download_rounded, color: Colors.white),
          label: const Text(
            'Save to Device (Gallery / Files)',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
        ),
      ),

      const SizedBox(height: 6),
      Text(
        '"Open" streams the file and opens it in your ${_appHint(fileExt ?? '')}\n'
        '"Save" downloads it to your device via the Download Manager.',
        style: const TextStyle(color: AppTheme.textHint, fontSize: 11, height: 1.5),
        textAlign: TextAlign.center,
      ),
    ]);
  }

  static String _appHint(String ext) {
    final e = ext.toLowerCase();
    if (['jpg','jpeg','png','gif','webp','bmp','heic'].contains(e)) return 'Gallery';
    if (['mp4','mkv','avi','mov','wmv','flv','webm'].contains(e))   return 'Video Player';
    if (['mp3','wav','aac','flac','ogg','m4a','opus'].contains(e))  return 'Music Player';
    if (['pdf','doc','docx','xls','xlsx','ppt','pptx'].contains(e)) return 'Document Viewer';
    return 'default app';
  }
}


class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner(this.message);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: AppTheme.error.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppTheme.error.withValues(alpha: 0.3)),
    ),
    child: Row(children: [
      const Icon(Icons.warning_amber_rounded, color: AppTheme.error, size: 16),
      const SizedBox(width: 8),
      Expanded(child: Text(message,
          style: const TextStyle(color: AppTheme.error, fontSize: 12))),
    ]),
  );
}

// ── Helpers ───────────────────────────────────────────────────────────────────

class _MetaRow extends StatelessWidget {
  final String label, value;
  const _MetaRow({required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: BoxDecoration(
      color: AppTheme.card,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppTheme.cardBorder),
    ),
    child: Row(children: [
      Text(label, style: AppTheme.bodyMedium.copyWith(color: AppTheme.textSecondary)),
      const Spacer(),
      Flexible(child: Text(value, style: AppTheme.bodyMedium,
          overflow: TextOverflow.ellipsis)),
    ]),
  );
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _Chip({required this.icon, required this.label,
      required this.color, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
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
      Text(label, style: TextStyle(
          color: color, fontSize: 11, fontWeight: FontWeight.w600)),
    ]),
  );
}
