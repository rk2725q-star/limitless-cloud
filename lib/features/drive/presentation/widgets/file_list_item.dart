import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/file_utils.dart';
import '../../../../core/utils/date_utils.dart';
import '../../data/models/cloud_file.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/services/tdlib_service.dart';
import '../../data/firestore_metadata_service.dart';
import '../../../auth/data/telegram_auth_service.dart';

class FileListItem extends ConsumerStatefulWidget {
  final CloudFile file;
  final bool isSelected;
  final bool isSelectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onMoreTap;

  const FileListItem({
    super.key,
    required this.file,
    required this.onTap,
    required this.onLongPress,
    required this.onMoreTap,
    this.isSelected = false,
    this.isSelectionMode = false,
  });

  @override
  ConsumerState<FileListItem> createState() => _FileListItemState();
}

class _FileListItemState extends ConsumerState<FileListItem> {
  bool _isLoadingThumbnail = false;

  bool get _isImage {
    const imageExts = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'avif'};
    return imageExts.contains(widget.file.extension.toLowerCase());
  }

  @override
  void initState() {
    super.initState();
    _checkThumbnail();
  }

  @override
  void didUpdateWidget(FileListItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.id != widget.file.id || oldWidget.file.thumbnailPath != widget.file.thumbnailPath) {
      _checkThumbnail();
    }
  }

  void _checkThumbnail() {
    final file = widget.file;
    if (_isImage && (file.thumbnailPath == null || file.thumbnailPath!.isEmpty) && file.telegramThumbnailId != null) {
      _loadThumbnail(file.telegramThumbnailId!);
    }
  }

  Future<void> _loadThumbnail(int thumbnailId) async {
    if (_isLoadingThumbnail) return;
    setState(() => _isLoadingThumbnail = true);
    
    try {
      final firestoreService = ref.read(firestoreServiceProvider);
      
      final localPath = await TdlibService.instance.downloadThumbnail(thumbnailId);
      if (localPath != null && localPath.isNotEmpty && mounted) {
        final authService = ref.read(telegramAuthServiceProvider);
        final profile = await authService.getProfile();
        final userId = profile['userId'];
        if (userId != null && userId.isNotEmpty) {
          await firestoreService.updateThumbnailPath(widget.file.id, localPath);
        }
      }
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() => _isLoadingThumbnail = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.file;
    final color = FileUtils.getFileColor(file.extension);
    final icon  = FileUtils.getFileIcon(file.extension);

    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: widget.isSelected
              ? AppTheme.primary.withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: widget.isSelected ? AppTheme.primary.withValues(alpha: 0.5) : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            // ── File Icon / Thumbnail ──────────────────────────────────────
            if (widget.isSelectionMode)
              GestureDetector(
                onTap: widget.onTap,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 52,
                  height: 52,
                  margin: const EdgeInsets.only(right: 14),
                  decoration: BoxDecoration(
                    color: widget.isSelected ? AppTheme.primary : AppTheme.surfaceVariant,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: widget.isSelected ? AppTheme.primary : AppTheme.cardBorder,
                    ),
                  ),
                  child: Icon(
                    widget.isSelected ? Icons.check : icon,
                    color: widget.isSelected ? Colors.white : color,
                    size: 22,
                  ),
                ),
              )
            else
              Container(
                width: 52,
                height: 52,
                margin: const EdgeInsets.only(right: 14),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                clipBehavior: Clip.antiAlias,
                child: _isImage && file.thumbnailPath != null && file.thumbnailPath!.isNotEmpty
                    ? (file.thumbnailPath!.startsWith('http')
                        ? CachedNetworkImage(
                            imageUrl: file.thumbnailPath!,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => Icon(icon, color: color, size: 22),
                            errorWidget: (_, __, ___) => Icon(icon, color: color, size: 22),
                          )
                        : Image.file(
                            io.File(file.thumbnailPath!),
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Icon(icon, color: color, size: 22),
                          ))
                    : _isImage && _isLoadingThumbnail
                        ? SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(color),
                            ),
                          )
                        : Icon(icon, color: color, size: 22),
              ),

            // ── File Details ───────────────────────────────────────────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          file.name,
                          style: AppTheme.bodyLarge.copyWith(fontWeight: FontWeight.w500),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (file.isStarred)
                        const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: Icon(Icons.star_rounded, color: AppTheme.warning, size: 14),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Text(FileUtils.formatFileSize(file.sizeBytes), style: AppTheme.bodyMedium),
                      const Text(' · ', style: TextStyle(color: AppTheme.textHint)),
                      Text(AppDateUtils.getRelativeTime(file.uploadedAt), style: AppTheme.bodyMedium),
                    ],
                  ),
                ],
              ),
            ),

            // ── More Button ────────────────────────────────────────────────
            if (!widget.isSelectionMode)
              IconButton(
                icon: const Icon(Icons.more_vert_rounded, color: AppTheme.textHint, size: 20),
                onPressed: widget.onMoreTap,
                splashRadius: 20,
              ),
          ],
        ),
      ),
    );
  }
}
