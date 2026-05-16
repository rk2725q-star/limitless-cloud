import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/file_utils.dart';
import '../../../../core/utils/date_utils.dart';
import '../../data/models/cloud_file.dart';
import '../providers/drive_provider.dart';

class FileDetailPage extends ConsumerStatefulWidget {
  final Map<String, dynamic> args;
  const FileDetailPage({super.key, required this.args});

  @override
  ConsumerState<FileDetailPage> createState() => _FileDetailPageState();
}

class _FileDetailPageState extends ConsumerState<FileDetailPage> {
  bool _isDownloading = false;
  double _downloadProgress = 0;

  CloudFile get _file => widget.args['file'] as CloudFile;

  Future<void> _download() async {
    setState(() { _isDownloading = true; _downloadProgress = 0; });
    final path = await ref.read(driveProvider.notifier).downloadFile(
      _file,
      onProgress: (p) => setState(() => _downloadProgress = p),
    );
    setState(() => _isDownloading = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(path != null ? 'Downloaded to $path' : 'Download failed')),
      );
    }
  }

  Future<void> _share() async {
    final link = await ref.read(driveProvider.notifier).getShareLink(_file);
    if (mounted && link != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Link: $link'), action: SnackBarAction(label: 'Copy', onPressed: () {})),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = FileUtils.getFileColor(_file.extension);
    final icon = FileUtils.getFileIcon(_file.extension);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: Text(_file.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: Icon(_file.isStarred ? Icons.star_rounded : Icons.star_border_rounded, color: AppTheme.warning),
            onPressed: () => ref.read(driveProvider.notifier).toggleStar(_file),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // File Icon
            Center(
              child: Container(
                width: 100, height: 100,
                decoration: BoxDecoration(
                  color: color.withValues(alpha:0.12),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: color.withValues(alpha:0.3)),
                ),
                child: Icon(icon, color: color, size: 52),
              ),
            ),
            const SizedBox(height: 20),
            Center(child: Text(_file.name, style: AppTheme.titleLarge, textAlign: TextAlign.center)),
            Center(child: Text(FileUtils.getMimeDisplayName(_file.mimeType), style: AppTheme.bodyMedium)),
            const SizedBox(height: 32),

            // Action Buttons
            Row(
              children: [
                Expanded(child: _ActionBtn(icon: Icons.download_rounded, label: 'Download', color: AppTheme.primary, onTap: _download)),
                const SizedBox(width: 12),
                Expanded(child: _ActionBtn(icon: Icons.share_rounded, label: 'Share', color: AppTheme.accent, onTap: _share)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _ActionBtn(icon: Icons.drive_file_move_rounded, label: 'Move', color: AppTheme.secondary, onTap: () {})),
                const SizedBox(width: 12),
                Expanded(child: _ActionBtn(icon: Icons.copy_rounded, label: 'Copy', color: AppTheme.info, onTap: () {})),
              ],
            ),

            if (_isDownloading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: _downloadProgress,
                backgroundColor: AppTheme.surfaceVariant,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 4),
              Text('Downloading... ${(_downloadProgress * 100).toInt()}%', style: AppTheme.labelLarge),
            ],

            const SizedBox(height: 24),
            Text('File Details', style: AppTheme.titleMedium),
            const SizedBox(height: 12),
            _DetailRow(label: 'Size', value: FileUtils.formatFileSize(_file.sizeBytes)),
            _DetailRow(label: 'Type', value: _file.extension.toUpperCase()),
            _DetailRow(label: 'Location', value: _file.folderPath),
            _DetailRow(label: 'Uploaded', value: AppDateUtils.formatDateTime(_file.uploadedAt)),
            _DetailRow(label: 'Modified', value: AppDateUtils.formatDateTime(_file.updatedAt)),
            _DetailRow(label: 'Telegram ID', value: '${_file.telegramMessageId}'),

            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  ref.read(driveProvider.notifier).trashFile(_file);
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.delete_outline_rounded, color: AppTheme.error),
                label: const Text('Move to Trash', style: TextStyle(color: AppTheme.error)),
                style: OutlinedButton.styleFrom(side: const BorderSide(color: AppTheme.error)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionBtn({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha:0.1),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha:0.25)),
        ),
        child: Column(children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 4),
          Text(label, style: AppTheme.labelLarge.copyWith(color: color)),
        ]),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(width: 100, child: Text(label, style: AppTheme.bodyMedium)),
          Expanded(child: Text(value, style: AppTheme.bodyLarge.copyWith(fontWeight: FontWeight.w500))),
        ],
      ),
    );
  }
}
