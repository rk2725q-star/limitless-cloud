import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_routes.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../auth/data/telegram_auth_service.dart';
import '../../data/firestore_metadata_service.dart';
import '../../data/models/cloud_file.dart';
import '../../data/models/cloud_folder.dart';
import '../providers/drive_provider.dart';
import '../widgets/file_grid_item.dart';
import '../widgets/file_list_item.dart';
import '../widgets/folder_item.dart';
import '../widgets/upload_progress_card.dart';

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

  // â”€â”€ Create subfolder â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
    // "/Movies/Action" for a nested folder â€” works at any depth.
    await ref.read(driveProvider.notifier).createFolder(
      name: name,
      parentFolderId: parent.id,
      parentPath: parent.path, // correct â€” LocalMetadataService appends /name itself
    );
  }

  // â”€â”€ Upload files â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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

      // â”€â”€ Speed-dial FAB (New Folder + Upload) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
                data: (files) {
                  final sessionAsync = ref.watch(sessionProvider);
                  final session = sessionAsync.valueOrNull ?? '';
                  const imgExts = {
                    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'avif'
                  };
                  if (files.isEmpty) {
                    return const SliverToBoxAdapter(
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
                    );
                  }
                  return drive.isGridView
                      ? SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverGrid(
                            delegate: SliverChildBuilderDelegate(
                              (_, i) {
                                final f = files[i];
                                final isImg = imgExts.contains(f.extension.toLowerCase());
                                return FileGridItem(
                                  file: f,
                                  sessionString: session,
                                  onTap: () => Navigator.pushNamed(
                                    context,
                                    isImg ? AppRoutes.imageViewer : AppRoutes.fileDetail,
                                    arguments: {'file': f},
                                  ),
                                  onLongPress: () {},
                                );
                              },
                              childCount: files.length,
                            ),
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 12, childAspectRatio: 0.78,
                            ),
                          ),
                        )
                      : SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (_, i) {
                              final f = files[i];
                              final isImg = imgExts.contains(f.extension.toLowerCase());
                              return FileListItem(
                                file: f,
                                onTap: () => Navigator.pushNamed(
                                  context,
                                  isImg ? AppRoutes.imageViewer : AppRoutes.fileDetail,
                                  arguments: {'file': f},
                                ),
                                onLongPress: () {},
                                onMoreTap: () => _showFileOptions(context, f),
                              );
                            },
                            childCount: files.length,
                          ),
                        );
                },
                loading: () => const SliverToBoxAdapter(child: Center(child: CircularProgressIndicator())),
                error: (e, _) => SliverToBoxAdapter(child: Text('$e')),
              ),
              // Extra bottom padding so cards don't cover files
              SliverPadding(
                padding: EdgeInsets.only(
                  bottom: drive.uploadTasks.isNotEmpty ? 200 : 120,
                ),
              ),
            ],
          ),

          // Dimmer when FAB open
          if (_fabOpen)
            GestureDetector(
              onTap: () => setState(() => _fabOpen = false),
              child: Container(color: Colors.black54),
            ),

          // ── Animated upload progress cards (bottom overlay) ────────────────
          const UploadProgressOverlay(),
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
              leading: const Icon(Icons.delete_forever_rounded, color: AppTheme.error),
              title: const Text('Delete Permanently', style: TextStyle(color: AppTheme.error)),
              onTap: () {
                Navigator.pop(context);
                showDialog(
                  context: context,
                  builder: (dialogCtx) => AlertDialog(
                    backgroundColor: AppTheme.surface,
                    title: const Text('Delete Folder'),
                    content: Text('Delete "${sub.name}" permanently? All files inside will also be deleted. This cannot be undone.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogCtx),
                        child: const Text('Cancel'),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
                        onPressed: () async {
                          Navigator.pop(dialogCtx);
                          // Delete immediately — provider invalidation triggers rebuild
                          await ref.read(driveProvider.notifier).deleteFolder(sub.id);
                          // Also explicitly invalidate this folder's subfolder list
                          ref.invalidate(foldersProvider(sub.parentFolderId));
                        },
                        child: const Text('Delete', style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                );
              },
            ),
          ]),
        ),
      ),
    );
  }

  void _renameSubfolder(BuildContext context, CloudFolder sub) {
    final ctrl = TextEditingController(text: sub.name);
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Rename Folder'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: AppTheme.bodyLarge,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (ctrl.text.trim().isNotEmpty) {
                ref.read(driveProvider.notifier).renameFolder(sub.id, ctrl.text.trim());
              }
              Navigator.pop(dialogCtx);
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
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
            ListTile(
              leading: const Icon(Icons.drive_file_move_rounded, color: AppTheme.secondary),
              title: const Text('Move to Folder'),
              onTap: () {
                Navigator.pop(context);
                _showFolderPickerForFile(context, file, mode: 'move');
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded, color: AppTheme.accent),
              title: const Text('Copy to Folder'),
              onTap: () {
                Navigator.pop(context);
                _showFolderPickerForFile(context, file, mode: 'copy');
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_forever_rounded, color: AppTheme.error),
              title: const Text('Delete Permanently', style: TextStyle(color: AppTheme.error)),
              onTap: () {
                Navigator.pop(context);
                showDialog(
                  context: context,
                  builder: (dialogCtx) => AlertDialog(
                    backgroundColor: AppTheme.surface,
                    title: const Text('Delete File'),
                    content: Text('Permanently delete "${file.name}"? This will remove it from Telegram and cannot be undone.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Cancel')),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
                        onPressed: () {
                          Navigator.pop(dialogCtx);
                          ref.read(driveProvider.notifier).deleteFile(file);
                        },
                        child: const Text('Delete', style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                );
              },
            ),
          ]),
        ),
      ),
    );
  }

  void _showFolderPickerForFile(BuildContext context, CloudFile file, {required String mode}) {
    showDialog(
      context: context,
      builder: (_) => _FolderBrowserDialog(file: file, ref: ref, mode: mode),
    );
  }
}

// â”€â”€ Browse-style folder picker dialog â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// Tap a folder to navigate inside it. Back arrow goes up. "Move/Copy Here"
// button pastes into the current browsed location.

class _FolderBrowserDialog extends ConsumerStatefulWidget {
  final CloudFile file;
  final WidgetRef ref;
  final String mode;
  const _FolderBrowserDialog({required this.file, required this.ref, required this.mode});

  @override
  ConsumerState<_FolderBrowserDialog> createState() => _FolderBrowserDialogState();
}

class _FolderBrowserDialogState extends ConsumerState<_FolderBrowserDialog> {
  final List<CloudFolder?> _navStack = [null]; // null = My Drive root
  List<CloudFolder> _subfolders = [];
  bool _loadingSubfolders = true;
  bool _busy = false;

  CloudFolder? get _currentFolder => _navStack.last;

  @override
  void initState() {
    super.initState();
    _loadSubfolders();
  }

  Future<void> _loadSubfolders() async {
    if (mounted) setState(() => _loadingSubfolders = true);
    try {
      final authService = ref.read(telegramAuthServiceProvider);
      final profile = await authService.getProfile();
      final userId = profile['userId'] ?? '';
      if (userId.isEmpty) {
        if (mounted) setState(() { _subfolders = []; _loadingSubfolders = false; });
        return;
      }
      final service = ref.read(firestoreServiceProvider);
      final folders = await service
          .getFolders(userId: userId, parentFolderId: _currentFolder?.id)
          .first;
      if (mounted) setState(() { _subfolders = folders; _loadingSubfolders = false; });
    } catch (_) {
      if (mounted) setState(() { _subfolders = []; _loadingSubfolders = false; });
    }
  }

  void _enterFolder(CloudFolder f) {
    _navStack.add(f);
    _loadSubfolders();
  }

  void _goUp() {
    if (_navStack.length > 1) {
      _navStack.removeLast();
      _loadSubfolders();
    }
  }

  bool get _isCurrentFileLocation {
    if (_currentFolder == null) return widget.file.folderId == null;
    return widget.file.folderId == _currentFolder!.id;
  }

  String get _breadcrumb {
    if (_navStack.length == 1) return 'My Drive';
    return _navStack.skip(1).map((f) => f!.name).join(' / ');
  }

  @override
  Widget build(BuildContext context) {
    final isMove = widget.mode == 'move';
    final accent = isMove ? AppTheme.secondary : AppTheme.accent;

    return Dialog(
      backgroundColor: AppTheme.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 14),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.07),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(isMove ? Icons.drive_file_move_rounded : Icons.copy_rounded,
                    color: accent, size: 22),
                const SizedBox(width: 10),
                Text(isMove ? 'Move to Folder' : 'Copy to Folder',
                    style: AppTheme.titleMedium.copyWith(color: accent)),
              ]),
              const SizedBox(height: 4),
              Text(widget.file.name,
                  style: AppTheme.bodyMedium.copyWith(color: AppTheme.textSecondary),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          // Navigation bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppTheme.cardBorder, width: 0.5)),
            ),
            child: Row(children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
                onPressed: _navStack.length > 1 ? _goUp : null,
                color: _navStack.length > 1 ? AppTheme.textPrimary : AppTheme.textHint,
                padding: const EdgeInsets.all(6),
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(_breadcrumb,
                    style: AppTheme.bodyMedium.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ]),
          ),
          // Folder list
          SizedBox(
            height: 270,
            child: _loadingSubfolders
                ? const Center(child: CircularProgressIndicator())
                : _subfolders.isEmpty
                    ? Center(
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          const Icon(Icons.folder_open_rounded, size: 42, color: AppTheme.textHint),
                          const SizedBox(height: 8),
                          Text('No subfolders here',
                              style: AppTheme.bodyMedium.copyWith(color: AppTheme.textHint)),
                          if (_isCurrentFileLocation)
                            Text('(file is already here)',
                                style: AppTheme.bodyMedium.copyWith(color: AppTheme.textHint, fontSize: 11)),
                        ]),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: _subfolders.length,
                        itemBuilder: (_, i) {
                          final f = _subfolders[i];
                          return ListTile(
                            leading: Container(
                              width: 40, height: 40,
                              decoration: BoxDecoration(
                                color: const Color(0xFF4F8CFF).withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(Icons.folder_rounded,
                                  color: Color(0xFF4F8CFF), size: 22),
                            ),
                            title: Text(f.name,
                                style: AppTheme.bodyMedium.copyWith(fontWeight: FontWeight.w600)),
                            subtitle: Text(
                              '${f.itemCount} item${f.itemCount == 1 ? '' : 's'}',
                              style: const TextStyle(fontSize: 11),
                            ),
                            trailing: const Icon(Icons.chevron_right_rounded,
                                color: AppTheme.textSecondary),
                            onTap: () => _enterFolder(f),
                          );
                        },
                      ),
          ),
          // Action bar
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppTheme.cardBorder, width: 0.5)),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(20)),
            ),
            child: Row(children: [
              TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              const Spacer(),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(right: 10),
                  child: SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isCurrentFileLocation ? AppTheme.surfaceVariant : accent,
                  foregroundColor: _isCurrentFileLocation ? AppTheme.textHint : Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                ),
                icon: Icon(
                  isMove ? Icons.drive_file_move_rounded : Icons.copy_rounded,
                  size: 18,
                ),
                label: Text(isMove ? 'Move Here' : 'Copy Here',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                onPressed: (_isCurrentFileLocation || _busy) ? null : _executeHere,
              ),
            ]),
          ),
        ],
      ),
    );
  }

  Future<void> _executeHere() async {
    setState(() => _busy = true);
    final destination = _currentFolder;
    try {
      final destId   = destination?.id;
      final destPath = destination?.path ?? '/';
      final destName = destination?.name ?? 'My Drive';

      final destFolder = CloudFolder(
        id: destId ?? '',
        name: destName,
        parentFolderId: destination?.parentFolderId,
        path: destPath,
        color: destination?.color ?? '#4F8CFF',
        metaMessageId: destination?.metaMessageId ?? 0,
        createdAt: destination?.createdAt ?? DateTime.now(),
        updatedAt: destination?.updatedAt ?? DateTime.now(),
      );

      if (widget.mode == 'move') {
        await widget.ref.read(driveProvider.notifier).moveFile(widget.file, destFolder);
      } else {
        await widget.ref.read(driveProvider.notifier).copyFile(widget.file, destFolder);
      }

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(widget.mode == 'move'
              ? 'Moved to $destName'
              : 'Copied to $destName'),
          backgroundColor:
              widget.mode == 'move' ? AppTheme.secondary : AppTheme.accent,
        ));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed: $e'),
          backgroundColor: AppTheme.error,
        ));
      }
    }
  }
}

// â”€â”€ Mini speed-dial button â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

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
