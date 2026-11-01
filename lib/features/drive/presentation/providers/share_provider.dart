import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../auth/data/telegram_auth_service.dart';
import '../../data/models/share_record.dart';
import '../../data/models/cloud_file.dart';
import '../../data/models/cloud_folder.dart';
import '../../data/share_service.dart';

// ── Singleton service provider ───────────────────────────────────────────────

final shareServiceProvider = Provider<ShareService>((ref) => const ShareService());

// ── Current user ID helper ───────────────────────────────────────────────────

final _currentUserIdProvider = FutureProvider<String?>((ref) async {
  final auth = ref.read(telegramAuthServiceProvider);
  final profile = await auth.getProfile();
  final uid = profile['userId'];
  return uid?.toString();
});

// ── My shares (items I shared with others) ───────────────────────────────────

final mySharesProvider =
    FutureProvider.autoDispose<List<ShareRecord>>((ref) async {
  final uid = await ref.watch(_currentUserIdProvider.future);
  if (uid == null || uid.isEmpty) return [];
  return ref.read(shareServiceProvider).myShares(uid);
});

// ── Shared with me (items others shared with me) ─────────────────────────────

final sharedWithMeProvider =
    FutureProvider.autoDispose<List<ShareRecord>>((ref) async {
  final uid = await ref.watch(_currentUserIdProvider.future);
  if (uid == null || uid.isEmpty) return [];
  return ref.read(shareServiceProvider).sharedWithMe(uid);
});

// ── Share action notifier ────────────────────────────────────────────────────

class ShareNotifier extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  /// Share a file with a phone number. Returns the created ShareRecord.
  Future<ShareRecord> shareFile(CloudFile file, String phone) async {
    final uid = await ref.read(_currentUserIdProvider.future);
    if (uid == null || uid.isEmpty) throw Exception('Not logged in');
    final svc = ref.read(shareServiceProvider);
    final rec = await svc.shareItem(
      ownerUserId: uid,
      phone: phone,
      file: file,
    );
    ref.invalidate(mySharesProvider);
    return rec;
  }

  /// Share a folder with a phone number.
  Future<ShareRecord> shareFolder(CloudFolder folder, String phone) async {
    final uid = await ref.read(_currentUserIdProvider.future);
    if (uid == null || uid.isEmpty) throw Exception('Not logged in');
    final svc = ref.read(shareServiceProvider);
    final rec = await svc.shareItem(
      ownerUserId: uid,
      phone: phone,
      folder: folder,
    );
    ref.invalidate(mySharesProvider);
    return rec;
  }

  /// Revoke a share (only owner can do this).
  Future<void> revokeShare(String shareId) async {
    final uid = await ref.read(_currentUserIdProvider.future);
    if (uid == null || uid.isEmpty) throw Exception('Not logged in');
    await ref.read(shareServiceProvider).revokeShare(shareId, uid);
    ref.invalidate(mySharesProvider);
  }

  /// Sync "Shared with me" from Telegram Saved Messages.
  Future<void> syncSharedWithMe() async {
    final uid = await ref.read(_currentUserIdProvider.future);
    if (uid == null || uid.isEmpty) return;
    await ref.read(shareServiceProvider).syncSharedWithMe(uid);
    ref.invalidate(sharedWithMeProvider);
  }

  /// Lookup a Telegram user by phone number (for share sheet preview).
  Future<Map<String, dynamic>> lookupUser(String phone) =>
      ref.read(shareServiceProvider).lookupUserByPhone(phone);
}

final shareNotifierProvider =
    AsyncNotifierProvider<ShareNotifier, void>(ShareNotifier.new);

// ── Per-item share count helper (for context menus) ──────────────────────────

final fileShareCountProvider =
    FutureProvider.autoDispose.family<int, String>((ref, fileId) async {
  final shares = await ref.read(shareServiceProvider).sharesForFile(fileId);
  return shares.length;
});

final folderShareCountProvider =
    FutureProvider.autoDispose.family<int, String>((ref, folderId) async {
  final shares = await ref.read(shareServiceProvider).sharesForFolder(folderId);
  return shares.length;
});

