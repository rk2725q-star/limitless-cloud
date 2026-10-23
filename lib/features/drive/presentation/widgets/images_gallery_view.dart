import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../core/constants/app_routes.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/date_utils.dart';
import '../../../../core/utils/file_utils.dart';
import '../../../../core/services/face_detection_service.dart';
import '../../../../core/services/tdlib_service.dart';
import '../../../auth/data/telegram_auth_service.dart';
import '../../data/firestore_metadata_service.dart';
import '../../data/models/cloud_file.dart';
import '../../data/models/cloud_folder.dart';
import '../../data/telegram_storage_service.dart';
import '../pages/camera_capture_page.dart';
import '../pages/download_manager_page.dart';
import '../providers/drive_provider.dart';

const _imageExtensions = {
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'avif'
};

enum _ImagesMode { timeline, albums }

class ImagesGalleryView extends ConsumerStatefulWidget {
  final Color accentColor;
  final IconData icon;

  const ImagesGalleryView({
    super.key,
    required this.accentColor,
    required this.icon,
  });

  @override
  ConsumerState<ImagesGalleryView> createState() => _ImagesGalleryViewState();
}

class _ImagesGalleryViewState extends ConsumerState<ImagesGalleryView> {
  _ImagesMode _mode = _ImagesMode.timeline;

  // Face filter
  String? _selectedPersonId;

  // Date filters
  String? _selectedYear;
  String? _selectedMonth;

  // Search
  bool _showSearchBar = false;
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';

  // Folder navigation stack for Albums mode
  final List<CloudFolder> _folderStack = [];
  CloudFolder? get _currentFolder => _folderStack.isEmpty ? null : _folderStack.last;

  String? _userId;
  final Set<String> _newlyCreatedFolderIds = {};

  int _countImagesInFolder(CloudFolder folder, List<CloudFile> allImages) {
    return allImages.where((f) {
      if (f.folderId != null && f.folderId == folder.id) return true;
      if (f.folderPath.isNotEmpty) {
        if (f.folderPath == folder.path) return true;
        if (folder.path.isNotEmpty && folder.path != '/' && f.folderPath.startsWith(folder.path)) return true;
        if (f.folderPath == '/${folder.name}' ||
            f.folderPath == '/${folder.name}/' ||
            f.folderPath.startsWith('/${folder.name}/')) {
          return true;
        }
      }
      return false;
    }).length;
  }

  bool _isImageFolder(CloudFolder folder, List<CloudFile> allImages) {
    if (_newlyCreatedFolderIds.contains(folder.id) || _newlyCreatedFolderIds.contains(folder.name)) {
      return true;
    }
    return _countImagesInFolder(folder, allImages) > 0;
  }

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadUser() async {
    final authService = ref.read(telegramAuthServiceProvider);
    final profile = await authService.getProfile();
    final uid = profile['userId'];
    if (mounted && uid != null && uid.isNotEmpty) {
      setState(() => _userId = uid);
    }
  }

  void _triggerFaceScanning(List<CloudFile> files) {
    final uid = _userId;
    if (uid != null && uid.isNotEmpty) {
      FaceDetectionService.instance.batchScanImages(uid, files);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filesAsync = ref.watch(filesByCategoryProvider(FileCategory.images));

    return filesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e', style: AppTheme.bodyMedium)),
      data: (allImages) {
        final activeFileIds = allImages.map((f) => f.id).toSet();
        if (_userId != null) {
          FaceDetectionService.instance.purgeOrphanedPeople(_userId!, activeFileIds);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _triggerFaceScanning(allImages);
          });
        }

        return Column(
          children: [
            _buildTopModeBar(allImages),
            if (_mode == _ImagesMode.timeline)
              Expanded(child: _buildTimelineContent(allImages))
            else
              Expanded(child: _buildAlbumsContent(allImages)),
          ],
        );
      },
    );
  }

  // ── Top Mode Selector (Timeline vs Albums) ───────────────────────────────────

  Widget _buildTopModeBar(List<CloudFile> allImages) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ModePill(
              icon: Icons.auto_awesome_mosaic_rounded,
              label: 'Timeline',
              count: allImages.length,
              isSelected: _mode == _ImagesMode.timeline,
              accentColor: widget.accentColor,
              onTap: () => setState(() => _mode = _ImagesMode.timeline),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _ModePill(
              icon: Icons.folder_copy_rounded,
              label: 'Folders & Albums',
              isSelected: _mode == _ImagesMode.albums,
              accentColor: AppTheme.folderColor,
              onTap: () => setState(() => _mode = _ImagesMode.albums),
            ),
          ),
        ],
      ),
    );
  }

  // ═════════════════════════════════════════════════════════════════════════════
  // ── TIMELINE MODE ────────────────────────────────────────────────────────────
  // ═════════════════════════════════════════════════════════════════════════════

  Widget _buildTimelineContent(List<CloudFile> allImages) {
    final activeFileIds = allImages.map((f) => f.id).toSet();

    // 1. Filter by Person
    List<CloudFile> filtered = allImages;
    if (_selectedPersonId != null && _userId != null) {
      final people = FaceDetectionService.instance.getCachedPeople(_userId!, activeFileIds);
      final personIdx = people.indexWhere((p) => p.id == _selectedPersonId);
      if (personIdx == -1) {
        _selectedPersonId = null;
      } else {
        final person = people[personIdx];
        filtered = filtered.where((f) => person.fileIds.contains(f.id)).toList();
      }
    }

    // 2. Filter by Year
    if (_selectedYear != null) {
      filtered = filtered.where((f) => AppDateUtils.getYear(f.uploadedAt) == _selectedYear).toList();
    }

    // 3. Filter by Month
    if (_selectedMonth != null) {
      filtered = filtered.where((f) => AppDateUtils.getMonthYear(f.uploadedAt).startsWith(_selectedMonth!)).toList();
    }

    // 4. Filter by Search Query
    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.trim().toLowerCase();
      filtered = filtered.where((f) {
        final name = f.name.toLowerCase();
        final year = AppDateUtils.getYear(f.uploadedAt);
        final month = AppDateUtils.getMonthYear(f.uploadedAt).toLowerCase();
        final date = AppDateUtils.formatDate(f.uploadedAt).toLowerCase();
        return name.contains(q) || year.contains(q) || month.contains(q) || date.contains(q);
      }).toList();
    }

    // Group files by day for neat date/time organization
    final dayGroups = <String, List<CloudFile>>{};
    for (final f in filtered) {
      final key = '${f.uploadedAt.year}-${f.uploadedAt.month.toString().padLeft(2, '0')}-${f.uploadedAt.day.toString().padLeft(2, '0')}';
      dayGroups.putIfAbsent(key, () => []).add(f);
    }

    // Sort days descending (most recent first)
    final sortedDayKeys = dayGroups.keys.toList()..sort((a, b) => b.compareTo(a));

    return Column(
      children: [
        // ── People & Faces Row (Google Photos Style) ─────────────────────────
        _buildPeopleFaceSuggestions(allImages, activeFileIds),

        // ── Date Filters & Search Row ────────────────────────────────────────
        _buildDateFilterBar(allImages),

        // ── Filter info banner if active ─────────────────────────────────────
        if (_selectedPersonId != null || _selectedYear != null || _selectedMonth != null || _searchQuery.isNotEmpty)
          _buildActiveFilterBanner(filtered.length, activeFileIds),

        // ── Empty State or Day Groups Stream ─────────────────────────────────
        Expanded(
          child: filtered.isEmpty
              ? _buildEmptyState('No images matching your filters')
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 90),
                  itemCount: sortedDayKeys.length,
                  itemBuilder: (context, idx) {
                    final dayKey = sortedDayKeys[idx];
                    final dayFiles = dayGroups[dayKey]!;
                    final firstFile = dayFiles.first;

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Day Header with Date & Year & Photo Count
                        Padding(
                          padding: const EdgeInsets.only(top: 14, bottom: 8, left: 4, right: 4),
                          child: Row(
                            children: [
                              Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  color: widget.accentColor.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Icon(Icons.calendar_today_rounded, size: 12, color: widget.accentColor),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  AppDateUtils.getTimelineHeader(firstFile.uploadedAt),
                                  style: AppTheme.titleMedium.copyWith(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ),
                              Text(
                                '${dayFiles.length} ${dayFiles.length == 1 ? 'photo' : 'photos'}',
                                style: AppTheme.bodyMedium.copyWith(fontSize: 11, color: AppTheme.textSecondary),
                              ),
                            ],
                          ),
                        ),

                        // 3-Column Grid for this day
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 4,
                            mainAxisSpacing: 4,
                          ),
                          itemCount: dayFiles.length,
                          itemBuilder: (_, fileIdx) {
                            final f = dayFiles[fileIdx];
                            return _ImageTile(
                              file: f,
                              allImages: filtered,
                              accentColor: widget.accentColor,
                              onMoreTap: () => _showFileOptions(context, f),
                            );
                          },
                        ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ── People & Faces Row (Google Photos Style) ─────────────────────────────────

  Widget _buildPeopleFaceSuggestions(List<CloudFile> allImages, Set<String> activeFileIds) {
    if (_userId == null) return const SizedBox.shrink();

    return ListenableBuilder(
      listenable: FaceDetectionService.instance,
      builder: (context, _) {
        final people = FaceDetectionService.instance.getCachedPeople(_userId!, activeFileIds);
        final isScanning = FaceDetectionService.instance.isScanning;

        // If no people with existing photos, hide completely
        if (people.isEmpty) {
          return const SizedBox.shrink();
        }

        // Auto-deselect if selected person was deleted
        if (_selectedPersonId != null && !people.any((p) => p.id == _selectedPersonId)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _selectedPersonId = null);
          });
        }

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.face_retouching_natural_rounded, color: widget.accentColor, size: 16),
                  const SizedBox(width: 6),
                  const Text(
                    'People & Faces',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: widget.accentColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${people.length}',
                      style: TextStyle(color: widget.accentColor, fontSize: 11, fontWeight: FontWeight.w700),
                    ),
                  ),
                  const Spacer(),
                  if (isScanning)
                    Row(
                      children: [
                        SizedBox(
                          width: 11,
                          height: 11,
                          child: CircularProgressIndicator(strokeWidth: 1.5, color: widget.accentColor),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          'Detecting faces…',
                          style: TextStyle(color: widget.accentColor, fontSize: 11),
                        ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 86,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: 1 + people.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      // "All" chip
                      final isAll = _selectedPersonId == null;
                      return GestureDetector(
                        onTap: () => setState(() => _selectedPersonId = null),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              width: 50,
                              height: 50,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isAll ? widget.accentColor : AppTheme.card,
                                border: Border.all(
                                  color: isAll ? Colors.white : AppTheme.cardBorder,
                                  width: isAll ? 2.5 : 1,
                                ),
                                boxShadow: isAll
                                    ? [
                                        BoxShadow(
                                          color: widget.accentColor.withValues(alpha: 0.4),
                                          blurRadius: 8,
                                          spreadRadius: 1,
                                        ),
                                      ]
                                    : null,
                              ),
                              child: Icon(
                                Icons.groups_rounded,
                                color: isAll ? Colors.white : AppTheme.textSecondary,
                                size: 24,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'All Photos',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: isAll ? FontWeight.w700 : FontWeight.w500,
                                color: isAll ? widget.accentColor : AppTheme.textSecondary,
                              ),
                            ),
                            Text(
                              '${allImages.length}',
                              style: const TextStyle(fontSize: 10, color: AppTheme.textHint),
                            ),
                          ],
                        ),
                      );
                    }

                    final person = people[i - 1];
                    final isSelected = _selectedPersonId == person.id;

                    return GestureDetector(
                      onTap: () {
                        setState(() {
                          _selectedPersonId = isSelected ? null : person.id;
                        });
                      },
                      onLongPress: () => _showRenamePersonDialog(person),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width: 50,
                            height: 50,
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isSelected ? widget.accentColor : AppTheme.cardBorder,
                                width: isSelected ? 2.5 : 1.2,
                              ),
                              boxShadow: isSelected
                                  ? [
                                      BoxShadow(
                                        color: widget.accentColor.withValues(alpha: 0.5),
                                        blurRadius: 10,
                                        spreadRadius: 1,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: ClipOval(
                              child: io.File(person.avatarPath).existsSync()
                                  ? Image.file(
                                      io.File(person.avatarPath),
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => Container(
                                        color: widget.accentColor.withValues(alpha: 0.2),
                                        child: Icon(Icons.person, color: widget.accentColor, size: 24),
                                      ),
                                    )
                                  : Container(
                                      color: widget.accentColor.withValues(alpha: 0.2),
                                      child: Icon(Icons.person, color: widget.accentColor, size: 24),
                                    ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          SizedBox(
                            width: 62,
                            child: Text(
                              person.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                                color: isSelected ? widget.accentColor : AppTheme.textPrimary,
                              ),
                            ),
                          ),
                          Builder(
                            builder: (_) {
                              final count = person.fileIds.where(activeFileIds.contains).length;
                              return Text(
                                '$count ${count == 1 ? 'photo' : 'photos'}',
                                style: const TextStyle(fontSize: 10, color: AppTheme.textHint),
                              );
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Date Filters (Year & Month) + Search Bar ─────────────────────────────────

  Widget _buildDateFilterBar(List<CloudFile> allImages) {
    // Extract unique years
    final years = allImages
        .map((f) => AppDateUtils.getYear(f.uploadedAt))
        .toSet()
        .toList()
      ..sort((a, b) => b.compareTo(a));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        children: [
          Row(
            children: [
              // Search toggle button
              GestureDetector(
                onTap: () => setState(() => _showSearchBar = !_showSearchBar),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: _showSearchBar ? widget.accentColor.withValues(alpha: 0.2) : AppTheme.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _showSearchBar ? widget.accentColor : AppTheme.cardBorder,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.search_rounded,
                        size: 16,
                        color: _showSearchBar ? widget.accentColor : AppTheme.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Search',
                        style: TextStyle(
                          fontSize: 12,
                          color: _showSearchBar ? widget.accentColor : AppTheme.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),

              // Horizontal Year chips
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      _FilterChip(
                        label: 'All Years',
                        isSelected: _selectedYear == null,
                        accentColor: widget.accentColor,
                        onTap: () {
                          setState(() {
                            _selectedYear = null;
                            _selectedMonth = null;
                          });
                        },
                      ),
                      ...years.map((y) => _FilterChip(
                            label: y,
                            isSelected: _selectedYear == y,
                            accentColor: widget.accentColor,
                            onTap: () {
                              setState(() {
                                _selectedYear = _selectedYear == y ? null : y;
                                _selectedMonth = null;
                              });
                            },
                          )),
                    ],
                  ),
                ),
              ),
            ],
          ),

          // If a year is selected: show Month chips
          if (_selectedYear != null) ...[
            const SizedBox(height: 6),
            SizedBox(
              height: 30,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _FilterChip(
                    label: 'All Months in $_selectedYear',
                    isSelected: _selectedMonth == null,
                    accentColor: widget.accentColor,
                    isSmall: true,
                    onTap: () => setState(() => _selectedMonth = null),
                  ),
                  ...[
                    'January', 'February', 'March', 'April', 'May', 'June',
                    'July', 'August', 'September', 'October', 'November', 'December'
                  ].map((m) => _FilterChip(
                        label: m,
                        isSelected: _selectedMonth == m,
                        accentColor: widget.accentColor,
                        isSmall: true,
                        onTap: () {
                          setState(() {
                            _selectedMonth = _selectedMonth == m ? null : m;
                          });
                        },
                      )),
                ],
              ),
            ),
          ],

          // Search input field
          if (_showSearchBar) ...[
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: widget.accentColor.withValues(alpha: 0.4)),
              ),
              child: TextField(
                controller: _searchCtrl,
                autofocus: true,
                style: AppTheme.bodyLarge,
                decoration: InputDecoration(
                  hintText: 'Search by date, month, year, or image name…',
                  hintStyle: const TextStyle(color: AppTheme.textHint, fontSize: 13),
                  prefixIcon: const Icon(Icons.search_rounded, size: 20, color: AppTheme.textSecondary),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
                onChanged: (val) => setState(() => _searchQuery = val),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Active Filter Banner ─────────────────────────────────────────────────────

  Widget _buildActiveFilterBanner(int resultCount, Set<String> activeFileIds) {
    String label = 'Showing $resultCount ${resultCount == 1 ? 'photo' : 'photos'}';
    if (_selectedPersonId != null && _userId != null) {
      final people = FaceDetectionService.instance.getCachedPeople(_userId!, activeFileIds);
      final p = people.firstWhere((x) => x.id == _selectedPersonId, orElse: () => PersonGroup(id: '', name: '', avatarPath: '', fileIds: [], featureVector: [], updatedAt: DateTime.now()));
      if (p.id.isNotEmpty) label = 'Filtered by ${p.name} ($resultCount)';
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: widget.accentColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: widget.accentColor.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.filter_alt_rounded, size: 14, color: widget.accentColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: widget.accentColor, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          if (_selectedPersonId != null && _userId != null) ...[
            GestureDetector(
              onTap: () {
                final people = FaceDetectionService.instance.getCachedPeople(_userId!, activeFileIds);
                final p = people.firstWhere((x) => x.id == _selectedPersonId, orElse: () => PersonGroup(id: '', name: '', avatarPath: '', fileIds: [], featureVector: [], updatedAt: DateTime.now()));
                if (p.id.isNotEmpty) _showRenamePersonDialog(p);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  children: [
                    Icon(Icons.edit_rounded, size: 14, color: widget.accentColor),
                    const SizedBox(width: 3),
                    Text('Rename', style: TextStyle(color: widget.accentColor, fontSize: 11, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          GestureDetector(
            onTap: () {
              setState(() {
                _selectedPersonId = null;
                _selectedYear = null;
                _selectedMonth = null;
                _searchQuery = '';
                _searchCtrl.clear();
              });
            },
            child: Icon(Icons.close_rounded, size: 16, color: widget.accentColor),
          ),
        ],
      ),
    );
  }

  // ═════════════════════════════════════════════════════════════════════════════
  // ── ALBUMS & FOLDERS MODE ────────────────────────────────────────────────────
  // ═════════════════════════════════════════════════════════════════════════════

  Widget _buildAlbumsContent(List<CloudFile> allImages) {
    final currentF = _currentFolder;
    final foldersAsync = ref.watch(foldersProvider(currentF?.id));

    // Files in current folder
    final folderFilesAsync = currentF == null
        ? null
        : ref.watch(filesProvider((folderId: currentF.id, sortBy: 'uploadedAt', descending: true)));

    return Column(
      children: [
        // ── Compact Breadcrumbs & Actions Row ─────────────────────────────────────────
        Container(
          margin: const EdgeInsets.fromLTRB(16, 2, 16, 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (_folderStack.isNotEmpty) ...[
                    GestureDetector(
                      onTap: () => setState(() => _folderStack.removeLast()),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          color: AppTheme.card,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: AppTheme.cardBorder),
                        ),
                        child: const Icon(Icons.arrow_back_rounded, size: 14, color: AppTheme.textPrimary),
                      ),
                    ),
                  ],
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          GestureDetector(
                            onTap: () => setState(() => _folderStack.clear()),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.photo_library_rounded,
                                  size: 13,
                                  color: _folderStack.isEmpty ? AppTheme.primary : AppTheme.textSecondary,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'Gallery Root',
                                  style: TextStyle(
                                    fontWeight: _folderStack.isEmpty ? FontWeight.w700 : FontWeight.w500,
                                    color: _folderStack.isEmpty ? AppTheme.primary : AppTheme.textSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          ..._folderStack.asMap().entries.map((entry) {
                            final idx = entry.key;
                            final f = entry.value;
                            final isLast = idx == _folderStack.length - 1;
                            return Row(
                              children: [
                                const Text(' / ', style: TextStyle(color: AppTheme.textHint, fontSize: 12)),
                                GestureDetector(
                                  onTap: isLast ? null : () {
                                    setState(() {
                                      _folderStack.removeRange(idx + 1, _folderStack.length);
                                    });
                                  },
                                  child: Text(
                                    f.name,
                                    style: TextStyle(
                                      fontWeight: isLast ? FontWeight.w700 : FontWeight.w500,
                                      color: isLast ? AppTheme.primary : AppTheme.textSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            );
                          }),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Compact Action buttons: New Subfolder, Upload Images, Camera
              Row(
                children: [
                  _CompactActionButton(
                    icon: Icons.create_new_folder_rounded,
                    label: currentF == null ? '+ Folder' : '+ Subfolder',
                    color: AppTheme.folderColor,
                    onTap: () => _showCreateFolderDialog(currentF),
                  ),
                  const SizedBox(width: 6),
                  _CompactActionButton(
                    icon: Icons.add_photo_alternate_rounded,
                    label: 'Upload',
                    color: widget.accentColor,
                    onTap: () {
                      ref.read(driveProvider.notifier).uploadFiles(
                        folderId: currentF?.id,
                        folderPath: currentF?.path ?? '/',
                      );
                    },
                  ),
                  const SizedBox(width: 6),
                  _CompactActionButton(
                    icon: Icons.camera_alt_rounded,
                    label: 'Camera',
                    color: Colors.pinkAccent,
                    onTap: () {
                      openCameraCapture(
                        context,
                        folderId: currentF?.id,
                        folderPath: currentF?.path ?? '/',
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),

        // ── Subfolders & Images inside Current Folder ─────────────────────────
        Expanded(
          child: foldersAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e', style: AppTheme.bodyMedium)),
            data: (folders) {
              // Automatically filter to only show folders that contain images or were newly created
              final imageFolders = folders.where((f) => _isImageFolder(f, allImages)).toList();

              if (currentF == null) {
                // Root view: show folders and root images
                final rootImages = allImages.where((f) => f.folderId == null || f.folderId!.isEmpty).toList();

                if (imageFolders.isEmpty && rootImages.isEmpty) {
                  return _buildEmptyCard('No image albums or photos yet.\nTap "+ Folder" to create an album or "Upload" to add photos.');
                }

                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 90),
                  children: [
                    if (imageFolders.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'FOLDERS & ALBUMS',
                          style: TextStyle(
                            color: AppTheme.textSecondary,
                            letterSpacing: 1.1,
                            fontWeight: FontWeight.w700,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      _buildFolderGrid(imageFolders, allImages),
                      const SizedBox(height: 16),
                    ],

                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Text(
                            'UNORGANIZED IMAGES (${rootImages.length})',
                            style: const TextStyle(
                              color: AppTheme.textSecondary,
                              letterSpacing: 1.1,
                              fontWeight: FontWeight.w700,
                              fontSize: 11,
                            ),
                          ),
                          const Spacer(),
                          const Text(
                            'Select folder to organize',
                            style: TextStyle(fontSize: 11, color: AppTheme.textHint),
                          ),
                        ],
                      ),
                    ),
                    if (rootImages.isEmpty)
                      _buildEmptyCard('No images at root. Create a folder above or upload images.')
                    else
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 4,
                          mainAxisSpacing: 4,
                        ),
                        itemCount: rootImages.length,
                        itemBuilder: (_, i) => _ImageTile(
                          file: rootImages[i],
                          allImages: rootImages,
                          accentColor: widget.accentColor,
                          onMoreTap: () => _showFileOptions(context, rootImages[i]),
                        ),
                      ),
                  ],
                );
              }

              // Inside a Subfolder
              return folderFilesAsync?.when(
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Center(child: Text('$e')),
                    data: (filesInFolder) {
                      final imagesInFolder = filesInFolder
                          .where((f) => _imageExtensions.contains(f.extension.toLowerCase()))
                          .toList();

                      return ListView(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 90),
                        children: [
                          // Subfolders in this folder that contain images
                          if (imageFolders.isNotEmpty) ...[
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                'SUBFOLDERS',
                                style: TextStyle(
                                  color: AppTheme.textSecondary,
                                  letterSpacing: 1.1,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                            _buildFolderGrid(imageFolders, allImages),
                            const SizedBox(height: 16),
                          ],

                          // Photos in this folder
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              'PHOTOS IN THIS FOLDER (${imagesInFolder.length})',
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                                letterSpacing: 1.1,
                                fontWeight: FontWeight.w700,
                                fontSize: 11,
                              ),
                            ),
                          ),
                          if (imagesInFolder.isEmpty)
                            _buildEmptyCard('This folder has no images yet.\nTap "Upload" or "Camera" above.')
                          else
                            GridView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                crossAxisSpacing: 4,
                                mainAxisSpacing: 4,
                              ),
                              itemCount: imagesInFolder.length,
                              itemBuilder: (_, i) => _ImageTile(
                                file: imagesInFolder[i],
                                allImages: imagesInFolder,
                                accentColor: widget.accentColor,
                                onMoreTap: () => _showFileOptions(context, imagesInFolder[i]),
                              ),
                            ),
                        ],
                      );
                    },
                  ) ??
                  const SizedBox.shrink();
            },
          ),
        ),
      ],
    );
  }

  Widget _buildFolderGrid(List<CloudFolder> folders, List<CloudFile> allImages) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 2.2,
      ),
      itemCount: folders.length,
      itemBuilder: (context, i) {
        final folder = folders[i];
        final folderColor = _parseFolderColor(folder.color);
        final photoCount = _countImagesInFolder(folder, allImages);

        return GestureDetector(
          onTap: () => setState(() => _folderStack.add(folder)),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: folderColor.withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: folderColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.folder_rounded, color: folderColor, size: 22),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        folder.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        photoCount == 0 ? 'Empty album' : '$photoCount ${photoCount == 1 ? 'photo' : 'photos'}',
                        style: const TextStyle(color: AppTheme.textHint, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: AppTheme.textHint, size: 18),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Dialogs & Helpers ────────────────────────────────────────────────────────

  void _showCreateFolderDialog(CloudFolder? parent) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(parent == null ? 'New Image Folder / Album' : 'New Subfolder in ${parent.name}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: AppTheme.bodyLarge,
          decoration: InputDecoration(
            hintText: parent == null ? 'Album name (e.g. Vacation, Family)' : 'Subfolder name',
            prefixIcon: const Icon(Icons.folder_rounded, color: AppTheme.folderColor),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              final name = ctrl.text.trim();
              if (name.isNotEmpty) {
                setState(() {
                  _newlyCreatedFolderIds.add(name);
                });
                ref.read(driveProvider.notifier).createFolder(
                  name: name,
                  parentFolderId: parent?.id,
                  parentPath: parent?.path ?? '/',
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

  void _showRenamePersonDialog(PersonGroup person) {
    final ctrl = TextEditingController(text: person.name);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Name this person'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 60,
                height: 60,
                decoration: const BoxDecoration(shape: BoxShape.circle),
                child: ClipOval(
                  child: io.File(person.avatarPath).existsSync()
                      ? Image.file(io.File(person.avatarPath), fit: BoxFit.cover)
                      : Container(color: widget.accentColor.withValues(alpha: 0.2)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              style: AppTheme.bodyLarge,
              decoration: const InputDecoration(
                hintText: 'e.g. Manith, Mom, Friend',
                prefixIcon: Icon(Icons.person_rounded),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              final newName = ctrl.text.trim();
              if (newName.isNotEmpty && _userId != null) {
                FaceDetectionService.instance.renamePerson(_userId!, person.id, newName);
                Navigator.pop(context);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showFileOptions(BuildContext context, CloudFile file) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => _ImagesFileOptionsSheet(file: file, ref: ref),
    );
  }

  Widget _buildEmptyState(String msg) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.photo_library_outlined, size: 54, color: widget.accentColor.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          Text(msg, style: AppTheme.titleMedium.copyWith(color: AppTheme.textSecondary)),
        ],
      ),
    );
  }

  Widget _buildEmptyCard(String msg) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        children: [
          const Icon(Icons.image_not_supported_outlined, color: AppTheme.textHint, size: 36),
          const SizedBox(height: 8),
          Text(msg, textAlign: TextAlign.center, style: AppTheme.bodyMedium.copyWith(color: AppTheme.textSecondary)),
        ],
      ),
    );
  }

  Color _parseFolderColor(String? hex) {
    if (hex == null || hex.isEmpty) return AppTheme.folderColor;
    try {
      final clean = hex.replaceAll('#', '');
      return Color(int.parse('FF$clean', radix: 16));
    } catch (_) {
      return AppTheme.folderColor;
    }
  }
}

// ── Segmented Mode Pill ────────────────────────────────────────────────────────

class _ModePill extends StatelessWidget {
  final IconData icon;
  final String label;
  final int? count;
  final bool isSelected;
  final Color accentColor;
  final VoidCallback onTap;

  const _ModePill({
    required this.icon,
    required this.label,
    this.count,
    required this.isSelected,
    required this.accentColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 10),
        decoration: BoxDecoration(
          color: isSelected ? accentColor.withValues(alpha: 0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? accentColor.withValues(alpha: 0.5) : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: isSelected ? accentColor : AppTheme.textSecondary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected ? accentColor : AppTheme.textSecondary,
              ),
            ),
            if (count != null) ...[
              const SizedBox(width: 5),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: isSelected ? accentColor : AppTheme.cardBorder,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: isSelected ? Colors.white : AppTheme.textPrimary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Filter Chip Widget ─────────────────────────────────────────────────────────

class _FilterChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final Color accentColor;
  final bool isSmall;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.isSelected,
    required this.accentColor,
    this.isSmall = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: EdgeInsets.symmetric(horizontal: isSmall ? 10 : 13, vertical: isSmall ? 4 : 6),
          decoration: BoxDecoration(
            color: isSelected ? accentColor : AppTheme.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isSelected ? accentColor : AppTheme.cardBorder,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: isSmall ? 11 : 12,
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              color: isSelected ? Colors.white : AppTheme.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Compact Action Button ──────────────────────────────────────────────────────

class _CompactActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _CompactActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withValues(alpha: 0.25), width: 1),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 13, color: color),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.1,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


// ── Image Tile with Time Badge ─────────────────────────────────────────────────

class _ImageTile extends ConsumerStatefulWidget {
  final CloudFile file;
  final List<CloudFile> allImages;
  final Color accentColor;
  final VoidCallback onMoreTap;

  const _ImageTile({
    required this.file,
    required this.allImages,
    required this.accentColor,
    required this.onMoreTap,
  });

  @override
  ConsumerState<_ImageTile> createState() => _ImageTileState();
}

class _ImageTileState extends ConsumerState<_ImageTile> {
  bool _isLoadingThumbnail = false;

  @override
  void initState() {
    super.initState();
    _checkThumbnail();
  }

  @override
  void didUpdateWidget(_ImageTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.id != widget.file.id ||
        oldWidget.file.thumbnailPath != widget.file.thumbnailPath) {
      _checkThumbnail();
    }
  }

  void _checkThumbnail() {
    final f = widget.file;
    final isImg = _imageExtensions.contains(f.extension.toLowerCase());
    final needsLoad = isImg &&
        (f.thumbnailPath == null || f.thumbnailPath!.isEmpty) &&
        f.telegramThumbnailId != null &&
        f.telegramThumbnailId! > 0;
    if (needsLoad) _loadThumbnail(f.telegramThumbnailId!);
  }

  Future<void> _loadThumbnail(int thumbnailId) async {
    if (_isLoadingThumbnail) return;
    if (mounted) setState(() => _isLoadingThumbnail = true);
    try {
      final localPath = await TdlibService.instance.downloadThumbnail(thumbnailId);
      if (localPath != null && localPath.isNotEmpty && mounted) {
        final authService = ref.read(telegramAuthServiceProvider);
        final profile = await authService.getProfile();
        final userId = profile['userId'];
        if (userId != null && userId.isNotEmpty) {
          await ref.read(firestoreServiceProvider).updateThumbnailPath(widget.file.id, localPath);
          FaceDetectionService.instance.scanSingleFile(userId, widget.file, localPath);
        }
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _isLoadingThumbnail = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.file;
    final hasThumb = f.thumbnailPath != null && f.thumbnailPath!.isNotEmpty;
    final initialIdx = widget.allImages.indexOf(f);

    return GestureDetector(
      onTap: () {
        Navigator.pushNamed(
          context,
          AppRoutes.imageViewer,
          arguments: {
            'file': f,
            'allFiles': widget.allImages,
            'initialIndex': initialIdx >= 0 ? initialIdx : 0,
          },
        );
      },
      onLongPress: widget.onMoreTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Container(
          color: AppTheme.card,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Image content
              if (hasThumb)
                f.thumbnailPath!.startsWith('http')
                    ? CachedNetworkImage(
                        imageUrl: f.thumbnailPath!,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => _placeholder(),
                        errorWidget: (_, __, ___) => _placeholder(),
                      )
                    : Image.file(
                        io.File(f.thumbnailPath!),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _placeholder(),
                      )
              else if (_isLoadingThumbnail)
                Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: widget.accentColor),
                  ),
                )
              else
                _placeholder(),

              // Gradient shadow at bottom
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  height: 24,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                ),
              ),

              // Time badge (e.g. "6:34 PM")
              Positioned(
                bottom: 3,
                left: 4,
                child: Text(
                  AppDateUtils.formatTime(f.uploadedAt),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    shadows: [Shadow(color: Colors.black, blurRadius: 3)],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: widget.accentColor.withValues(alpha: 0.1),
      child: Icon(Icons.image_rounded, color: widget.accentColor.withValues(alpha: 0.4), size: 24),
    );
  }
}

// ── Images File Options Bottom Sheet ──────────────────────────────────────────

class _ImagesFileOptionsSheet extends StatelessWidget {
  final CloudFile file;
  final WidgetRef ref;

  const _ImagesFileOptionsSheet({required this.file, required this.ref});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: AppTheme.cardBorder, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: file.thumbnailPath != null && io.File(file.thumbnailPath!).existsSync()
                        ? Image.file(io.File(file.thumbnailPath!), fit: BoxFit.cover)
                        : Container(color: AppTheme.cardBorder, child: const Icon(Icons.image_rounded)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.titleMedium.copyWith(fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${FileUtils.formatFileSize(file.sizeBytes)} • ${AppDateUtils.formatDateTime(file.uploadedAt)}',
                        style: AppTheme.bodyMedium.copyWith(fontSize: 11, color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 20),
            ListTile(
              leading: const Icon(Icons.download_rounded, color: AppTheme.primary),
              title: const Text('Download'),
              onTap: () {
                Navigator.pop(context);
                final auth = ref.read(telegramAuthServiceProvider);
                final tg = TelegramStorageService(auth);
                ref.read(dlManagerProvider.notifier).downloadCloudFile(file, tg);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Downloading ${file.name}…'), backgroundColor: AppTheme.primary),
                );
              },
            ),
            ListTile(
              leading: Icon(file.isStarred ? Icons.star_border_rounded : Icons.star_rounded, color: AppTheme.warning),
              title: Text(file.isStarred ? 'Remove Star' : 'Star'),
              onTap: () {
                Navigator.pop(context);
                ref.read(driveProvider.notifier).toggleStar(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline_rounded),
              title: const Text('Rename'),
              onTap: () {
                Navigator.pop(context);
                _showRenameDialog(context, file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded, color: AppTheme.error),
              title: const Text('Move to Trash', style: TextStyle(color: AppTheme.error)),
              onTap: () {
                Navigator.pop(context);
                ref.read(driveProvider.notifier).trashFile(file);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showRenameDialog(BuildContext context, CloudFile file) {
    final ctrl = TextEditingController(text: file.name);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Rename Image'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: AppTheme.bodyLarge,
          decoration: const InputDecoration(hintText: 'New image name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              final newName = ctrl.text.trim();
              if (newName.isNotEmpty && newName != file.name) {
                ref.read(driveProvider.notifier).renameFile(file, newName);
                Navigator.pop(context);
              }
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }
}
