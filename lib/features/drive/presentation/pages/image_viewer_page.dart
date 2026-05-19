import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/file_utils.dart';
import '../../data/models/cloud_file.dart';
import '../../data/telegram_storage_service.dart';
import '../providers/drive_provider.dart';
import '../../../auth/data/telegram_auth_service.dart';

/// Full-screen image viewer.
/// • Single tap: toggle chrome (app-bar / info bar).
/// • Double tap: zoom 3× at tap point / reset.
/// • Long press: actions sheet (Save, Star, Share, Delete).
class ImageViewerPage extends ConsumerStatefulWidget {
  final Map<String, dynamic> args;
  const ImageViewerPage({super.key, required this.args});

  @override
  ConsumerState<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends ConsumerState<ImageViewerPage>
    with SingleTickerProviderStateMixin {
  CloudFile get _file => widget.args['file'] as CloudFile;

  File? _localFile;
  bool _loading = true;
  bool _error = false;
  bool _barsVisible = true;

  late TransformationController _transformController;
  late AnimationController _doubleTapController;
  Animation<Matrix4>? _doubleTapAnimation;
  TapDownDetails? _doubleTapDetails;

  @override
  void initState() {
    super.initState();
    _transformController = TransformationController();
    _doubleTapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _loadImage();
  }

  @override
  void dispose() {
    _transformController.dispose();
    _doubleTapController.dispose();
    super.dispose();
  }

  // ── Load image bytes from Telegram ─────────────────────────────────────────

  Future<void> _loadImage() async {
    try {
      final authService = ref.read(telegramAuthServiceProvider);
      final telegramService = TelegramStorageService(authService);
      final f = await telegramService.downloadFile(
          _file.telegramMessageId, _file.name);
      if (!mounted) return;
      setState(() {
        _localFile = f;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = true; });
    }
  }

  // ── Double-tap zoom ────────────────────────────────────────────────────────

  void _onDoubleTapDown(TapDownDetails details) {
    _doubleTapDetails = details;
  }

  void _onDoubleTap() {
    final isZoomedOut = _transformController.value.getMaxScaleOnAxis() < 2.0;
    Matrix4 endMatrix;
    if (isZoomedOut) {
      final pos = _doubleTapDetails?.localPosition ?? Offset.zero;
      endMatrix = Matrix4.translationValues(-pos.dx * 2.0, -pos.dy * 2.0, 0.0)
        ..multiply(Matrix4.diagonal3Values(3.0, 3.0, 1.0));
    } else {
      endMatrix = Matrix4.identity();
    }

    _doubleTapAnimation = Matrix4Tween(
      begin: _transformController.value,
      end: endMatrix,
    ).animate(CurvedAnimation(
      parent: _doubleTapController,
      curve: Curves.easeInOut,
    ));

    _doubleTapController.forward(from: 0).then((_) {
      _transformController.value = endMatrix;
    });
    _doubleTapAnimation!.addListener(() {
      _transformController.value = _doubleTapAnimation!.value;
    });
  }

  // ── Long-press → actions bottom sheet ─────────────────────────────────────

  void _showActions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => _ImageActionsSheet(
        file: _file,
        localFile: _localFile,
        onSave: _saveToDevice,
        onDelete: () {
          ref.read(driveProvider.notifier).trashFile(_file);
          Navigator.pop(context); // close sheet
          Navigator.pop(context); // exit viewer
        },
        onStar: () {
          ref.read(driveProvider.notifier).toggleStar(_file);
          Navigator.pop(context);
        },
        onShare: () async {
          Navigator.pop(context);
          final link = await ref.read(driveProvider.notifier).getShareLink(_file);
          if (mounted && link != null) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Link: $link'),
              action: SnackBarAction(label: 'OK', onPressed: () {}),
            ));
          }
        },
        onOpenWith: _openWithNativeApp,
      ),
    );
  }

  // ── Save to device ────────────────────────────────────────────────────────

  Future<void> _saveToDevice() async {
    Navigator.pop(context); // close actions sheet
    try {
      if (Platform.isAndroid) {
        final sdk = await _androidSdk();
        if (sdk < 33) {
          final status = await Permission.storage.request();
          if (!status.isGranted) {
            _showSnack('Storage permission denied');
            return;
          }
        }
      }
      final dir = await _publicDownloadsDir();
      final dest = File('${dir.path}/${_file.name}');

      if (_localFile != null) {
        await _localFile!.copy(dest.path);
      } else {
        // Download first
        final authService = ref.read(telegramAuthServiceProvider);
        final tg = TelegramStorageService(authService);
        final downloaded = await tg.downloadFile(_file.telegramMessageId, _file.name);
        await downloaded.copy(dest.path);
      }
      _showSnack('Saved to Downloads/LimitlessCloud ✓');
    } catch (e) {
      _showSnack('Save failed: $e');
    }
  }

  Future<void> _openWithNativeApp() async {
    Navigator.pop(context); // close actions sheet
    if (_localFile == null) {
      _showSnack('Image still loading…');
      return;
    }
    try {
      final tmpDir = await getTemporaryDirectory();
      final tmpFile = File('${tmpDir.path}/${_file.name}');
      await _localFile!.copy(tmpFile.path);
      final result = await OpenFilex.open(tmpFile.path, type: _file.mimeType);
      if (result.type == ResultType.noAppToOpen) {
        _showSnack('No app found to open .${_file.extension}');
      } else if (result.type == ResultType.error ||
                 result.type == ResultType.permissionDenied) {
        _showSnack(result.message);
      }
    } catch (e) {
      _showSnack('Could not open: $e');
    }
  }

  Future<Directory> _publicDownloadsDir() async {
    if (Platform.isAndroid) {
      final d = Directory('/storage/emulated/0/Download/LimitlessCloud');
      if (!await d.exists()) await d.create(recursive: true);
      return d;
    }
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/Downloads');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<int> _androidSdk() async {
    try {
      final r = await Process.run('getprop', ['ro.build.version.sdk']);
      return int.tryParse(r.stdout.toString().trim()) ?? 30;
    } catch (_) { return 30; }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _barsVisible
          ? AppBar(
              backgroundColor: Colors.black54,
              foregroundColor: Colors.white,
              title: Text(
                _file.name,
                style: const TextStyle(fontSize: 14),
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                // Three-dot hint for discoverability
                IconButton(
                  icon: const Icon(Icons.more_vert_rounded),
                  tooltip: 'More options',
                  onPressed: _showActions,
                ),
              ],
            )
          : null,
      body: GestureDetector(
        onTap: () => setState(() => _barsVisible = !_barsVisible),
        onDoubleTapDown: _onDoubleTapDown,
        onDoubleTap: _onDoubleTap,
        onLongPress: _showActions,
        child: _loading
            ? const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text('Loading image…',
                        style: TextStyle(color: Colors.white54, fontSize: 13)),
                  ],
                ),
              )
            : _error
                ? _buildError()
                : _buildImageViewer(),
      ),
      bottomNavigationBar: _barsVisible && !_loading && !_error
          ? Container(
              color: Colors.black87,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(children: [
                    const Icon(Icons.image_rounded, color: Colors.white54, size: 16),
                    const SizedBox(width: 8),
                    Text(
                      '${_file.extension.toUpperCase()} · '
                      '${FileUtils.formatFileSize(_file.sizeBytes)}',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ]),
                  Text(
                    'Long press for options',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.3), fontSize: 11),
                  ),
                ],
              ),
            )
          : null,
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.broken_image_rounded, color: Colors.white30, size: 80),
        const SizedBox(height: 16),
        const Text('Could not load image',
            style: TextStyle(color: Colors.white60)),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: () {
            setState(() { _loading = true; _error = false; });
            _loadImage();
          },
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Retry'),
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
        ),
      ]),
    );
  }

  Widget _buildImageViewer() {
    return InteractiveViewer(
      transformationController: _transformController,
      minScale: 0.5,
      maxScale: 8.0,
      child: Center(
        child: Image.file(
          _localFile!,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
          errorBuilder: (_, __, ___) => const Icon(
            Icons.broken_image_rounded,
            color: Colors.white30,
            size: 80,
          ),
        ),
      ),
    );
  }
}

// ── Actions Bottom Sheet ──────────────────────────────────────────────────────

class _ImageActionsSheet extends StatelessWidget {
  final CloudFile file;
  final File? localFile;
  final VoidCallback onSave;
  final VoidCallback onDelete;
  final VoidCallback onStar;
  final VoidCallback onShare;
  final VoidCallback onOpenWith;

  const _ImageActionsSheet({
    required this.file,
    required this.localFile,
    required this.onSave,
    required this.onDelete,
    required this.onStar,
    required this.onShare,
    required this.onOpenWith,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                  color: AppTheme.cardBorder,
                  borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 8),
            // File name header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                const Icon(Icons.image_rounded, color: AppTheme.primary, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    file.name,
                    style: AppTheme.bodyMedium.copyWith(
                        fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ]),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.save_alt_rounded, color: AppTheme.accent),
              title: const Text('Save to Device'),
              subtitle: const Text('Save to Downloads/LimitlessCloud',
                  style: TextStyle(fontSize: 11)),
              onTap: onSave,
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new_rounded, color: AppTheme.primary),
              title: const Text('Open with…'),
              subtitle: const Text('Choose an app to view this image',
                  style: TextStyle(fontSize: 11)),
              onTap: onOpenWith,
            ),
            ListTile(
              leading: Icon(
                file.isStarred ? Icons.star_rounded : Icons.star_border_rounded,
                color: AppTheme.warning,
              ),
              title: Text(file.isStarred ? 'Remove Star' : 'Star'),
              onTap: onStar,
            ),
            ListTile(
              leading: const Icon(Icons.share_rounded, color: AppTheme.textSecondary),
              title: const Text('Share Link'),
              onTap: onShare,
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded, color: AppTheme.error),
              title: const Text('Move to Trash',
                  style: TextStyle(color: AppTheme.error)),
              onTap: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
