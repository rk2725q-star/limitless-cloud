import 'package:flutter/material.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/file_utils.dart';
import '../../data/models/cloud_file.dart';

class FileGridItem extends StatelessWidget {
  final CloudFile file;
  final bool isSelected;
  final bool isSelectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const FileGridItem({
    super.key,
    required this.file,
    required this.onTap,
    required this.onLongPress,
    this.isSelected = false,
    this.isSelectionMode = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = FileUtils.getFileColor(file.extension);
    final icon = FileUtils.getFileIcon(file.extension);

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primary.withValues(alpha:0.15)
              : AppTheme.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? AppTheme.primary : AppTheme.cardBorder,
            width: isSelected ? 1.5 : 1,
          ),
          boxShadow: isSelected
              ? [BoxShadow(color: AppTheme.primary.withValues(alpha:0.15), blurRadius: 8)]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Thumbnail / Icon Area ──────────────────────────────────────
            Expanded(
              child: Stack(
                children: [
                  // File type icon background
                  Container(
                    decoration: BoxDecoration(
                      color: color.withValues(alpha:0.08),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
                    ),
                    child: Center(
                      child: Icon(icon, color: color, size: 44),
                    ),
                  ),

                  // Star indicator
                  if (file.isStarred)
                    const Positioned(
                      top: 8,
                      right: 8,
                      child: Icon(
                        Icons.star_rounded,
                        color: AppTheme.warning,
                        size: 16,
                      ),
                    ),

                  // Selection checkbox
                  if (isSelectionMode)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 24,
                        height: 24,
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
