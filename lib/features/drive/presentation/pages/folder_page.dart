import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_routes.dart';
import '../../../../core/theme/app_theme.dart';
import '../../data/models/cloud_folder.dart';
import '../providers/drive_provider.dart';
import '../widgets/file_grid_item.dart';
import '../widgets/file_list_item.dart';
import '../widgets/folder_item.dart';

class FolderPage extends ConsumerWidget {
  final Map<String, dynamic> args;
  const FolderPage({super.key, required this.args});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folder = args['folder'] as CloudFolder;
    final drive = ref.watch(driveProvider);
    final foldersAsync = ref.watch(foldersProvider(folder.id));
    final filesAsync = ref.watch(filesProvider((
      folderId: folder.id,
      sortBy: drive.sortBy,
      descending: drive.sortDescending,
    )));

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(folder.name, style: AppTheme.titleLarge),
            Text(folder.path, style: AppTheme.bodyMedium, overflow: TextOverflow.ellipsis),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(drive.isGridView ? Icons.view_list_rounded : Icons.grid_view_rounded),
            onPressed: () => ref.read(driveProvider.notifier).toggleViewMode(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          ref.read(driveProvider.notifier).uploadFiles(
            folderId: folder.id,
            folderPath: folder.path,
          );
        },
        backgroundColor: AppTheme.primary,
        icon: const Icon(Icons.upload_rounded),
        label: const Text('Upload', style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      body: CustomScrollView(
        slivers: [
          foldersAsync.when(
            data: (subFolders) => subFolders.isEmpty
                ? const SliverToBoxAdapter(child: SizedBox.shrink())
                : SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                          child: Text('Subfolders', style: AppTheme.titleMedium),
                        ),
                        ...subFolders.map((f) => FolderItem(
                          folder: f,
                          isGridView: false,
                          onTap: () => Navigator.pushNamed(context, AppRoutes.folder, arguments: {'folder': f}),
                          onLongPress: () {},
                          onMoreTap: () {},
                        )),
                      ],
                    ),
                  ),
            loading: () => const SliverToBoxAdapter(child: SizedBox.shrink()),
            error: (_, __) => const SliverToBoxAdapter(child: SizedBox.shrink()),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Text('Files', style: AppTheme.titleMedium),
            ),
          ),
          filesAsync.when(
            data: (files) => files.isEmpty
                ? const SliverToBoxAdapter(
                    child: Center(
                      child: Padding(
                        padding: EdgeInsets.all(40),
                        child: Column(
                          children: [
                            Icon(Icons.folder_open_rounded, color: AppTheme.textHint, size: 56),
                            SizedBox(height: 12),
                            Text('Folder is empty', style: TextStyle(color: AppTheme.textSecondary)),
                          ],
                        ),
                      ),
                    ),
                  )
                : drive.isGridView
                    ? SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        sliver: SliverGrid(
                          delegate: SliverChildBuilderDelegate(
                            (_, i) => FileGridItem(
                              file: files[i],
                              onTap: () => Navigator.pushNamed(context, AppRoutes.fileDetail, arguments: {'file': files[i]}),
                              onLongPress: () {},
                            ),
                            childCount: files.length,
                          ),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 12, childAspectRatio: 0.78,
                          ),
                        ),
                      )
                    : SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (_, i) => FileListItem(
                            file: files[i],
                            onTap: () => Navigator.pushNamed(context, AppRoutes.fileDetail, arguments: {'file': files[i]}),
                            onLongPress: () {},
                            onMoreTap: () => showModalBottomSheet(
                              context: context,
                              backgroundColor: AppTheme.surface,
                              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
                              builder: (_) => SafeArea(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ListTile(leading: const Icon(Icons.download_rounded, color: AppTheme.primary), title: const Text('Download'), onTap: () { Navigator.pop(context); ref.read(driveProvider.notifier).downloadFile(files[i], onProgress: (_) {}); }),
                                      ListTile(leading: Icon(files[i].isStarred ? Icons.star_border_rounded : Icons.star_rounded, color: AppTheme.warning), title: Text(files[i].isStarred ? 'Remove Star' : 'Star'), onTap: () { Navigator.pop(context); ref.read(driveProvider.notifier).toggleStar(files[i]); }),
                                      ListTile(leading: const Icon(Icons.delete_outline_rounded, color: AppTheme.error), title: const Text('Move to Trash', style: TextStyle(color: AppTheme.error)), onTap: () { Navigator.pop(context); ref.read(driveProvider.notifier).trashFile(files[i]); }),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          childCount: files.length,
                        ),
                      ),
            loading: () => const SliverToBoxAdapter(child: Center(child: CircularProgressIndicator())),
            error: (e, _) => SliverToBoxAdapter(child: Text('$e')),
          ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
        ],
      ),
    );
  }
}
