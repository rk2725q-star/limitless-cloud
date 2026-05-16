import 'package:flutter/material.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/date_utils.dart';
import '../../data/models/cloud_folder.dart';

class FolderItem extends StatelessWidget {
  final CloudFolder folder;
  final bool isGridView;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onMoreTap;

  const FolderItem({
    super.key,
    required this.folder,
    required this.isGridView,
    required this.onTap,
    required this.onLongPress,
    required this.onMoreTap,
  });

  Color get _folderColor {
    try {
      return Color(
        int.parse(folder.color.replaceAll('#', '0xFF')),
      );
    } catch (_) {
      return AppTheme.folderColor;
    }
  }

  @override
  Widget build(BuildContext context) {
    return isGridView ? _buildGrid() : _buildList();
  }

  Widget _buildGrid() {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Folder icon area
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: _folderColor.withValues(alpha:0.08),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
                ),
                child: Stack(
                  children: [
                    Center(
                      child: Icon(
                        Icons.folder_rounded,
                        color: _folderColor,
                        size: 48,
                      ),
                    ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: GestureDetector(
                        onTap: onMoreTap,
                        child: const Icon(
                          Icons.more_vert_rounded,
                          color: AppTheme.textHint,
                          size: 18,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Folder name & count
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    folder.name,
                    style: AppTheme.bodyMedium.copyWith(
                      color: AppTheme.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${folder.itemCount} item${folder.itemCount != 1 ? 's' : ''}',
                    style: AppTheme.labelLarge,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              margin: const EdgeInsets.only(right: 14),
              decoration: BoxDecoration(
                color: _folderColor.withValues(alpha:0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.folder_rounded, color: _folderColor, size: 24),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    folder.name,
                    style: AppTheme.bodyLarge.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Text(
                        '${folder.itemCount} item${folder.itemCount != 1 ? 's' : ''}',
                        style: AppTheme.bodyMedium,
                      ),
                      const Text(' · ', style: TextStyle(color: AppTheme.textHint)),
                      Text(
                        AppDateUtils.getRelativeTime(folder.createdAt),
                        style: AppTheme.bodyMedium,
                      ),
                    ],
                  ),
                ],
              ),
            ),
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
