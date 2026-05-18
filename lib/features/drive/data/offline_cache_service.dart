// offline_cache_service.dart
//
// The LRU app-private cache has been replaced by:
//   • "Open"  → temp stream → native device app  (zero permanent storage)
//   • "Save"  → public Downloads/LimitlessCloud  (user-initiated, visible in Gallery)
//
// This file is kept as a minimal stub so existing export references compile.

/// Status enum re-exported by download_manager_page.dart.
/// Now only 'cloud' is used — the others remain so compile-time references don't break.
enum OfflineStatus { cloud, caching, cached, failed }

/// Stub class kept for backward-compatible imports.
class OfflineCacheService {
  OfflineCacheService._();
  static final OfflineCacheService instance = OfflineCacheService._();

  // Kept so OfflineCacheNotifier (offline_cache_provider.dart) still compiles.
  static const int maxCacheBytes = 0;

  Future<void> init() async {}
  Future<bool> isCached(String fileId) async => false;
  Future<String?> getLocalPath(String fileId) async => null;
  Future<List<dynamic>> listCached() async => [];
  Future<int> totalCacheBytes() async => 0;
  Future<void> cacheFile({
    required String fileId, required int messageId,
    required String fileName, required int sizeBytes, required dynamic auth,
  }) async {}
  void cancelCache(String fileId) {}
  Future<void> removeFromCache(String fileId) async {}
  Future<void> clearAll() async {}
  void dispose() {}

  // Minimal progress stream stub
  Stream<CacheProgress> get progress$ => const Stream.empty();
}

class CacheProgress {
  final String fileId;
  final double progress;
  final OfflineStatus status;
  const CacheProgress({
    required this.fileId,
    required this.progress,
    required this.status,
  });
}
