import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/file_utils.dart';
import '../../data/models/cloud_file.dart';
import '../../data/telegram_storage_service.dart';
import '../providers/drive_provider.dart';
import '../../../auth/data/telegram_auth_service.dart';

/// Full-screen image viewer with swipe navigation.
/// • Receives 'file', 'allFiles' (optional), 'initialIndex' (optional) in args.
/// • Single tap: toggle chrome (app-bar / info bar).
/// • Double tap: zoom 3× at tap point / reset.
/// • Swipe horizontally: navigate to previous/next image in gallery.
/// • Long press / ⋮ button: actions sheet.
class ImageViewerPage extends ConsumerStatefulWidget {
  final Map<String, dynamic> args;
  const ImageViewerPage({super.key, required this.args});

  @override
  ConsumerState<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends ConsumerState<ImageViewerPage>
    with SingleTickerProviderStateMixin {
  late List<CloudFile> _allFiles;
  late PageController _pageController;
  late int _currentIndex;
  CloudFile get _file => _allFiles[_currentIndex];

  // Per-page zoom/transform
  final Map<int, TransformationController> _transformControllers = {};
  late AnimationController _doubleTapController;
  Animation<Matrix4>? _doubleTapAnimation;
  TapDownDetails? _doubleTapDetails;

  bool _barsVisible = true;

  // Per-page load state
  final Map<int, File?> _localFiles = {};
  final Map<int, bool> _loading = {};
  final Map<int, bool> _error = {};

  @override
  void initState() {
    super.initState();
    final args = widget.args;
    _allFiles = (args['allFiles'] as List<CloudFile>?)?.toList()
        ?? [args['file'] as CloudFile];
    _currentIndex = (args['initialIndex'] as int?) ?? 0;
    _pageController = PageController(initialPage: _currentIndex);
    _doubleTapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _loadImage(_currentIndex);
    // Preload adjacent
    if (_currentIndex + 1 < _allFiles.length) _loadImage(_currentIndex + 1);
    if (_currentIndex - 1 >= 0) _loadImage(_currentIndex - 1);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _doubleTapController.dispose();
    for (final c in _transformControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TransformationController _transformFor(int index) {
    return _transformControllers.putIfAbsent(index, () => TransformationController());
  }

  // ── Load image bytes from Telegram ─────────────────────────────────────────

  Future<void> _loadImage(int index) async {
    if (_loading[index] == true || _localFiles.containsKey(index)) return;
    _loading[index] = true;
    if (mounted) setState(() {});
    try {
      final authService = ref.read(telegramAuthServiceProvider);
      final telegramService = TelegramStorageService(authService);
      final f = await telegramService.downloadFile(
          _allFiles[index].telegramMessageId, _allFiles[index].name);
      if (!mounted) return;
      _localFiles[index] = f;
      _loading[index] = false;
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) {
        _loading[index] = false;
        _error[index] = true;
        setState(() {});
      }
    }
  }

  // ── Double-tap zoom ────────────────────────────────────────────────────────

  void _onDoubleTapDown(TapDownDetails details) {
    _doubleTapDetails = details;
  }

  void _onDoubleTap(int index) {
    final ctrl = _transformFor(index);
    final isZoomedOut = ctrl.value.getMaxScaleOnAxis() < 2.0;
    Matrix4 endMatrix;
    if (isZoomedOut) {
      final pos = _doubleTapDetails?.localPosition ?? Offset.zero;
      endMatrix = Matrix4.translationValues(-pos.dx * 2.0, -pos.dy * 2.0, 0.0)
        ..multiply(Matrix4.diagonal3Values(3.0, 3.0, 1.0));
    } else {
      endMatrix = Matrix4.identity();
    }

    _doubleTapAnimation = Matrix4Tween(
      begin: ctrl.value,
      end: endMatrix,
    ).animate(CurvedAnimation(
      parent: _doubleTapController,
      curve: Curves.easeInOut,
    ));

    _doubleTapController.forward(from: 0).then((_) {
      ctrl.value = endMatrix;
    });
    _doubleTapAnimation!.addListener(() {
      ctrl.value = _doubleTapAnimation!.value;
    });
  }

  // ── Long-press → actions bottom sheet ─────────────────────────────────────

  void _showActions() {
    final file = _file;
    final localFile = _localFiles[_currentIndex];
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => _ImageActionsSheet(
        file: file,
        localFile: localFile,
        onSave: _saveToDevice,
        onDelete: () {
          Navigator.pop(context); // close sheet
          _confirmDelete(context, file);
        },
        onStar: () {
          ref.read(driveProvider.notifier).toggleStar(file);
          Navigator.pop(context);
        },
        onShareImage: _shareImageFile,
        onShareLink: () async {
          Navigator.pop(context);
          final link = await ref.read(driveProvider.notifier).getShareLink(file);
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

  void _confirmDelete(BuildContext context, CloudFile file) {
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Delete Image'),
        content: Text('Permanently delete "${file.name}"? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            onPressed: () {
              Navigator.pop(dialogCtx);
              // Remove from local list first for snappy UX
              final deletedIndex = _currentIndex;
              ref.read(driveProvider.notifier).deleteFile(file);
              if (_allFiles.length <= 1) {
                // Last image - exit viewer
                if (mounted) Navigator.pop(context);
              } else {
                // Navigate away from deleted image
                setState(() {
                  _allFiles.removeAt(deletedIndex);
                  _localFiles.remove(deletedIndex);
                  _loading.remove(deletedIndex);
                  _error.remove(deletedIndex);
                  if (_currentIndex >= _allFiles.length) {
                    _currentIndex = _allFiles.length - 1;
                  }
                });
                _pageController.jumpToPage(_currentIndex);
              }
            },
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
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
      final localFile = _localFiles[_currentIndex];
      if (localFile != null) {
        await localFile.copy(dest.path);
      } else {
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

  // ── Share image file to other apps ──────────────────────────────────

  Future<void> _shareImageFile() async {
    Navigator.pop(context); // close actions sheet
    final localFile = _localFiles[_currentIndex];
    if (localFile == null) {
      _showSnack('Image still loading…');
      return;
    }
    try {
      final xFile = XFile(localFile.path, mimeType: _file.mimeType ?? 'image/*');
      await Share.shareXFiles([xFile], text: _file.name);
    } catch (e) {
      _showSnack('Could not share: $e');
    }
  }

  Future<void> _openWithNativeApp() async {
    Navigator.pop(context); // close actions sheet
    final localFile = _localFiles[_currentIndex];
    if (localFile == null) {
      _showSnack('Image still loading…');
      return;
    }
    try {
      final tmpDir = await getTemporaryDirectory();
      final tmpFile = File('${tmpDir.path}/${_file.name}');
      await localFile.copy(tmpFile.path);
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
                IconButton(
                  icon: const Icon(Icons.more_vert_rounded),
                  tooltip: 'More options',
                  onPressed: _showActions,
                ),
              ],
            )
          : null,
      body: PageView.builder(
        controller: _pageController,
        physics: _transformFor(_currentIndex).value.getMaxScaleOnAxis() > 1.1
            ? const NeverScrollableScrollPhysics()
            : const BouncingScrollPhysics(),
        onPageChanged: (index) {
          setState(() => _currentIndex = index);
          // Preload adjacent images
          if (index + 1 < _allFiles.length) _loadImage(index + 1);
          if (index - 1 >= 0) _loadImage(index - 1);
        },
        itemCount: _allFiles.length,
        itemBuilder: (_, index) {
          final isLoading = _loading[index] == true;
          final hasError = _error[index] == true;
          final localFile = _localFiles[index];

          return GestureDetector(
            onTap: () => setState(() => _barsVisible = !_barsVisible),
            onDoubleTapDown: _onDoubleTapDown,
            onDoubleTap: () => _onDoubleTap(index),
            onLongPress: index == _currentIndex ? _showActions : null,
            child: isLoading
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
                : hasError
                    ? _buildError(index)
                    : localFile != null
                        ? InteractiveViewer(
                            transformationController: _transformFor(index),
                            minScale: 0.5,
                            maxScale: 8.0,
                            onInteractionUpdate: (_) => setState(() {}),
                            child: Center(
                              child: Image.file(
                                localFile,
                                fit: BoxFit.contain,
                                filterQuality: FilterQuality.high,
                                errorBuilder: (_, __, ___) => const Icon(
                                  Icons.broken_image_rounded,
                                  color: Colors.white30,
                                  size: 80,
                                ),
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
          );
        },
      ),
      bottomNavigationBar: _barsVisible
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
                  // Page indicator (only shown when multiple images)
                  if (_allFiles.length > 1)
                    Text(
                      '${_currentIndex + 1} / ${_allFiles.length}',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    )
                  else
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

  Widget _buildError(int index) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.broken_image_rounded, color: Colors.white30, size: 80),
        const SizedBox(height: 16),
        const Text('Could not load image',
            style: TextStyle(color: Colors.white60)),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: () {
            setState(() {
              _loading.remove(index);
              _error.remove(index);
              _localFiles.remove(index);
            });
            _loadImage(index);
          },
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Retry'),
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
        ),
      ]),
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
  final VoidCallback onShareImage;
  final VoidCallback onShareLink;
  final VoidCallback onOpenWith;

  const _ImageActionsSheet({
    required this.file,
    required this.localFile,
    required this.onSave,
    required this.onDelete,
    required this.onStar,
    required this.onShareImage,
    required this.onShareLink,
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
              leading: const Icon(Icons.share_rounded, color: AppTheme.accent),
              title: const Text('Share'),
              subtitle: const Text('Send image to other apps',
                  style: TextStyle(fontSize: 11)),
              onTap: onShareImage,
            ),
            ListTile(
              leading: const Icon(Icons.link_rounded, color: AppTheme.textSecondary),
              title: const Text('Share Link'),
              subtitle: const Text('Copy Telegram link',
                  style: TextStyle(fontSize: 11)),
              onTap: onShareLink,
            ),
            ListTile(
              leading: const Icon(Icons.delete_forever_rounded, color: AppTheme.error),
              title: const Text('Delete Permanently',
                  style: TextStyle(color: AppTheme.error)),
              onTap: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
