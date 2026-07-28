import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/file_utils.dart';
import '../../data/models/cloud_file.dart';

class FileGridItem extends StatelessWidget {
  final CloudFile file;
  final bool isSelected;
  final bool isSelectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  /// Authenticated session string — pass it so thumbnails can load via backend.
  final String? sessionString;

  const FileGridItem({
    super.key,
    required this.file,
    required this.onTap,
    required this.onLongPress,
    this.isSelected = false,
    this.isSelectionMode = false,
    this.sessionString,
  });

  // In serverless mode, thumbnails are not streamed — all files show a type icon.
  // (No backend server URL to stream from; user can preview via the file detail page.)

  @override
  Widget build(BuildContext context) {
    final color = FileUtils.getFileColor(file.extension);
    final icon  = FileUtils.getFileIcon(file.extension);
    final bool isImage = ['jpg', 'jpeg', 'png', 'gif', 'webp'].contains(file.extension.toLowerCase());

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primary.withValues(alpha: 0.15)
              : AppTheme.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? AppTheme.primary : AppTheme.cardBorder,
            width: isSelected ? 1.5 : 1,
          ),
          boxShadow: isSelected
              ? [BoxShadow(color: AppTheme.primary.withValues(alpha: 0.15), blurRadius: 8)]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Thumbnail / Icon Area ──────────────────────────────────────
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // ── Image preview OR file-type icon ───────────────────
                  isImage && file.thumbnailPath != null && file.thumbnailPath!.isNotEmpty
                      ? Container(
                          decoration: const BoxDecoration(
                            borderRadius: BorderRadius.vertical(top: Radius.circular(15)),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: file.thumbnailPath!.startsWith('http')
                              ? CachedNetworkImage(
                                  imageUrl: file.thumbnailPath!,
                                  fit: BoxFit.cover,
                                  placeholder: (_, __) => _IconBackground(color: color, icon: icon),
                                  errorWidget: (_, __, ___) => _IconBackground(color: color, icon: icon),
                                )
                              : Image.file(
                                  io.File(file.thumbnailPath!),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => _IconBackground(color: color, icon: icon),
                                ),
                        )
                      : _IconBackground(color: color, icon: icon),

                  // Star indicator
                  if (file.isStarred)
                    const Positioned(
                      top: 8, right: 8,
                      child: Icon(Icons.star_rounded, color: AppTheme.warning, size: 16),
                    ),

                  // Selection checkbox
                  if (isSelectionMode)
                    Positioned(
                      top: 8, left: 8,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 24, height: 24,
                        decoration: BoxDecoration(
                          color: isSelected ? AppTheme.primary : Colors.transparent,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isSelected ? AppTheme.primary : AppTheme.textSecondary,
                            width: 2,
                          ),
                        ),
                        child: isSelected
                            ? const Icon(Icons.check, color: Colors.white, size: 14)
                            : null,
                      ),
                    ),
                ],
              ),
            ),

            // ── File Info ──────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.name,
                    style: AppTheme.bodyMedium.copyWith(
                      color: AppTheme.textPrimary,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          FileUtils.formatFileSize(file.sizeBytes),
                          style: AppTheme.labelLarge,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        file.extension.toUpperCase(),
                        style: AppTheme.labelLarge.copyWith(
                          color: color,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IconBackground extends StatelessWidget {
  final Color color;
  final IconData icon;
  const _IconBackground({required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
      ),
      child: Center(child: Icon(icon, color: color, size: 44)),
    );
  }
}
