import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/file_utils.dart';
import '../../data/models/cloud_file.dart';
import '../../data/telegram_storage_service.dart';
import '../providers/drive_provider.dart';
import '../../../auth/data/telegram_auth_service.dart';

/// Document viewer: shows text/code inline, opens PDF/office with system app.
class DocumentViewerPage extends ConsumerStatefulWidget {
  final Map<String, dynamic> args;
  const DocumentViewerPage({super.key, required this.args});

  @override
  ConsumerState<DocumentViewerPage> createState() => _DocumentViewerPageState();
}

class _DocumentViewerPageState extends ConsumerState<DocumentViewerPage> {
  CloudFile get _file => widget.args['file'] as CloudFile;

  File? _localFile;
  bool _loading = true;
  bool _error = false;
  String? _textContent;

  static const _textExtensions = {
    'txt', 'md', 'dart', 'py', 'js', 'ts', 'html', 'css', 'java', 'kt',
    'swift', 'go', 'rs', 'cpp', 'c', 'h', 'json', 'xml', 'yaml', 'yml',
    'sh', 'bat', 'csv', 'log', 'ini', 'toml', 'env',
  };

  bool get _isTextFile =>
      _textExtensions.contains(_file.extension.toLowerCase());

  @override
  void initState() {
    super.initState();
    _loadDocument();
  }

  Future<void> _loadDocument() async {
    try {
      final authService = ref.read(telegramAuthServiceProvider);
      final telegramService = TelegramStorageService(authService);
      final f = await telegramService.downloadFile(_file.telegramMessageId, _file.name);
      if (!mounted) return;

      String? textContent;
      if (_isTextFile) {
        try {
          textContent = await f.readAsString();
        } catch (_) {
          textContent = null;
        }
      }

      setState(() {
        _localFile = f;
        _textContent = textContent;
        _loading = false;
      });

      // Auto-open non-text files with system app
      if (!_isTextFile) {
        await OpenFilex.open(f.path);
      }
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = true; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_file.name, style: AppTheme.titleMedium, overflow: TextOverflow.ellipsis),
            Text(
              '${_file.extension.toUpperCase()} · ${FileUtils.formatFileSize(_file.sizeBytes)}',
              style: AppTheme.bodyMedium,
            ),
          ],
        ),
        actions: [
          if (_localFile != null)
            IconButton(
              icon: const Icon(Icons.open_in_new_rounded),
              tooltip: 'Open with external app',
              onPressed: () => OpenFilex.open(_localFile!.path),
            ),
          IconButton(
            icon: Icon(
              _file.isStarred ? Icons.star_rounded : Icons.star_border_rounded,
              color: AppTheme.warning,
            ),
            onPressed: () => ref.read(driveProvider.notifier).toggleStar(_file),
          ),
        ],
      ),
      body: _loading
          ? _buildLoading()
          : _error
              ? _buildError()
              : _isTextFile && _textContent != null
                  ? _buildTextViewer()
                  : _buildOpenedWithApp(),
    );
  }

  Widget _buildLoading() {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text('Loading document...', style: AppTheme.bodyMedium),
      ]),
    );
  }

  Widget _buildError() {
    final color = FileUtils.getFileColor(_file.extension);
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 80, height: 80,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Icon(FileUtils.getFileIcon(_file.extension), color: color, size: 44),
        ),
        const SizedBox(height: 16),
        Text('Could not load document', style: AppTheme.titleMedium),
        const SizedBox(height: 8),
        Text('Check your connection and try again', style: AppTheme.bodyMedium),
        const SizedBox(height: 20),
        ElevatedButton.icon(
          onPressed: () { setState(() { _loading = true; _error = false; }); _loadDocument(); },
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Retry'),
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
        ),
      ]),
    );
  }

  Widget _buildTextViewer() {
    final content = _textContent!;
    final isCode = _file.extension != 'txt' && _file.extension != 'md' && _file.extension != 'csv';

    return Column(
      children: [
        // Info bar
        Container(
          color: AppTheme.card,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.code_rounded, color: AppTheme.textSecondary, size: 14),
              const SizedBox(width: 6),
              Text(
                '${content.split('\n').length} lines · ${content.length} chars',
                style: AppTheme.bodyMedium,
              ),
              const Spacer(),
              if (isCode)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    _file.extension.toUpperCase(),
                    style: AppTheme.labelLarge.copyWith(color: AppTheme.primary, fontSize: 10),
                  ),
                ),
            ],
          ),
        ),
        // Content
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              content,
              style: isCode
                  ? const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      color: Color(0xFFABB2BF),
                      height: 1.6,
                    )
                  : AppTheme.bodyLarge.copyWith(height: 1.7),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOpenedWithApp() {
    final color = FileUtils.getFileColor(_file.extension);
    final icon = FileUtils.getFileIcon(_file.extension);

    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 100, height: 100,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Icon(icon, color: color, size: 52),
        ),
        const SizedBox(height: 20),
        Text(_file.name, style: AppTheme.titleLarge, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
          'Opened with your device\'s default app',
          style: AppTheme.bodyMedium.copyWith(color: AppTheme.textSecondary),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton.icon(
              onPressed: () => _localFile != null ? OpenFilex.open(_localFile!.path) : null,
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text('Open Again'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () => ref.read(driveProvider.notifier).downloadFile(_file, onProgress: (_) {}),
              icon: const Icon(Icons.download_rounded),
              label: const Text('Save to Device'),
              style: OutlinedButton.styleFrom(foregroundColor: AppTheme.textPrimary),
            ),
          ],
        ),
      ]),
    );
  }
}
