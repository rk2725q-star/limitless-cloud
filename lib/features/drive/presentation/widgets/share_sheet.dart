import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../data/models/cloud_file.dart';
import '../../data/models/cloud_folder.dart';
import '../providers/share_provider.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Public entry points
// ─────────────────────────────────────────────────────────────────────────────

Future<void> showShareFileSheet(
    BuildContext context, WidgetRef ref, CloudFile file) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ShareSheet(file: file, ref: ref),
  );
}

Future<void> showShareFolderSheet(
    BuildContext context, WidgetRef ref, CloudFolder folder) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ShareSheet(folder: folder, ref: ref),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
//  _ShareSheet — the bottom sheet
// ─────────────────────────────────────────────────────────────────────────────

class _ShareSheet extends StatefulWidget {
  final CloudFile?   file;
  final CloudFolder? folder;
  final WidgetRef    ref;

  const _ShareSheet({this.file, this.folder, required this.ref});

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  final _phoneCtrl = TextEditingController();
  final _focusNode = FocusNode();

  bool _looking  = false;
  bool _sharing  = false;
  bool _done     = false;
  String? _error;

  Map<String, dynamic>? _resolvedUser; // {userId, name}

  String get _itemName => widget.file?.name ?? widget.folder!.name;

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ── Look up user by phone ────────────────────────────────────────────────

  Future<void> _lookupUser() async {
    final phone = _phoneCtrl.text.trim();
    if (phone.isEmpty) return;
    setState(() { _looking = true; _error = null; _resolvedUser = null; });
    try {
      final user = await widget.ref
          .read(shareNotifierProvider.notifier)
          .lookupUser(phone);
      setState(() { _resolvedUser = user; _looking = false; });
    } catch (e) {
      setState(() { _error = e.toString().replaceFirst('Exception: ', ''); _looking = false; });
    }
  }

  // ── Share ────────────────────────────────────────────────────────────────

  Future<void> _share() async {
    final phone = _phoneCtrl.text.trim();
    if (phone.isEmpty) return;
    setState(() { _sharing = true; _error = null; });
    try {
      final notifier = widget.ref.read(shareNotifierProvider.notifier);
      if (widget.file != null) {
        await notifier.shareFile(widget.file!, phone);
      } else {
        await notifier.shareFolder(widget.folder!, phone);
      }
      setState(() { _sharing = false; _done = true; });
      await Future.delayed(const Duration(milliseconds: 1200));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() {
        _sharing = false;
        _error   = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bottom),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                widget.file != null
                    ? Icons.insert_drive_file_rounded
                    : Icons.folder_rounded,
                color: AppTheme.primary,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Share Item',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary)),
                  Text(
                    _itemName,
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded,
                  color: AppTheme.textHint, size: 20),
              onPressed: () => Navigator.pop(context),
            ),
          ]),

          const SizedBox(height: 20),

          // Phone or username input
          const Text('Recipient mobile number or User ID / Nickname',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textSecondary)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller:  _phoneCtrl,
                focusNode:   _focusNode,
                keyboardType: TextInputType.text,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[+\w@\.\-]'))],
                style: const TextStyle(color: AppTheme.textPrimary, fontSize: 15),
                decoration: InputDecoration(
                  hintText:        '+91 9XXXXXXXXX or @user_id',
                  hintStyle:       const TextStyle(color: AppTheme.textHint),
                  prefixIcon:      const Icon(Icons.person_search_rounded,
                      color: AppTheme.textHint, size: 18),
                  filled:          true,
                  fillColor:       AppTheme.card,
                  border:          OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:   BorderSide.none),
                  focusedBorder:   OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:   const BorderSide(
                          color: AppTheme.primary, width: 1.5)),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                ),
                onSubmitted: (_) => _lookupUser(),
              ),
            ),
            const SizedBox(width: 8),
            // Lookup button
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _looking
                  ? const SizedBox(
                      width: 44, height: 44,
                      child: Center(child: SizedBox(
                          width: 22, height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.5,
                              color: AppTheme.primary))))
                  : IconButton(
                      icon: const Icon(Icons.search_rounded),
                      color: AppTheme.primary,
                      onPressed: _lookupUser,
                      tooltip: 'Find user',
                    ),
            ),
          ]),

          // Error
          if (_error != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.error.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: AppTheme.error.withValues(alpha: 0.3)),
              ),
              child: Row(children: [
                const Icon(Icons.error_outline_rounded,
                    color: AppTheme.error, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_error!,
                      style: const TextStyle(
                          color: AppTheme.error, fontSize: 12)),
                ),
              ]),
            ),
          ],

          // Resolved user preview
          if (_resolvedUser != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.success.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: AppTheme.success.withValues(alpha: 0.3)),
              ),
              child: Row(children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor:
                      AppTheme.primary.withValues(alpha: 0.15),
                  child: Text(
                    (_resolvedUser!['name'] as String? ?? '?')
                        .isNotEmpty
                        ? (_resolvedUser!['name'] as String)[0]
                            .toUpperCase()
                        : '?',
                    style: const TextStyle(
                        color: AppTheme.primary,
                        fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_resolvedUser!['name'] as String? ?? '–',
                            style: const TextStyle(
                                color: AppTheme.textPrimary,
                                fontWeight: FontWeight.w600,
                                fontSize: 14)),
                        const Text('Telegram user found  ✓',
                            style: TextStyle(
                                color: AppTheme.success, fontSize: 11)),
                      ]),
                ),
              ]),
            ),
          ],

          const SizedBox(height: 16),

          // Info pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Row(children: [
              Icon(Icons.info_outline_rounded,
                  color: AppTheme.primary, size: 15),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Recipient can view & download only. '
                  'Only you can delete or move this item.',
                  style: TextStyle(
                      color: AppTheme.textSecondary, fontSize: 11),
                ),
              ),
            ]),
          ),

          const SizedBox(height: 16),

          // Share button
          SizedBox(
            width: double.infinity,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _done
                  ? _SuccessPill()
                  : ElevatedButton.icon(
                      key: const ValueKey('share_btn'),
                      onPressed: (_resolvedUser != null && !_sharing)
                          ? _share
                          : null,
                      icon: _sharing
                          ? const SizedBox(
                              width: 18, height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white))
                          : const Icon(Icons.send_rounded, size: 18),
                      label: Text(_sharing ? 'Sharing…' : 'Share'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                        textStyle: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 15),
                        disabledBackgroundColor:
                            AppTheme.primary.withValues(alpha: 0.3),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SuccessPill extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: AppTheme.success.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.success.withValues(alpha: 0.4)),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_rounded,
              color: AppTheme.success, size: 20),
          SizedBox(width: 8),
          Text('Shared successfully!',
              style: TextStyle(
                  color: AppTheme.success,
                  fontWeight: FontWeight.w700,
                  fontSize: 15)),
        ],
      ),
    );
  }
}

