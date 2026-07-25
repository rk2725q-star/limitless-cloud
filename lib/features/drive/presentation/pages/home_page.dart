import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_routes.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/file_utils.dart';
import '../../../auth/data/telegram_auth_service.dart';
import '../../data/models/cloud_file.dart';
import '../../data/models/cloud_folder.dart';
import '../../data/firestore_metadata_service.dart';
import '../../data/telegram_storage_service.dart';
import '../providers/drive_provider.dart';
import '../widgets/file_grid_item.dart';
import '../widgets/file_list_item.dart';
import '../widgets/folder_item.dart';
import './download_manager_page.dart';
import '../widgets/upload_progress_card.dart';

// ── Global nav-index provider — lets any widget switch the HomePage tab ────────
final homeNavIndexProvider = StateProvider<int>((ref) => 0);

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});
  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  @override
  Widget build(BuildContext context) {
    final navIndex = ref.watch(homeNavIndexProvider);
    final pages = [
      const _DriveTab(),
      const _StarredTab(),
      const _CategoriesTab(),
      const _DownloadsTab(),
    ];

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: pages[navIndex],
      floatingActionButton: navIndex == 0 ? _buildFAB(context) : null,
      bottomNavigationBar: _buildBottomNav(navIndex),
    );
  }

  Widget _buildFAB(BuildContext context) {
    // Watch selection mode — hide FAB when user is selecting files
    final isSelecting = ref.watch(driveProvider.select((s) => s.isSelectionMode));
    if (isSelecting) return const SizedBox.shrink();
    return FloatingActionButton.extended(
      onPressed: () => _showUploadOptions(context),
      backgroundColor: AppTheme.primary,
      icon: const Icon(Icons.add_rounded),
      label: const Text('New', style: TextStyle(fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildBottomNav(int navIndex) {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        border: Border(top: BorderSide(color: AppTheme.cardBorder)),
      ),
      child: BottomNavigationBar(
        currentIndex: navIndex,
        onTap: (i) => ref.read(homeNavIndexProvider.notifier).state = i,
        backgroundColor: Colors.transparent,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.cloud_rounded), label: 'My Drive'),
          BottomNavigationBarItem(icon: Icon(Icons.star_rounded), label: 'Starred'),
          BottomNavigationBarItem(icon: Icon(Icons.category_rounded), label: 'Categories'),
          BottomNavigationBarItem(icon: Icon(Icons.download_for_offline_rounded), label: 'Downloads'),
        ],
      ),
    );
  }

  void _showUploadOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => _UploadOptionsSheet(
        onUploadFiles: () {
          Navigator.pop(context);
          ref.read(driveProvider.notifier).uploadFiles();
        },
        onCreateFolder: () {
          Navigator.pop(context);
          _showCreateFolderDialog(context);
        },
      ),
    );
  }

  void _showCreateFolderDialog(BuildContext context, {String? parentFolderId, String parentPath = '/'}) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('New Folder'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: AppTheme.bodyLarge,
          decoration: const InputDecoration(
            hintText: 'Folder name',
            prefixIcon: Icon(Icons.folder_rounded, color: AppTheme.folderColor),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              if (ctrl.text.trim().isNotEmpty) {
                ref.read(driveProvider.notifier).createFolder(
                  name: ctrl.text.trim(),
                  parentFolderId: parentFolderId,
                  parentPath: parentPath,
                );
                Navigator.pop(context);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
}

// â”€â”€ Drive Tab â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _DriveTab extends ConsumerStatefulWidget {
  const _DriveTab();

  @override
  ConsumerState<_DriveTab> createState() => _DriveTabState();
}

class _DriveTabState extends ConsumerState<_DriveTab> {
  int _syncedFiles = 0;
  int _syncedFolders = 0;
  bool _syncDone = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  Future<void> _sync() async {
    final result = await ref.read(driveProvider.notifier).syncFromTelegram();
    if (mounted && (result.files > 0 || result.folders > 0)) {
      setState(() {
        _syncedFiles = result.files;
        _syncedFolders = result.folders;
        _syncDone = true;
      });
      await Future.delayed(const Duration(seconds: 4));
      if (mounted) setState(() => _syncDone = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final drive = ref.watch(driveProvider);
    final foldersAsync = ref.watch(foldersProvider(null));
    final filesAsync = ref.watch(filesProvider((
      folderId: null,
      sortBy: drive.sortBy,
      descending: drive.sortDescending,
    )));
    final stats = ref.watch(userStatsProvider);

    return Stack(
      children: [
        CustomScrollView(
      slivers: [
        // ── App Bar ───────────────────────────────────────────────────────
        SliverAppBar(
          floating: true,
          backgroundColor: AppTheme.background,
          title: Row(
            children: [
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  gradient: AppTheme.primaryGradient,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.cloud_rounded, color: Colors.white, size: 18),
              ),
              const SizedBox(width: 10),
              Text('My Drive', style: AppTheme.headlineMedium),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.search_rounded),
              onPressed: () => Navigator.pushNamed(context, AppRoutes.search),
            ),
            IconButton(
              icon: Icon(drive.isGridView ? Icons.view_list_rounded : Icons.grid_view_rounded),
              onPressed: () => ref.read(driveProvider.notifier).toggleViewMode(),
            ),
            IconButton(
              icon: const Icon(Icons.settings_rounded),
              onPressed: () => Navigator.pushNamed(context, AppRoutes.settings),
            ),
          ],
        ),

        SliverToBoxAdapter(
          child: stats.when(
            data: (data) {
              final used = (data['totalStorageUsed'] ?? 0) as int;
              return _StorageBanner(usedBytes: used);
            },
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
        ),

        foldersAsync.when(
          data: (folders) => folders.isEmpty ? const SliverToBoxAdapter(child: SizedBox.shrink()) : _buildFoldersSection(context, ref, folders, drive.isGridView),
          loading: () => const SliverToBoxAdapter(child: LinearProgressIndicator()),
          error: (e, _) => SliverToBoxAdapter(child: Text('$e')),
        ),

        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Row(
              children: [
                Text('Files', style: AppTheme.titleMedium),
                const Spacer(),
                _SortButton(),
              ],
            ),
          ),
        ),

        filesAsync.when(
          data: (files) => files.isEmpty
              ? const SliverToBoxAdapter(child: _EmptyState(message: 'No files yet\nTap + to upload'))
              : drive.isGridView
                  ? _buildFileGrid(context, ref, files, drive)
                  : _buildFileList(context, ref, files, drive),
          loading: () => const SliverToBoxAdapter(child: Center(child: CircularProgressIndicator())),
          error: (e, _) => SliverToBoxAdapter(child: Text('$e')),
        ),

        SliverPadding(
          padding: EdgeInsets.only(
            bottom: drive.isSelectionMode
                ? 86
                : drive.uploadTasks.isNotEmpty ? 200 : 100,
          ),
        ),
      ],
    ),
        if (_syncDone)
          Positioned(
            top: 80, left: 16, right: 16,
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(12),
              color: AppTheme.secondary,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(children: [
                  const Icon(Icons.sync_rounded, color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Synced: $_syncedFolders folder(s) · $_syncedFiles file(s)',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                  ),
                ]),
              ),
            ),
          ),

        // ── Persistent multi-select action bar (slides up when files selected) ──
        if (drive.isSelectionMode && drive.selectedFileIds.isNotEmpty)
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: _SelectionActionBar(
              selectedCount: drive.selectedFileIds.length,
              onAction: (action) => _handleSelectionAction(
                context, ref, action, drive,
                filesAsync.valueOrNull ?? [],
              ),
              onClearSelection: () => ref.read(driveProvider.notifier).clearSelection(),
            ),
          ),

        // ── Animated upload progress cards (bottom overlay) ────────────────────
        if (!drive.isSelectionMode)
          const UploadProgressOverlay(),
      ],
    );
  }

  Widget _buildFoldersSection(BuildContext context, WidgetRef ref, List<CloudFolder> folders, bool isGrid) {
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text('Folders', style: AppTheme.titleMedium),
          ),
          isGrid
              ? GridView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 1.2,
                  ),
                  itemCount: folders.length,
                  itemBuilder: (_, i) => FolderItem(
                    folder: folders[i],
                    isGridView: true,
                    onTap: () => Navigator.pushNamed(context, AppRoutes.folder, arguments: {'folder': folders[i]}),
                    onLongPress: () {},
                    onMoreTap: () => _showFolderOptions(context, ref, folders[i]),
                  ),
                )
              : Column(
                  children: folders.map((f) => FolderItem(
                    folder: f,
                    isGridView: false,
                    onTap: () => Navigator.pushNamed(context, AppRoutes.folder, arguments: {'folder': f}),
                    onLongPress: () {},
                    onMoreTap: () => _showFolderOptions(context, ref, f),
                  )).toList(),
                ),
        ],
      ),
    );
  }

  Widget _buildFileGrid(BuildContext context, WidgetRef ref, List<CloudFile> files, DriveState drive) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid(
        delegate: SliverChildBuilderDelegate(
          (_, i) {
            final f = files[i];
            final isImg = _imageExts.contains(f.extension.toLowerCase());
            return FileGridItem(
              file: f,
              isSelected: drive.selectedFileIds.contains(f.id),
              isSelectionMode: drive.isSelectionMode,
              onTap: () => drive.isSelectionMode
                  ? ref.read(driveProvider.notifier).toggleSelection(f.id)
                  : isImg
                      ? Navigator.pushNamed(context, AppRoutes.imageViewer, arguments: {'file': f})
                      : Navigator.pushNamed(context, AppRoutes.fileDetail, arguments: {'file': f}),
              onLongPress: () => ref.read(driveProvider.notifier).toggleSelection(f.id),
            );
          },
          childCount: files.length,
        ),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 0.78,
        ),
      ),
    );
  }

  Widget _buildFileList(BuildContext context, WidgetRef ref, List<CloudFile> files, DriveState drive) {
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (_, i) {
          final f = files[i];
          final isImg = _imageExts.contains(f.extension.toLowerCase());
          return FileListItem(
            file: f,
            isSelected: drive.selectedFileIds.contains(f.id),
            isSelectionMode: drive.isSelectionMode,
            onTap: () => drive.isSelectionMode
                ? ref.read(driveProvider.notifier).toggleSelection(f.id)
                : isImg
                    ? Navigator.pushNamed(context, AppRoutes.imageViewer, arguments: {'file': f})
                    : Navigator.pushNamed(context, AppRoutes.fileDetail, arguments: {'file': f}),
            onLongPress: () => ref.read(driveProvider.notifier).toggleSelection(f.id),
            onMoreTap: () => _showFileOptions(context, ref, f),
          );
        },
        childCount: files.length,
      ),
    );
  }

  void _showFolderOptions(BuildContext context, WidgetRef ref, CloudFolder folder) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => _FolderOptionsSheet(folder: folder, ref: ref),
    );
  }

  void _showFileOptions(BuildContext context, WidgetRef ref, CloudFile tappedFile) {
    final drive = ref.read(driveProvider);
    // If multiple files are selected, show bulk action sheet
    if (drive.isSelectionMode && drive.selectedFileIds.length > 1) {
      final filesAsync = ref.read(filesProvider((
        folderId: null,
        sortBy: drive.sortBy,
        descending: drive.sortDescending,
      )));
      final allFiles = filesAsync.valueOrNull ?? <CloudFile>[];
      final selectedFiles = allFiles
          .where((f) => drive.selectedFileIds.contains(f.id))
          .toList();
      showModalBottomSheet(
        context: context,
        backgroundColor: AppTheme.surface,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
        builder: (_) => _MultiFileOptionsSheet(
          selectedFiles: selectedFiles,
          outerScaffoldContext: context,
        ),
      );
    } else {
      showModalBottomSheet(
        context: context,
        backgroundColor: AppTheme.surface,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
        builder: (_) => _FileOptionsSheet(file: tappedFile, ref: ref),
      );
    }
  }

  /// Called by the persistent selection bar for each action tap.
  void _handleSelectionAction(
    BuildContext context,
    WidgetRef ref,
    String action,
    DriveState drive,
    List<CloudFile> allFiles,
  ) {
    final selectedFiles = allFiles
        .where((f) => drive.selectedFileIds.contains(f.id))
        .toList();
    if (selectedFiles.isEmpty) return;

    switch (action) {
      case 'download':
        final auth = ref.read(telegramAuthServiceProvider);
        final tg = TelegramStorageService(auth);
        for (final f in selectedFiles) {
          ref.read(dlManagerProvider.notifier).downloadCloudFile(f, tg);
        }
        ref.read(driveProvider.notifier).clearSelection();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Row(children: [
            const Icon(Icons.download_rounded, color: Colors.white, size: 16),
            const SizedBox(width: 8),
            Text('Queued ${selectedFiles.length} file${selectedFiles.length == 1 ? '' : 's'} for download'),
          ]),
          backgroundColor: AppTheme.primary,
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: 'View',
            textColor: Colors.white,
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
              ref.read(homeNavIndexProvider.notifier).state = 3;
            },
          ),
        ));
        break;

      case 'star':
        final allStarred = selectedFiles.every((f) => f.isStarred);
        for (final f in selectedFiles) {
          if (f.isStarred == allStarred) {
            ref.read(driveProvider.notifier).toggleStar(f);
          }
        }
        ref.read(driveProvider.notifier).clearSelection();
        break;

      case 'move':
        showDialog(
          context: context,
          builder: (_) => _MultiFolderPickerDialog(
            files: selectedFiles,
            ref: ref,
            mode: 'move',
          ),
        );
        break;

      case 'copy':
        showDialog(
          context: context,
          builder: (_) => _MultiFolderPickerDialog(
            files: selectedFiles,
            ref: ref,
            mode: 'copy',
          ),
        );
        break;

      case 'delete':
        final count = selectedFiles.length;
        showDialog(
          context: context,
          builder: (dialogCtx) => AlertDialog(
            backgroundColor: AppTheme.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Row(children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: AppTheme.error.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.delete_forever_rounded, color: AppTheme.error, size: 20),
              ),
              const SizedBox(width: 10),
              const Text('Delete Files'),
            ]),
            content: Text(
              'Permanently delete $count file${count == 1 ? '' : 's'}?\nThis cannot be undone.',
              style: AppTheme.bodyMedium.copyWith(height: 1.5),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Cancel')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.error,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () async {
                  Navigator.pop(dialogCtx);
                  for (final f in selectedFiles) {
                    await ref.read(driveProvider.notifier).deleteFile(f);
                  }
                  ref.read(driveProvider.notifier).clearSelection();
                },
                child: const Text('Delete All', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        );
        break;
    }
  }
}

// â”€â”€ Starred Tab â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _StarredTab extends ConsumerWidget {
  const _StarredTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filesAsync = ref.watch(allFilesProvider((starredOnly: true, trashedOnly: false)));
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(title: const Text('Starred'), backgroundColor: AppTheme.background),
      body: filesAsync.when(
        data: (files) => files.isEmpty
            ? const _EmptyState(message: 'No starred files\nStar files to find them quickly')
            : ListView.builder(
                itemCount: files.length,
                itemBuilder: (_, i) {
                  final f = files[i];
                  final isImg = _imageExts.contains(f.extension.toLowerCase());
                  return FileListItem(
                    file: f,
                    onTap: () => Navigator.pushNamed(
                      context,
                      isImg ? AppRoutes.imageViewer : AppRoutes.fileDetail,
                      arguments: {'file': f},
                    ),
                    onLongPress: () {},
                    onMoreTap: () {},
                  );
                },
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
      ),
    );
  }
}

// â”€â”€ Categories Tab â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _CategoriesTab extends ConsumerStatefulWidget {
  const _CategoriesTab();
  @override
  ConsumerState<_CategoriesTab> createState() => _CategoriesTabState();
}

class _CategoriesTabState extends ConsumerState<_CategoriesTab>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;

  static const _cats = [
    (cat: FileCategory.images,    icon: Icons.image_rounded,          color: Color(0xFF4CAF50)),
    (cat: FileCategory.videos,    icon: Icons.videocam_rounded,       color: Color(0xFFE91E63)),
    (cat: FileCategory.audio,     icon: Icons.music_note_rounded,     color: Color(0xFF9C27B0)),
    (cat: FileCategory.documents, icon: Icons.description_rounded,    color: Color(0xFF2196F3)),
    (cat: FileCategory.others,    icon: Icons.folder_zip_rounded,     color: Color(0xFFFF9800)),
  ];

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: _cats.length, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: Row(children: [
          Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
              gradient: AppTheme.primaryGradient,
              borderRadius: BorderRadius.circular(7),
            ),
            child: const Icon(Icons.category_rounded, color: Colors.white, size: 16),
          ),
          const SizedBox(width: 10),
          const Text('Categories'),
        ]),
        bottom: TabBar(
          controller: _tabCtrl,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          padding: EdgeInsets.zero,
          indicatorColor: AppTheme.primary,
          labelColor: AppTheme.primary,
          unselectedLabelColor: AppTheme.textSecondary,
          tabs: _cats.map((c) => Tab(
            icon: Icon(c.icon, size: 18),
            text: c.cat.label,
          )).toList(),
        ),
      ),
      body: TabBarView(
        controller: _tabCtrl,
        children: _cats.map((c) => _CategoryList(
          category: c.cat,
          accentColor: c.color,
          icon: c.icon,
        )).toList(),
      ),
    );
  }
}

class _CategoryList extends ConsumerStatefulWidget {
  final FileCategory category;
  final Color accentColor;
  final IconData icon;
  const _CategoryList({required this.category, required this.accentColor, required this.icon});

  @override
  ConsumerState<_CategoryList> createState() => _CategoryListState();
}

class _CategoryListState extends ConsumerState<_CategoryList> {
  bool _isGridView = true; // default grid for images

  @override
  void initState() {
    super.initState();
    // Images start in grid, others in list
    _isGridView = widget.category == FileCategory.images;
  }

  @override
  Widget build(BuildContext context) {
    final filesAsync = ref.watch(filesByCategoryProvider(widget.category));
    return filesAsync.when(
      data: (files) {
        if (files.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 80, height: 80,
                  decoration: BoxDecoration(
                    color: widget.accentColor.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(widget.icon, color: widget.accentColor, size: 40),
                ),
                const SizedBox(height: 20),
                Text('No ${widget.category.label}',
                    style: AppTheme.titleLarge.copyWith(color: AppTheme.textSecondary)),
                const SizedBox(height: 8),
                Text('Upload ${widget.category.label.toLowerCase()} to see them here',
                    style: AppTheme.bodyMedium, textAlign: TextAlign.center),
              ],
            ),
          );
        }
        return Column(
          children: [
            // â”€â”€ Stats header + view toggle â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
            Container(
              margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: widget.accentColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: widget.accentColor.withValues(alpha: 0.25)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: widget.accentColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(widget.icon, color: widget.accentColor, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${files.length} ${widget.category.label}',
                        style: AppTheme.titleMedium.copyWith(color: widget.accentColor)),
                    Text(FileUtils.formatFileSize(files.fold(0, (s, f) => s + f.sizeBytes)),
                        style: AppTheme.bodyMedium),
                  ]),
                  const Spacer(),
                  // View toggle
                  GestureDetector(
                    onTap: () => setState(() => _isGridView = !_isGridView),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: widget.accentColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        _isGridView ? Icons.view_list_rounded : Icons.grid_view_rounded,
                        color: widget.accentColor, size: 18,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // â”€â”€ File list or image grid â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
            Expanded(
              child: widget.category == FileCategory.images && _isGridView
                  ? _ImageGalleryGrid(files: files, accentColor: widget.accentColor)
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 80),
                      itemCount: files.length,
                      itemBuilder: (_, i) {
                        final f = files[i];
                        final isImg = _imageExts.contains(f.extension.toLowerCase());
                        final imgFiles = isImg
                            ? files.where((x) => _imageExts.contains(x.extension.toLowerCase())).toList()
                            : <CloudFile>[];
                        final imgIndex = isImg ? imgFiles.indexOf(f) : 0;
                        return FileListItem(
                          file: f,
                          onTap: () => Navigator.pushNamed(
                            context,
                            isImg ? AppRoutes.imageViewer : AppRoutes.fileDetail,
                            arguments: isImg
                                ? {'file': f, 'allFiles': imgFiles, 'initialIndex': imgIndex}
                                : {'file': f},
                          ),
                          onLongPress: () {},
                          onMoreTap: () => _showCategoryFileOptions(context, f),
                        );
                      },
                    ),
            ),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
    );
  }

  // â”€â”€ Category file options bottom sheet â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  void _showCategoryFileOptions(BuildContext context, CloudFile file) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => _FileOptionsSheet(file: file, ref: ref),
    );
  }
}

// â”€â”€ Image Gallery Grid â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

const _imageExts = {
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'avif'
};

class _ImageGalleryGrid extends ConsumerWidget {
  final List<CloudFile> files;
  final Color accentColor;
  const _ImageGalleryGrid({required this.files, required this.accentColor});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 80),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 3,
        mainAxisSpacing: 3,
      ),
      itemCount: files.length,
      itemBuilder: (_, i) {
        final f = files[i];
        return GestureDetector(
          onTap: () => Navigator.pushNamed(
            context,
            AppRoutes.imageViewer,
            arguments: {'file': f, 'allFiles': files, 'initialIndex': i},
          ),
          child: _GalleryThumbnail(file: f),
        );
      },
    );
  }
}

class _GalleryThumbnail extends StatelessWidget {
  final CloudFile file;
  const _GalleryThumbnail({required this.file});

  @override
  Widget build(BuildContext context) {
    final color = FileUtils.getFileColor(file.extension);
    // Serverless mode: no backend URL for streaming thumbnails
    // Show image icon placeholder instead
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _imgPlaceholder(color),
          // Bottom gradient
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: Container(
              height: 40,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black.withValues(alpha: 0.6), Colors.transparent],
                ),
              ),
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
              alignment: Alignment.bottomLeft,
              child: Text(
                file.name,
                style: const TextStyle(
                    color: Colors.white, fontSize: 9, fontWeight: FontWeight.w500),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          // Star
          if (file.isStarred)
            const Positioned(
              top: 4, right: 4,
              child: Icon(Icons.star_rounded, color: AppTheme.warning, size: 14),
            ),
        ],
      ),
    );
  }

  Widget _imgPlaceholder(Color color) {
    return Container(
      color: color.withValues(alpha: 0.08),
      child: Icon(Icons.image_rounded, color: color, size: 32),
    );
  }
}

// â”€â”€ Downloads Tab â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _DownloadsTab extends StatelessWidget {
  const _DownloadsTab();
  @override
  Widget build(BuildContext context) {
    return const DownloadManagerPage();
  }
}


// â”€â”€ Helper Widgets â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _StorageBanner extends StatelessWidget {
  final int usedBytes;
  const _StorageBanner({required this.usedBytes});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1A2040), Color(0xFF1A1535)],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_done_rounded, color: AppTheme.primary, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Unlimited Storage', style: AppTheme.titleMedium.copyWith(color: AppTheme.primary)),
                Text(
                  'Used: ${FileUtils.formatFileSize(usedBytes)}  |  Powered by Telegram',
                  style: AppTheme.bodyMedium,
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
            ),
            child: const Text('inf', style: TextStyle(color: AppTheme.primary, fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: -0.5)),
          ),
        ],
      ),
    );
  }
}





class _EmptyState extends StatelessWidget {
  final String message;
  const _EmptyState({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_upload_outlined, color: AppTheme.textHint, size: 64),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppTheme.bodyMedium.copyWith(height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}

class _SortButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drive = ref.watch(driveProvider);
    return PopupMenuButton<String>(
      color: AppTheme.surfaceVariant,
      icon: const Icon(Icons.sort_rounded, color: AppTheme.textSecondary),
      onSelected: (v) => ref.read(driveProvider.notifier).setSortBy(v),
      itemBuilder: (_) => [
        _menuItem('uploadedAt', 'Date', Icons.calendar_today_rounded, drive.sortBy),
        _menuItem('name', 'Name', Icons.sort_by_alpha_rounded, drive.sortBy),
        _menuItem('sizeBytes', 'Size', Icons.storage_rounded, drive.sortBy),
      ],
    );
  }

  PopupMenuItem<String> _menuItem(String value, String label, IconData icon, String current) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 18, color: value == current ? AppTheme.primary : AppTheme.textSecondary),
          const SizedBox(width: 10),
          Text(label, style: AppTheme.bodyMedium.copyWith(color: value == current ? AppTheme.primary : AppTheme.textPrimary)),
          if (value == current) ...[const Spacer(), const Icon(Icons.check, size: 16, color: AppTheme.primary)],
        ],
      ),
    );
  }
}

class _UploadOptionsSheet extends StatelessWidget {
  final VoidCallback onUploadFiles;
  final VoidCallback onCreateFolder;
  const _UploadOptionsSheet({required this.onUploadFiles, required this.onCreateFolder});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 40, height: 4, decoration: BoxDecoration(color: AppTheme.cardBorder, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 20),
            Text('Add New', style: AppTheme.headlineMedium),
            const SizedBox(height: 24),
            _OptionTile(icon: Icons.upload_file_rounded, color: AppTheme.primary, title: 'Upload Files', subtitle: 'Pick any file from device', onTap: onUploadFiles),
            const SizedBox(height: 12),
            _OptionTile(icon: Icons.create_new_folder_rounded, color: AppTheme.secondary, title: 'New Folder', subtitle: 'Organize your files', onTap: onCreateFolder),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _OptionTile({required this.icon, required this.color, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Row(
          children: [
            Container(width: 48, height: 48, decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle), child: Icon(icon, color: color, size: 24)),
            const SizedBox(width: 16),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppTheme.titleMedium),
              Text(subtitle, style: AppTheme.bodyMedium),
            ]),
            const Spacer(),
            Icon(Icons.arrow_forward_ios_rounded, color: color, size: 16),
          ],
        ),
      ),
    );
  }
}

class _FolderOptionsSheet extends StatelessWidget {
  final CloudFolder folder;
  final WidgetRef ref;
  const _FolderOptionsSheet({required this.folder, required this.ref});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 40, height: 4, decoration: BoxDecoration(color: AppTheme.cardBorder, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            ListTile(leading: const Icon(Icons.drive_file_rename_outline_rounded), title: const Text('Rename'), onTap: () { Navigator.pop(context); _rename(context); }),
            ListTile(
              leading: const Icon(Icons.delete_forever_rounded, color: AppTheme.error),
              title: const Text('Delete Permanently', style: TextStyle(color: AppTheme.error)),
              onTap: () {
                Navigator.pop(context);
                _confirmDeleteFolder(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _rename(BuildContext context) {
    final ctrl = TextEditingController(text: folder.name);
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Rename Folder'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: AppTheme.bodyLarge,
          decoration: const InputDecoration(hintText: 'Folder name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final name = ctrl.text.trim();
              if (name.isNotEmpty) {
                ref.read(driveProvider.notifier).renameFolder(folder.id, name);
              }
              Navigator.pop(dialogCtx);
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteFolder(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Delete Folder'),
        content: Text('Delete "${folder.name}" permanently? All files inside will also be deleted. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            onPressed: () {
              Navigator.pop(dialogCtx);
              ref.read(driveProvider.notifier).deleteFolder(folder.id);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

class _FileOptionsSheet extends StatelessWidget {
  final CloudFile file;
  final WidgetRef ref;
  const _FileOptionsSheet({required this.file, required this.ref});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 40, height: 4, decoration: BoxDecoration(color: AppTheme.cardBorder, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 4),
            ListTile(
              leading: const Icon(Icons.download_rounded, color: AppTheme.primary),
              title: const Text('Download'),
              onTap: () {
                Navigator.pop(context);
                final auth = ref.read(telegramAuthServiceProvider);
                final tg = TelegramStorageService(auth);
                ref.read(dlManagerProvider.notifier).downloadCloudFile(file, tg);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Row(children: [
                      const Icon(Icons.download_rounded, color: Colors.white, size: 16),
                      const SizedBox(width: 8),
                      Expanded(child: Text('Downloading ${file.name}…', maxLines: 1, overflow: TextOverflow.ellipsis)),
                    ]),
                    backgroundColor: AppTheme.primary,
                    duration: const Duration(seconds: 5),
                    action: SnackBarAction(
                      label: 'View',
                      textColor: Colors.white,
                      onPressed: () {
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        // Set jump signal FIRST, then switch tab — so when
                        // DownloadManagerPage builds, initState already reads true
                        ref.read(dlManagerJumpToActiveProvider.notifier).state = true;
                        ref.read(homeNavIndexProvider.notifier).state = 3;
                      },
                    ),
                  ),
                );
              },
            ),
            ListTile(leading: Icon(file.isStarred ? Icons.star_border_rounded : Icons.star_rounded, color: AppTheme.warning), title: Text(file.isStarred ? 'Remove Star' : 'Star'), onTap: () { Navigator.pop(context); ref.read(driveProvider.notifier).toggleStar(file); }),
            ListTile(leading: const Icon(Icons.share_rounded, color: AppTheme.accent), title: const Text('Share'), onTap: () { Navigator.pop(context); }),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline_rounded),
              title: const Text('Rename'),
              onTap: () {
                Navigator.pop(context);
                _showRenameDialog(context, file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_rounded, color: AppTheme.secondary),
              title: const Text('Move to Folder'),
              onTap: () {
                Navigator.pop(context);
                _showFolderPicker(context, mode: 'move');
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded, color: AppTheme.accent),
              title: const Text('Copy to Folder'),
              onTap: () {
                Navigator.pop(context);
                _showFolderPicker(context, mode: 'copy');
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_forever_rounded, color: AppTheme.error),
              title: const Text('Delete Permanently', style: TextStyle(color: AppTheme.error)),
              onTap: () {
                Navigator.pop(context);
                _confirmDelete(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
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
              // Run delete without awaiting to avoid using stale context
              ref.read(driveProvider.notifier).deleteFile(file);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showRenameDialog(BuildContext context, CloudFile file) {
    final ctrl = TextEditingController(text: file.name);
    // Capture the outer scaffold context before opening the dialog
    final outerCtx = context;
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.drive_file_rename_outline_rounded, color: AppTheme.primary, size: 20),
          ),
          const SizedBox(width: 10),
          const Text('Rename File'),
        ]),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'New file name',
            prefixIcon: Icon(Icons.edit_rounded, color: AppTheme.textHint),
          ),
          onSubmitted: (_) => _doRename(dialogCtx, outerCtx, file, ctrl.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => _doRename(dialogCtx, outerCtx, file, ctrl.text.trim()),
            child: const Text('Rename', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    ).whenComplete(() => ctrl.dispose());
  }

  Future<void> _doRename(BuildContext dialogCtx, BuildContext scaffoldCtx, CloudFile file, String newName) async {
    if (newName.isEmpty || newName == file.name) {
      Navigator.pop(dialogCtx);
      return;
    }
    Navigator.pop(dialogCtx);
    // Capture messenger before async gap to avoid BuildContext-across-async warning
    final messenger = ScaffoldMessenger.of(scaffoldCtx);
    try {
      await ref.read(driveProvider.notifier).renameFile(file, newName);
      messenger.showSnackBar(SnackBar(
        content: Text('Renamed to "$newName"'),
        backgroundColor: AppTheme.success,
        duration: const Duration(seconds: 3),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Rename failed: $e'),
        backgroundColor: AppTheme.error,
      ));
    }
  }

  void _showFolderPicker(BuildContext context, {required String mode}) {
    showDialog(
      context: context,
      builder: (_) => _FolderPickerDialog(
        file: file,
        ref: ref,
        mode: mode,
      ),
    );
  }
}

// ── Multi File Options Sheet (stunning design, shown when ≥2 files selected) ──

class _MultiFileOptionsSheet extends ConsumerWidget {
  final List<CloudFile> selectedFiles;
  final BuildContext outerScaffoldContext;

  const _MultiFileOptionsSheet({
    required this.selectedFiles,
    required this.outerScaffoldContext,
  });

  void _queueDownloads(WidgetRef ref) {
    final auth = ref.read(telegramAuthServiceProvider);
    final tg = TelegramStorageService(auth);
    for (final f in selectedFiles) {
      ref.read(dlManagerProvider.notifier).downloadCloudFile(f, tg);
    }
    ref.read(driveProvider.notifier).clearSelection();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = selectedFiles.length;
    final allStarred = selectedFiles.every((f) => f.isStarred);

    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [

          // ── Drag handle ──────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: AppTheme.cardBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // ── Gradient header ───────────────────────────────────────────────────
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  AppTheme.primary.withValues(alpha: 0.18),
                  const Color(0xFF6C3FFF).withValues(alpha: 0.12),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
            ),
            child: Row(children: [
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  gradient: AppTheme.primaryGradient,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [BoxShadow(color: AppTheme.primary.withValues(alpha: 0.4), blurRadius: 10, offset: const Offset(0, 4))],
                ),
                child: const Icon(Icons.checklist_rounded, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  '$count File${count == 1 ? '' : 's'} Selected',
                  style: AppTheme.titleMedium.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
                ),
                Text(
                  'Choose an action to apply to all',
                  style: AppTheme.bodyMedium.copyWith(color: AppTheme.textSecondary, fontSize: 11),
                ),
              ])),
            ]),
          ),

          const SizedBox(height: 16),

          // ── Quick action icon buttons row ─────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _QuickAction(
                  icon: Icons.download_rounded,
                  label: 'Download',
                  gradient: const LinearGradient(colors: [Color(0xFF4F8CFF), Color(0xFF6C3FFF)]),
                  onTap: () {
                    Navigator.pop(context);
                    _queueDownloads(ref);
                    ScaffoldMessenger.of(outerScaffoldContext).showSnackBar(SnackBar(
                      content: Row(children: [
                        const Icon(Icons.download_rounded, color: Colors.white, size: 16),
                        const SizedBox(width: 8),
                        Text('Queued $count file${count == 1 ? '' : 's'} for download'),
                      ]),
                      backgroundColor: AppTheme.primary,
                      duration: const Duration(seconds: 4),
                      action: SnackBarAction(
                        label: 'View',
                        textColor: Colors.white,
                        onPressed: () {
                          ScaffoldMessenger.of(outerScaffoldContext).hideCurrentSnackBar();
                          ref.read(homeNavIndexProvider.notifier).state = 3;
                        },
                      ),
                    ));
                  },
                ),
                _QuickAction(
                  icon: allStarred ? Icons.star_border_rounded : Icons.star_rounded,
                  label: allStarred ? 'Unstar' : 'Star',
                  gradient: const LinearGradient(colors: [Color(0xFFFFB800), Color(0xFFFF6B00)]),
                  onTap: () {
                    Navigator.pop(context);
                    for (final f in selectedFiles) {
                      if (f.isStarred == allStarred) {
                        ref.read(driveProvider.notifier).toggleStar(f);
                      }
                    }
                    ref.read(driveProvider.notifier).clearSelection();
                  },
                ),
                _QuickAction(
                  icon: Icons.drive_file_move_rounded,
                  label: 'Move',
                  gradient: const LinearGradient(colors: [Color(0xFF00C8A0), Color(0xFF00A0C8)]),
                  onTap: () {
                    Navigator.pop(context);
                    showDialog(
                      context: outerScaffoldContext,
                      builder: (_) => _MultiFolderPickerDialog(files: selectedFiles, ref: ref, mode: 'move'),
                    );
                  },
                ),
                _QuickAction(
                  icon: Icons.copy_rounded,
                  label: 'Copy',
                  gradient: const LinearGradient(colors: [Color(0xFFFF6CC8), Color(0xFFAA4FFF)]),
                  onTap: () {
                    Navigator.pop(context);
                    showDialog(
                      context: outerScaffoldContext,
                      builder: (_) => _MultiFolderPickerDialog(files: selectedFiles, ref: ref, mode: 'copy'),
                    );
                  },
                ),
                _QuickAction(
                  icon: Icons.delete_forever_rounded,
                  label: 'Delete',
                  gradient: const LinearGradient(colors: [Color(0xFFFF4F4F), Color(0xFFCC1111)]),
                  onTap: () {
                    Navigator.pop(context);
                    showDialog(
                      context: outerScaffoldContext,
                      builder: (dialogCtx) => AlertDialog(
                        backgroundColor: AppTheme.surface,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        title: Row(children: [
                          Container(
                            width: 36, height: 36,
                            decoration: BoxDecoration(color: AppTheme.error.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
                            child: const Icon(Icons.delete_forever_rounded, color: AppTheme.error, size: 20),
                          ),
                          const SizedBox(width: 10),
                          const Text('Delete Files'),
                        ]),
                        content: Text(
                          'Permanently delete $count file${count == 1 ? '' : 's'}?\nThis will remove them from Telegram and cannot be undone.',
                          style: AppTheme.bodyMedium.copyWith(height: 1.5),
                        ),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Cancel')),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.error,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: () async {
                              Navigator.pop(dialogCtx);
                              for (final f in selectedFiles) {
                                await ref.read(driveProvider.notifier).deleteFile(f);
                              }
                              ref.read(driveProvider.notifier).clearSelection();
                            },
                            child: const Text('Delete All', style: TextStyle(color: Colors.white)),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // ── Divider ───────────────────────────────────────────────────────────
          const Divider(height: 1, color: AppTheme.cardBorder, indent: 16, endIndent: 16),
          const SizedBox(height: 4),

          // ── Cancel ────────────────────────────────────────────────────────────
          ListTile(
            leading: Container(
              width: 38, height: 38,
              decoration: BoxDecoration(
                color: AppTheme.textHint.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.close_rounded, color: AppTheme.textSecondary, size: 20),
            ),
            title: const Text('Cancel Selection', style: TextStyle(color: AppTheme.textSecondary)),
            onTap: () {
              Navigator.pop(context);
              ref.read(driveProvider.notifier).clearSelection();
            },
          ),
          const SizedBox(height: 4),
        ]),
      ),
    );
  }
}

// ── Quick Action Icon Button ──────────────────────────────────────────────────

class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Gradient gradient;
  final VoidCallback onTap;

  const _QuickAction({
    required this.icon,
    required this.label,
    required this.gradient,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 56, height: 56,
          decoration: BoxDecoration(
            gradient: gradient,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: (gradient as LinearGradient).colors.first.withValues(alpha: 0.35),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Icon(icon, color: Colors.white, size: 26),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11, fontWeight: FontWeight.w500),
        ),
      ]),
    );
  }
}

// ── Persistent Selection Action Bar ─────────────────────────────────────────
// Slides up from the bottom whenever isSelectionMode is true.
// Shows: count badge | Download | Star | Move | Copy | Delete | Close

class _SelectionActionBar extends StatelessWidget {
  final int selectedCount;
  final void Function(String action) onAction;
  final VoidCallback onClearSelection;

  const _SelectionActionBar({
    required this.selectedCount,
    required this.onAction,
    required this.onClearSelection,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Container(
          height: 62,
          decoration: BoxDecoration(
            color: const Color(0xFF1A1E2E).withValues(alpha: 0.97),
            borderRadius: BorderRadius.circular(32),
            border: Border.all(
              color: AppTheme.primary.withValues(alpha: 0.35),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: AppTheme.primary.withValues(alpha: 0.18),
                blurRadius: 24,
                spreadRadius: 0,
                offset: const Offset(0, 4),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            children: [
              // ── Count badge ──────────────────────────────────────────
              const SizedBox(width: 14),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  gradient: AppTheme.primaryGradient,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$selectedCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const Spacer(),

              // ── Action buttons ────────────────────────────────────────
              _CompactActionBtn(
                icon: Icons.download_rounded,
                color: const Color(0xFF4F8CFF),
                tooltip: 'Download',
                onTap: () => onAction('download'),
              ),
              _CompactActionBtn(
                icon: Icons.star_rounded,
                color: const Color(0xFFFFB800),
                tooltip: 'Star',
                onTap: () => onAction('star'),
              ),
              _CompactActionBtn(
                icon: Icons.drive_file_move_rounded,
                color: const Color(0xFF00C8A0),
                tooltip: 'Move',
                onTap: () => onAction('move'),
              ),
              _CompactActionBtn(
                icon: Icons.copy_rounded,
                color: const Color(0xFFD16FFF),
                tooltip: 'Copy',
                onTap: () => onAction('copy'),
              ),
              _CompactActionBtn(
                icon: Icons.delete_forever_rounded,
                color: const Color(0xFFFF4F4F),
                tooltip: 'Delete',
                onTap: () => onAction('delete'),
              ),

              // ── Close ─────────────────────────────────────────────────
              const SizedBox(width: 4),
              GestureDetector(
                onTap: onClearSelection,
                child: Container(
                  width: 30, height: 30,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close_rounded, color: AppTheme.textSecondary, size: 16),
                ),
              ),
              const SizedBox(width: 10),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactActionBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;

  const _CompactActionBtn({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40, height: 40,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            shape: BoxShape.circle,
            border: Border.all(color: color.withValues(alpha: 0.3), width: 1),
          ),
          child: Icon(icon, color: color, size: 19),
        ),
      ),
    );
  }
}

// ── Multi Folder Picker Dialog (Move/Copy for multiple files) ─────────────────


class _MultiFolderPickerDialog extends ConsumerStatefulWidget {
  final List<CloudFile> files;
  final WidgetRef ref;
  final String mode;
  const _MultiFolderPickerDialog({required this.files, required this.ref, required this.mode});

  @override
  ConsumerState<_MultiFolderPickerDialog> createState() => _MultiFolderPickerDialogState();
}

class _MultiFolderPickerDialogState extends ConsumerState<_MultiFolderPickerDialog> {
  final List<CloudFolder?> _navStack = [null];
  List<CloudFolder> _subfolders = [];
  bool _loadingSubfolders = true;
  bool _busy = false;

  CloudFolder? get _currentFolder => _navStack.last;

  @override
  void initState() { super.initState(); _loadSubfolders(); }

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
      final folders = await service.getFolders(userId: userId, parentFolderId: _currentFolder?.id).first;
      if (mounted) setState(() { _subfolders = folders; _loadingSubfolders = false; });
    } catch (_) {
      if (mounted) setState(() { _subfolders = []; _loadingSubfolders = false; });
    }
  }

  void _enterFolder(CloudFolder f) { _navStack.add(f); _loadSubfolders(); }
  void _goUp() { if (_navStack.length > 1) { _navStack.removeLast(); _loadSubfolders(); } }

  String get _breadcrumb => _navStack.length == 1 ? 'My Drive' : _navStack.skip(1).map((f) => f!.name).join(' / ');

  @override
  Widget build(BuildContext context) {
    final isMove = widget.mode == 'move';
    final accent = isMove ? AppTheme.secondary : AppTheme.accent;
    final count = widget.files.length;

    return Dialog(
      backgroundColor: AppTheme.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 14),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.07),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(isMove ? Icons.drive_file_move_rounded : Icons.copy_rounded, color: accent, size: 22),
              const SizedBox(width: 10),
              Text(isMove ? 'Move $count Files' : 'Copy $count Files',
                  style: AppTheme.titleMedium.copyWith(color: accent)),
            ]),
            const SizedBox(height: 4),
            Text('Select destination folder', style: AppTheme.bodyMedium.copyWith(color: AppTheme.textSecondary)),
          ]),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.cardBorder, width: 0.5))),
          child: Row(children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
              onPressed: _navStack.length > 1 ? _goUp : null,
              color: _navStack.length > 1 ? AppTheme.textPrimary : AppTheme.textHint,
              padding: const EdgeInsets.all(6),
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 6),
            Expanded(child: Text(_breadcrumb, style: AppTheme.bodyMedium.copyWith(fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis)),
          ]),
        ),
        SizedBox(
          height: 270,
          child: _loadingSubfolders
              ? const Center(child: CircularProgressIndicator())
              : _subfolders.isEmpty
                  ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const Icon(Icons.folder_open_rounded, size: 42, color: AppTheme.textHint),
                      const SizedBox(height: 8),
                      Text('No subfolders here', style: AppTheme.bodyMedium.copyWith(color: AppTheme.textHint)),
                    ]))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: _subfolders.length,
                      itemBuilder: (_, i) {
                        final f = _subfolders[i];
                        return ListTile(
                          leading: Container(
                            width: 40, height: 40,
                            decoration: BoxDecoration(color: const Color(0xFF4F8CFF).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                            child: const Icon(Icons.folder_rounded, color: Color(0xFF4F8CFF), size: 22),
                          ),
                          title: Text(f.name, style: AppTheme.bodyMedium.copyWith(fontWeight: FontWeight.w600)),
                          subtitle: Text('${f.itemCount} item${f.itemCount == 1 ? '' : 's'}', style: const TextStyle(fontSize: 11)),
                          trailing: const Icon(Icons.chevron_right_rounded, color: AppTheme.textSecondary),
                          onTap: () => _enterFolder(f),
                        );
                      },
                    ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppTheme.cardBorder, width: 0.5)),
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(20)),
          ),
          child: Row(children: [
            TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
            const Spacer(),
            if (_busy) const Padding(padding: EdgeInsets.only(right: 10), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
              ),
              icon: Icon(isMove ? Icons.drive_file_move_rounded : Icons.copy_rounded, size: 18),
              label: Text(isMove ? 'Move Here' : 'Copy Here', style: const TextStyle(fontWeight: FontWeight.w600)),
              onPressed: _busy ? null : _executeHere,
            ),
          ]),
        ),
      ]),
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
        id: destId ?? '', name: destName,
        parentFolderId: destination?.parentFolderId, path: destPath,
        color: destination?.color ?? '#4F8CFF',
        metaMessageId: destination?.metaMessageId ?? 0,
        createdAt: destination?.createdAt ?? DateTime.now(),
        updatedAt: destination?.updatedAt ?? DateTime.now(),
      );

      for (final file in widget.files) {
        if (widget.mode == 'move') {
          await widget.ref.read(driveProvider.notifier).moveFile(file, destFolder);
        } else {
          await widget.ref.read(driveProvider.notifier).copyFile(file, destFolder);
        }
      }
      widget.ref.read(driveProvider.notifier).clearSelection();

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(widget.mode == 'move'
              ? '${widget.files.length} files moved to $destName'
              : '${widget.files.length} files copied to $destName'),
          backgroundColor: widget.mode == 'move' ? AppTheme.secondary : AppTheme.accent,
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

// ── Folder Picker Dialog (for Move / Copy) ────────────────────────────────────

class _FolderPickerDialog extends ConsumerStatefulWidget {
  final CloudFile file;
  final WidgetRef ref;
  final String mode; // 'move' or 'copy'
  const _FolderPickerDialog({required this.file, required this.ref, required this.mode});

  @override
  ConsumerState<_FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends ConsumerState<_FolderPickerDialog> {
  // Navigation stack â€” null means "My Drive (root)"
  final List<CloudFolder?> _navStack = [null];
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

          // â”€â”€ Header â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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

          // â”€â”€ Navigation bar (back + breadcrumb) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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

          // â”€â”€ Folder list â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
          SizedBox(
            height: 270,
            child: _loadingSubfolders
                ? const Center(child: CircularProgressIndicator())
                : _subfolders.isEmpty
                    ? Center(
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          const Icon(Icons.folder_open_rounded,
                              size: 42, color: AppTheme.textHint),
                          const SizedBox(height: 8),
                          Text('No subfolders here',
                              style: AppTheme.bodyMedium.copyWith(color: AppTheme.textHint)),
                          if (_isCurrentFileLocation)
                            Text('Current file location',
                                style: AppTheme.bodyMedium.copyWith(
                                    color: AppTheme.textHint, fontSize: 11)),
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
                                style: AppTheme.bodyMedium
                                    .copyWith(fontWeight: FontWeight.w600)),
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

          // â”€â”€ Action bar â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
                  backgroundColor:
                      _isCurrentFileLocation ? AppTheme.surfaceVariant : accent,
                  foregroundColor:
                      _isCurrentFileLocation ? AppTheme.textHint : Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
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

