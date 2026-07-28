import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/file_utils.dart';
import '../../../../core/utils/date_utils.dart';
import '../../data/models/cloud_file.dart';

class FileListItem extends StatelessWidget {
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

  bool get _isImage {
    const imageExts = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'avif'};
    return imageExts.contains(file.extension.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    final color = FileUtils.getFileColor(file.extension);
    final icon  = FileUtils.getFileIcon(file.extension);

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primary.withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppTheme.primary.withValues(alpha: 0.5) : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            // ── File Icon / Thumbnail ──────────────────────────────────────
            if (isSelectionMode)
              GestureDetector(
                onTap: onTap,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 52,
                  height: 52,
                  margin: const EdgeInsets.only(right: 14),
                  decoration: BoxDecoration(
                    color: isSelected ? AppTheme.primary : AppTheme.surfaceVariant,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected ? AppTheme.primary : AppTheme.cardBorder,
                    ),
                  ),
                  child: Icon(
                    isSelected ? Icons.check : icon,
                    color: isSelected ? Colors.white : color,
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
            if (!isSelectionMode)
              IconButton(
                icon: const Icon(Icons.more_vert_rounded, color: AppTheme.textHint, size: 20),
                onPressed: onMoreTap,
                splashRadius: 20,
              ),
          ],
        ),
      ),
    );
  }
}
