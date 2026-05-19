import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../core/constants/app_routes.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/file_utils.dart';
import '../../data/models/cloud_file.dart';
import '../../data/models/cloud_folder.dart';
import '../../data/firestore_metadata_service.dart';
import '../providers/drive_provider.dart';
import '../widgets/file_grid_item.dart';
import '../widgets/file_list_item.dart';
import '../widgets/folder_item.dart';
import './download_manager_page.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});
  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  int _navIndex = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      const _DriveTab(),
      const _StarredTab(),
      const _CategoriesTab(),
      const _DownloadsTab(),
    ];

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: pages[_navIndex],
      floatingActionButton: _navIndex == 0 ? _buildFAB(context) : null,
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildFAB(BuildContext context) {
    return FloatingActionButton.extended(
      onPressed: () => _showUploadOptions(context),
      backgroundColor: AppTheme.primary,
      icon: const Icon(Icons.add_rounded),
      label: const Text('New', style: TextStyle(fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        border: Border(top: BorderSide(color: AppTheme.cardBorder)),
      ),
      child: BottomNavigationBar(
        currentIndex: _navIndex,
        onTap: (i) => setState(() => _navIndex = i),
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

// ── Drive Tab ─────────────────────────────────────────────────────────────────

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
        // ── App Bar ────────────────────────────────────────────────────────
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

        // ── Upload Progress ────────────────────────────────────────────────
        if (drive.uploadTasks.isNotEmpty)
          SliverToBoxAdapter(
            child: Column(
              children: drive.uploadTasks.map((task) => _UploadTaskTile(task: task)).toList(),
            ),
          ),

        // ── Storage Banner ────────────────────────────────────────────────
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

        // ── Folders ───────────────────────────────────────────────────────
        foldersAsync.when(
          data: (folders) => folders.isEmpty ? const SliverToBoxAdapter(child: SizedBox.shrink()) : _buildFoldersSection(context, ref, folders, drive.isGridView),
          loading: () => const SliverToBoxAdapter(child: LinearProgressIndicator()),
          error: (e, _) => SliverToBoxAdapter(child: Text('$e')),
        ),

        // ── Files ─────────────────────────────────────────────────────────
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

        const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
      ],
    ),
        // ── Sync banner ────────────────────────────────────────────────────
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
    final sessionAsync = ref.watch(sessionProvider);
    final session = sessionAsync.valueOrNull ?? '';
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
              sessionString: session,
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

  void _showFileOptions(BuildContext context, WidgetRef ref, CloudFile file) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => _FileOptionsSheet(file: file, ref: ref),
    );
  }
}

// ── Starred Tab ───────────────────────────────────────────────────────────────

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

// ── Categories Tab ────────────────────────────────────────────────────────────

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
            // ── Stats header + view toggle ─────────────────────────────────
            Container(
              margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
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

            // ── File list or image grid ────────────────────────────────────
            Expanded(
              child: widget.category == FileCategory.images && _isGridView
                  ? _ImageGalleryGrid(files: files, accentColor: widget.accentColor)
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 80),
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
            ),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
    );
  }
}

// ── Image Gallery Grid ────────────────────────────────────────────────────────

const _imageExts = {
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'avif'
};

class _ImageGalleryGrid extends ConsumerWidget {
  final List<CloudFile> files;
  final Color accentColor;
  const _ImageGalleryGrid({required this.files, required this.accentColor});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionAsync = ref.watch(sessionProvider);
    final session = sessionAsync.valueOrNull ?? '';
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
          onTap: () => Navigator.pushNamed(context, AppRoutes.imageViewer, arguments: {'file': f}),
          child: _GalleryThumbnail(file: f, session: session),
        );
      },
    );
  }
}

class _GalleryThumbnail extends StatelessWidget {
  final CloudFile file;
  final String session;
  const _GalleryThumbnail({required this.file, required this.session});

  String? get _streamUrl {
    if (session.isEmpty) return null;
    final encoded = Uri.encodeQueryComponent(session);
    return '${AppConstants.backendBaseUrl}/files/download'
        '/${file.telegramMessageId}?session_string=$encoded';
  }

  @override
  Widget build(BuildContext context) {
    final color = FileUtils.getFileColor(file.extension);
    final url = _streamUrl;

    Widget content;
    if (url != null) {
      content = CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        memCacheWidth: 300,
        placeholder: (_, __) => _imgPlaceholder(color),
        errorWidget: (_, __, ___) => _imgPlaceholder(color),
      );
    } else {
      content = _imgPlaceholder(color);
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          content,
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

// ── Downloads Tab ─────────────────────────────────────────────────────────────

class _DownloadsTab extends StatelessWidget {
  const _DownloadsTab();
  @override
  Widget build(BuildContext context) {
    return const DownloadManagerPage();
  }
}


// ── Helper Widgets ────────────────────────────────────────────────────────────

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
                  'Used: ${FileUtils.formatFileSize(usedBytes)} · Powered by Telegram',
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
            child: Text('∞', style: AppTheme.headlineMedium.copyWith(color: AppTheme.primary)),
          ),
        ],
      ),
    );
  }
}

class _UploadTaskTile extends StatelessWidget {
  final UploadTask task;
  const _UploadTaskTile({required this.task});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.upload_rounded, color: AppTheme.primary, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(task.fileName, style: AppTheme.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis)),
              Text('${(task.progress * 100).toInt()}%', style: AppTheme.labelLarge.copyWith(color: AppTheme.primary)),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: task.progress,
            backgroundColor: AppTheme.surfaceVariant,
            valueColor: const AlwaysStoppedAnimation(AppTheme.primary),
            borderRadius: BorderRadius.circular(4),
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
            ListTile(leading: const Icon(Icons.delete_outline_rounded, color: AppTheme.error), title: const Text('Move to Trash', style: TextStyle(color: AppTheme.error)), onTap: () { Navigator.pop(context); ref.read(driveProvider.notifier).trashFolder(folder.id); }),
          ],
        ),
      ),
    );
  }

  void _rename(BuildContext context) {
    final ctrl = TextEditingController(text: folder.name);
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: AppTheme.surface,
      title: const Text('Rename Folder'),
      content: TextField(controller: ctrl, autofocus: true, style: AppTheme.bodyLarge, decoration: const InputDecoration(hintText: 'Folder name')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(onPressed: () { ref.read(driveProvider.notifier).renameFolder(folder.id, ctrl.text.trim()); Navigator.pop(context); }, child: const Text('Rename')),
      ],
    ));
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
            ListTile(leading: const Icon(Icons.download_rounded, color: AppTheme.primary), title: const Text('Download'), onTap: () { Navigator.pop(context); ref.read(driveProvider.notifier).downloadFile(file, onProgress: (_) {}); }),
            ListTile(leading: Icon(file.isStarred ? Icons.star_border_rounded : Icons.star_rounded, color: AppTheme.warning), title: Text(file.isStarred ? 'Remove Star' : 'Star'), onTap: () { Navigator.pop(context); ref.read(driveProvider.notifier).toggleStar(file); }),
            ListTile(leading: const Icon(Icons.share_rounded, color: AppTheme.accent), title: const Text('Share'), onTap: () { Navigator.pop(context); }),
            ListTile(leading: const Icon(Icons.drive_file_rename_outline_rounded), title: const Text('Rename'), onTap: () { Navigator.pop(context); }),
            ListTile(leading: const Icon(Icons.delete_outline_rounded, color: AppTheme.error), title: const Text('Move to Trash', style: TextStyle(color: AppTheme.error)), onTap: () { Navigator.pop(context); ref.read(driveProvider.notifier).trashFile(file); }),
          ],
        ),
      ),
    );
  }
}
