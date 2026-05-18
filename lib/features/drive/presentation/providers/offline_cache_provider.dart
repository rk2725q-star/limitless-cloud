import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/cloud_file.dart';
import '../../data/offline_cache_service.dart';
import '../../../auth/data/telegram_auth_service.dart';

// ── Per-file offline state ────────────────────────────────────────────────────

class FileOfflineState {
  final OfflineStatus status;
  final double progress; // 0.0 – 1.0 during caching
  final String? localPath;
  final String? error;

  const FileOfflineState({
    this.status = OfflineStatus.cloud,
    this.progress = 0.0,
    this.localPath,
    this.error,
  });

  bool get isAvailableOffline => status == OfflineStatus.cached;
  bool get isCaching => status == OfflineStatus.caching;
  bool get isFailed => status == OfflineStatus.failed;
}

// ── Global offline state (all files) ─────────────────────────────────────────

class OfflineCacheNotifier extends StateNotifier<Map<String, FileOfflineState>> {
  final Ref _ref;
  StreamSubscription<CacheProgress>? _sub;

  OfflineCacheNotifier(this._ref) : super(const {}) {
    _initProgressListener();
    _loadCachedList();
  }

  // Listen to the singleton service progress stream.
  void _initProgressListener() {
    _sub = OfflineCacheService.instance.progress$.listen((event) {
      final existing = state[event.fileId] ?? const FileOfflineState();
      state = {
        ...state,
        event.fileId: FileOfflineState(
          status: event.status,
          progress: event.progress,
          localPath: event.status == OfflineStatus.cached
              ? existing.localPath
              : null,
        ),
      };
    });
  }

  // On startup, populate state from SQLite so the UI reflects existing cache.
  Future<void> _loadCachedList() async {
    await OfflineCacheService.instance.init();
    final records = await OfflineCacheService.instance.listCached();
    final newState = Map<String, FileOfflineState>.from(state);
    for (final rec in records) {
      newState[rec.fileId] = FileOfflineState(
        status: OfflineStatus.cached,
        progress: 1.0,
        localPath: rec.localPath,
      );
    }
    state = newState;
  }

  /// Toggle offline availability for a file.
  Future<void> toggle(CloudFile file) async {
    final current = state[file.id]?.status ?? OfflineStatus.cloud;

    if (current == OfflineStatus.cached) {
      // Remove from cache.
      await OfflineCacheService.instance.removeFromCache(file.id);
      state = {...state, file.id: const FileOfflineState()};
      return;
    }

    if (current == OfflineStatus.caching) {
      // Cancel in-flight download.
      OfflineCacheService.instance.cancelCache(file.id);
      state = {...state, file.id: const FileOfflineState()};
      return;
    }

    // Start caching.
    final auth = _ref.read(telegramAuthServiceProvider);
    unawaited(OfflineCacheService.instance.cacheFile(
      fileId: file.id,
      messageId: file.telegramMessageId,
      fileName: file.name,
      sizeBytes: file.sizeBytes,
      auth: auth,
    ));
  }

  /// Remove a file from cache (called from the cache manager UI).
  Future<void> remove(String fileId) async {
    OfflineCacheService.instance.cancelCache(fileId);
    await OfflineCacheService.instance.removeFromCache(fileId);
    state = {...state, fileId: const FileOfflineState()};
  }

  /// Clear all cached files.
  Future<void> clearAll() async {
    final ids = state.keys.toList();
    for (final id in ids) {
      OfflineCacheService.instance.cancelCache(id);
    }
    await OfflineCacheService.instance.clearAll();
    state = const {};
  }

  /// Refresh state from disk (e.g. after app restart).
  Future<void> refresh() => _loadCachedList();

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

// ── Providers ─────────────────────────────────────────────────────────────────

final offlineCacheProvider =
    StateNotifierProvider<OfflineCacheNotifier, Map<String, FileOfflineState>>(
  (ref) => OfflineCacheNotifier(ref),
);

/// Convenience: get the offline state for a single file.
final fileOfflineStateProvider =
    Provider.family<FileOfflineState, String>((ref, fileId) {
  final all = ref.watch(offlineCacheProvider);
  return all[fileId] ?? const FileOfflineState();
});
