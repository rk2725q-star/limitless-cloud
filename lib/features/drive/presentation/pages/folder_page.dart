import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_routes.dart';
import '../../../../core/theme/app_theme.dart';
import '../../data/models/cloud_folder.dart';
import '../providers/drive_provider.dart';
import '../widgets/file_grid_item.dart';
import '../widgets/file_list_item.dart';
import '../widgets/folder_item.dart';

class FolderPage extends ConsumerStatefulWidget {
  final Map<String, dynamic> args;
  const FolderPage({super.key, required this.args});

  @override
  ConsumerState<FolderPage> createState() => _FolderPageState();
}

class _FolderPageState extends ConsumerState<FolderPage> {
  bool _fabOpen = false;

  CloudFolder get _folder => widget.args['folder'] as CloudFolder;

  void _toggleFab() => setState(() => _fabOpen = !_fabOpen);

  // ── Create subfolder ──────────────────────────────────────────────────────
  void _showCreateSubfolderDialog() {
    setState(() => _fabOpen = false);
    final ctrl = TextEditingController();
    final folder = _folder;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('New Subfolder'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: AppTheme.bodyLarge,
          decoration: const InputDecoration(
            hintText: 'Subfolder name',
            prefixIcon: Icon(Icons.folder_rounded, color: AppTheme.folderColor),
            hintStyle: TextStyle(color: AppTheme.textHint),
          ),
          onSubmitted: (_) => _doCreate(ctrl, folder),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => _doCreate(ctrl, folder),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  Future<void> _doCreate(TextEditingController ctrl, CloudFolder parent) async {
    final name = ctrl.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context);
    // parent.path is already the fully-qualified path of the parent folder
    // e.g. "/" for root folders, "/Movies" for a top-level folder,
    // "/Movies/Action" for a nested folder — works at any depth.
    await ref.read(driveProvider.notifier).createFolder(
      name: name,
      parentFolderId: parent.id,
      parentPath: parent.path, // correct — LocalMetadataService appends /name itself
    );
  }

  // ── Upload files ──────────────────────────────────────────────────────────
  void _doUpload() {
    setState(() => _fabOpen = false);
    ref.read(driveProvider.notifier).uploadFiles(
      folderId: _folder.id,
      folderPath: _folder.path,
    );
  }

  @override
  Widget build(BuildContext context) {
    final folder = _folder;
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

      // ── Speed-dial FAB (New Folder + Upload) ──────────────────────────────
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Mini action buttons (visible when open)
          if (_fabOpen) ...[
            _MiniFab(
              icon: Icons.create_new_folder_rounded,
              label: 'New Subfolder',
              color: AppTheme.secondary,
              onTap: _showCreateSubfolderDialog,
            ),
            const SizedBox(height: 12),
            _MiniFab(
              icon: Icons.upload_file_rounded,
              label: 'Upload Files',
              color: AppTheme.primary,
              onTap: _doUpload,
            ),
            const SizedBox(height: 16),
          ],
          // Main FAB
          FloatingActionButton.extended(
            onPressed: _toggleFab,
            backgroundColor: _fabOpen ? AppTheme.surfaceVariant : AppTheme.primary,
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Icon(
                _fabOpen ? Icons.close_rounded : Icons.add_rounded,
                key: ValueKey(_fabOpen),
              ),
            ),
            label: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Text(
                _fabOpen ? 'Close' : 'New',
                key: ValueKey(_fabOpen),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),

      body: Stack(
        children: [
          CustomScrollView(
            slivers: [
              // Upload progress tasks
              if (drive.uploadTasks.isNotEmpty)
                SliverToBoxAdapter(
                  child: Column(
                    children: drive.uploadTasks.map((task) => Container(
                      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppTheme.card,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.cardBorder),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          const Icon(Icons.upload_rounded, color: AppTheme.primary, size: 18),
                          const SizedBox(width: 8),
                          Expanded(child: Text(task.fileName, style: AppTheme.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis)),
                          Text('${(task.progress * 100).toInt()}%', style: AppTheme.labelLarge.copyWith(color: AppTheme.primary)),
                        ]),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: task.progress,
                          backgroundColor: AppTheme.surfaceVariant,
                          valueColor: const AlwaysStoppedAnimation(AppTheme.primary),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ]),
                    )).toList(),
                  ),
                ),

              // Subfolders
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
                              onMoreTap: () => _showSubfolderOptions(context, f),
                            )),
                          ],
                        ),
                      ),
                loading: () => const SliverToBoxAdapter(child: SizedBox.shrink()),
                error: (_, __) => const SliverToBoxAdapter(child: SizedBox.shrink()),
              ),

              // Files header
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                  child: Text('Files', style: AppTheme.titleMedium),
                ),
              ),

              // Files list / grid
              filesAsync.when(
                data: (files) => files.isEmpty
                    ? const SliverToBoxAdapter(
                        child: Center(
                          child: Padding(
                            padding: EdgeInsets.all(40),
                            child: Column(children: [
                              Icon(Icons.folder_open_rounded, color: AppTheme.textHint, size: 56),
                              SizedBox(height: 12),
                              Text('Folder is empty', style: TextStyle(color: AppTheme.textSecondary)),
                              SizedBox(height: 4),
                              Text('Tap + New to upload or create a subfolder', style: TextStyle(color: AppTheme.textHint, fontSize: 12)),
                            ]),
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
                                onMoreTap: () => _showFileOptions(context, files[i]),
                              ),
                              childCount: files.length,
                            ),
                          ),
                loading: () => const SliverToBoxAdapter(child: Center(child: CircularProgressIndicator())),
                error: (e, _) => SliverToBoxAdapter(child: Text('$e')),
              ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 120)),
            ],
          ),

          // Dimmer when FAB open
          if (_fabOpen)
            GestureDetector(
              onTap: () => setState(() => _fabOpen = false),
              child: Container(color: Colors.black54),
            ),
        ],
      ),
    );
  }

  void _showSubfolderOptions(BuildContext context, CloudFolder sub) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 40, height: 4, decoration: BoxDecoration(color: AppTheme.cardBorder, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline_rounded),
              title: const Text('Rename'),
              onTap: () { Navigator.pop(context); _renameSubfolder(context, sub); },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded, color: AppTheme.error),
              title: const Text('Move to Trash', style: TextStyle(color: AppTheme.error)),
              onTap: () { Navigator.pop(context); ref.read(driveProvider.notifier).trashFolder(sub.id); },
            ),
          ]),
        ),
      ),
    );
  }

  void _renameSubfolder(BuildContext context, CloudFolder sub) {
    final ctrl = TextEditingController(text: sub.name);
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: AppTheme.surface,
      title: const Text('Rename Folder'),
      content: TextField(controller: ctrl, autofocus: true, style: AppTheme.bodyLarge),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(onPressed: () {
          if (ctrl.text.trim().isNotEmpty) {
            ref.read(driveProvider.notifier).renameFolder(sub.id, ctrl.text.trim());
          }
          Navigator.pop(context);
        }, child: const Text('Rename')),
      ],
    ));
  }

  void _showFileOptions(BuildContext context, file) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 40, height: 4, decoration: BoxDecoration(color: AppTheme.cardBorder, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 4),
            ListTile(leading: const Icon(Icons.download_rounded, color: AppTheme.primary), title: const Text('Download'), onTap: () { Navigator.pop(context); ref.read(driveProvider.notifier).downloadFile(file, onProgress: (_) {}); }),
            ListTile(leading: Icon(file.isStarred ? Icons.star_border_rounded : Icons.star_rounded, color: AppTheme.warning), title: Text(file.isStarred ? 'Remove Star' : 'Star'), onTap: () { Navigator.pop(context); ref.read(driveProvider.notifier).toggleStar(file); }),
            ListTile(leading: const Icon(Icons.delete_outline_rounded, color: AppTheme.error), title: const Text('Move to Trash', style: TextStyle(color: AppTheme.error)), onTap: () { Navigator.pop(context); ref.read(driveProvider.notifier).trashFile(file); }),
          ]),
        ),
      ),
    );
  }
}

// ── Mini speed-dial button ────────────────────────────────────────────────────

class _MiniFab extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _MiniFab({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppTheme.cardBorder),
              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2))],
            ),
            child: Text(label, style: AppTheme.labelLarge.copyWith(color: Colors.white)),
          ),
          const SizedBox(width: 12),
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 10, offset: const Offset(0, 4))]),
            child: Icon(icon, color: Colors.white, size: 20),
          ),
        ],
      ),
    );
  }
}
