import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_routes.dart';
import '../../../../core/theme/app_theme.dart';
import '../../data/models/cloud_file.dart';
import '../providers/drive_provider.dart';
import '../widgets/file_list_item.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});
  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _ctrl = TextEditingController();
  List<CloudFile> _results = [];
  bool _isLoading = false;

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) { setState(() => _results = []); return; }
    setState(() => _isLoading = true);
    final results = await ref.read(driveProvider.notifier).searchFiles(q);
    setState(() { _results = results; _isLoading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          style: AppTheme.bodyLarge,
          decoration: const InputDecoration(
            hintText: 'Search files...',
            border: InputBorder.none,
            prefixIcon: Icon(Icons.search_rounded, color: AppTheme.textHint),
          ),
          onChanged: _search,
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _results.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.search_off_rounded, color: AppTheme.textHint, size: 56),
                      const SizedBox(height: 12),
                      Text(
                        _ctrl.text.isEmpty ? 'Type to search your files' : 'No files found',
                        style: AppTheme.bodyMedium,
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _results.length,
                  itemBuilder: (_, i) => FileListItem(
                    file: _results[i],
                    onTap: () => Navigator.pushNamed(context, AppRoutes.fileDetail, arguments: {'file': _results[i]}),
                    onLongPress: () {},
                    onMoreTap: () {},
                  ),
                ),
    );
  }
}
