import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/file_utils.dart';
import '../../data/models/cloud_file.dart';
import '../../data/telegram_storage_service.dart';
import '../providers/drive_provider.dart';
import '../../../auth/data/telegram_auth_service.dart';

/// Full-screen image viewer with pinch-to-zoom, double-tap zoom, and swipe-down-to-close.
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

  Future<void> _loadImage() async {
    try {
      final authService = ref.read(telegramAuthServiceProvider);
      final telegramService = TelegramStorageService(authService);
      final f = await telegramService.downloadFile(_file.telegramMessageId, _file.name);
      if (!mounted) return;
      setState(() { _localFile = f; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = true; });
    }
  }

  void _onDoubleTapDown(TapDownDetails details) {
    _doubleTapDetails = details;
  }

  void _onDoubleTap() {
    final isZoomedOut = _transformController.value.getMaxScaleOnAxis() < 2.0;

    Matrix4 endMatrix;
    if (isZoomedOut) {
      // Zoom in to 3x at the tap position
      final position = _doubleTapDetails?.localPosition ?? Offset.zero;
      endMatrix = Matrix4.translationValues(
              -position.dx * 2.0, -position.dy * 2.0, 0.0)
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _barsVisible
          ? AppBar(
              backgroundColor: Colors.black54,
              foregroundColor: Colors.white,
              title: Text(_file.name, style: const TextStyle(fontSize: 14), overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  icon: Icon(
                    _file.isStarred ? Icons.star_rounded : Icons.star_border_rounded,
                    color: AppTheme.warning,
                  ),
                  onPressed: () => ref.read(driveProvider.notifier).toggleStar(_file),
                ),
                IconButton(
                  icon: const Icon(Icons.download_rounded),
                  onPressed: () => ref.read(driveProvider.notifier).downloadFile(_file, onProgress: (_) {}),
                ),
              ],
            )
          : null,
      body: GestureDetector(
        onTap: () => setState(() => _barsVisible = !_barsVisible),
        onDoubleTapDown: _onDoubleTapDown,
        onDoubleTap: _onDoubleTap,
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: Colors.white))
            : _error
                ? _buildError()
                : _buildImageViewer(),
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
                      '${_file.extension.toUpperCase()} · ${FileUtils.formatFileSize(_file.sizeBytes)}',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ]),
                  Text(
                    'Pinch to zoom · Double-tap to fit',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 11),
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
        const Text('Could not load image', style: TextStyle(color: Colors.white60)),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: () { setState(() { _loading = true; _error = false; }); _loadImage(); },
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
