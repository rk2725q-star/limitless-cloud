import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/date_utils.dart';
import '../../../../core/utils/file_utils.dart';
import '../../data/models/share_record.dart';
import '../providers/share_provider.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Shared With Me Page (full screen — navigated to from Starred tab or menu)
// ─────────────────────────────────────────────────────────────────────────────

class SharedWithMePage extends ConsumerStatefulWidget {
  const SharedWithMePage({super.key});

  @override
  ConsumerState<SharedWithMePage> createState() => _SharedWithMePageState();
}

class _SharedWithMePageState extends ConsumerState<SharedWithMePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    // Sync on open so recipient sees latest shares from Telegram
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(shareNotifierProvider.notifier).syncSharedWithMe();
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded,
              color: AppTheme.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Sharing',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 18)),
        bottom: TabBar(
          controller: _tab,
          labelColor: AppTheme.primary,
          unselectedLabelColor: AppTheme.textSecondary,
          indicatorColor: AppTheme.primary,
          indicatorSize: TabBarIndicatorSize.label,
          tabs: const [
            Tab(text: 'Shared with me'),
            Tab(text: 'My shares'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: const [
          _SharedWithMeTab(),
          _MySharesTab(),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Shared With Me tab
// ─────────────────────────────────────────────────────────────────────────────

class _SharedWithMeTab extends ConsumerWidget {
  const _SharedWithMeTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sharedWithMeProvider);
    return async.when(
      loading: () => const Center(
          child: CircularProgressIndicator(color: AppTheme.primary)),
      error: (e, _) => _ErrorState(message: e.toString()),
      data: (shares) {
        if (shares.isEmpty) {
          return const _EmptySharedState(
            icon: Icons.folder_shared_rounded,
            title: 'Nothing shared with you yet',
            subtitle:
                'When someone shares a file or folder with you,\nit will appear here.',
          );
        }
        return RefreshIndicator(
          color: AppTheme.primary,
          onRefresh: () =>
              ref.read(shareNotifierProvider.notifier).syncSharedWithMe(),
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: shares.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, i) => _ShareCard(
              share:    shares[i],
              isOwner:  false,
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  My Shares tab (items I shared)
// ─────────────────────────────────────────────────────────────────────────────

class _MySharesTab extends ConsumerWidget {
  const _MySharesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mySharesProvider);
    return async.when(
      loading: () => const Center(
          child: CircularProgressIndicator(color: AppTheme.primary)),
      error: (e, _) => _ErrorState(message: e.toString()),
      data: (shares) {
        if (shares.isEmpty) {
          return const _EmptySharedState(
            icon: Icons.share_rounded,
            title: 'No active shares',
            subtitle:
                'Tap ⋮ on any file or folder and choose\n"Share" to invite someone.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: shares.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (_, i) => _ShareCard(
            share:    shares[i],
            isOwner:  true,
            onRevoke: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  backgroundColor: AppTheme.surface,
                  title: const Text('Revoke share?',
                      style: TextStyle(color: AppTheme.textPrimary)),
                  content: Text(
                      'Remove ${shares[i].recipientName}\'s access to '
                      '"${shares[i].itemName}"?',
                      style:
                          const TextStyle(color: AppTheme.textSecondary)),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel')),
                    TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Revoke',
                            style: TextStyle(color: AppTheme.error))),
                  ],
                ),
              );
              if (ok == true) {
                await ref
                    .read(shareNotifierProvider.notifier)
                    .revokeShare(shares[i].id);
              }
            },
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Share card widget
// ─────────────────────────────────────────────────────────────────────────────

class _ShareCard extends StatelessWidget {
  final ShareRecord share;
  final bool        isOwner;
  final VoidCallback? onRevoke;

  const _ShareCard({
    required this.share,
    required this.isOwner,
    this.onRevoke,
  });

  @override
  Widget build(BuildContext context) {
    final isFolder = share.isFolderShare;
    final icon     = isFolder
        ? Icons.folder_rounded
        : FileUtils.getFileIcon(
            share.itemName.contains('.')
                ? share.itemName.split('.').last
                : '');
    final color    = isFolder ? AppTheme.folderColor : AppTheme.primary;

    return InkWell(
      onTap: () => _showDetails(context),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  share.itemName,
                  style: AppTheme.bodyLarge
                      .copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                // Owner: show who I shared with; Recipient: show owner info
                Row(children: [
                  Icon(
                    isOwner
                        ? Icons.person_rounded
                        : Icons.person_outline_rounded,
                    size: 13,
                    color: AppTheme.textHint,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      isOwner
                          ? 'Shared with ${share.recipientName} (${share.recipientPhone})'
                          : 'Shared by owner',
                      style: AppTheme.bodyMedium
                          .copyWith(color: AppTheme.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ]),
                const SizedBox(height: 2),
                Row(children: [
                  const Icon(Icons.access_time_rounded,
                      size: 11, color: AppTheme.textHint),
                  const SizedBox(width: 4),
                  Text(
                    AppDateUtils.getRelativeTime(share.createdAt),
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textHint),
                  ),
                  const SizedBox(width: 8),
                  // Role badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'View only',
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.primary),
                    ),
                  ),
                ]),
              ],
            ),
          ),
          if (isOwner && onRevoke != null)
            IconButton(
              icon: const Icon(Icons.link_off_rounded,
                  size: 20, color: AppTheme.error),
              tooltip: 'Revoke access',
              onPressed: onRevoke,
            ),
        ]),
      ),
    );
  }

  void _showDetails(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  share.isFolderShare ? Icons.folder_rounded : Icons.insert_drive_file_rounded,
                  color: AppTheme.primary,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      share.itemName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      isOwner
                          ? 'Shared with ${share.recipientName}'
                          : 'Shared with you',
                      style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                    ),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.primary.withValues(alpha: 0.2)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.shield_rounded, color: AppTheme.primary, size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Protected Share: Only the owner has permission to delete, rename, or move this item.',
                      style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.card,
                  foregroundColor: AppTheme.textPrimary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Helpers
// ─────────────────────────────────────────────────────────────────────────────

class _EmptySharedState extends StatelessWidget {
  final IconData icon;
  final String   title;
  final String   subtitle;

  const _EmptySharedState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 80, height: 80,
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: AppTheme.primary, size: 40),
          ),
          const SizedBox(height: 20),
          Text(title, style: AppTheme.titleLarge,
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(subtitle,
              style: AppTheme.bodyMedium.copyWith(height: 1.6),
              textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  const _ErrorState({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(message,
            style: const TextStyle(
                color: AppTheme.error, fontSize: 13),
            textAlign: TextAlign.center),
      ),
    );
  }
}
