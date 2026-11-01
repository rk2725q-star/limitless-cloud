import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'tdlib_service.dart';
import '../../features/auth/data/telegram_auth_service.dart';
import '../../features/drive/data/models/cloud_file.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Constants
// ─────────────────────────────────────────────────────────────────────────────

const int _kMB = 1024 * 1024;

/// Parts to keep behind current playback position (safe for seek-back).
const int _kBehindWindow = 2;

/// Parts to keep buffered ahead of playback.
/// 8 parts × 15 MB = 120 MB buffer ahead (~5-6 minutes of video).
/// Eliminates buffering stalls completely.
const int _kAheadWindow = 8;

// ─────────────────────────────────────────────────────────────────────────────
//  Data model
// ─────────────────────────────────────────────────────────────────────────────

enum PartStatus { idle, downloading, ready, evicted }

class StreamPart {
  final int index;
  final int byteStart; // inclusive
  final int byteEnd;   // exclusive
  String? localPath;
  PartStatus status;

  StreamPart({
    required this.index,
    required this.byteStart,
    required this.byteEnd,
    this.status = PartStatus.idle,
  });

  int get byteLength => byteEnd - byteStart;
}

typedef StreamBufferCallback = void Function(double progress, bool ready);

// ─────────────────────────────────────────────────────────────────────────────
//  SmartStreamingSession — Continuous Deep-Prefetch Streaming Engine
// ─────────────────────────────────────────────────────────────────────────────

class SmartStreamingSession {
  final CloudFile file;
  final TelegramAuthService authService;

  late final List<StreamPart> parts;
  late final int _partSize;
  late final int _totalBytes;

  int _currentPart = 0;
  bool _disposed   = false;

  HttpServer? _server;
  int _serverPort  = 0;

  final List<int> _queue = [];
  bool _workerActive = false;
  Directory? _sessionDir;

  SmartStreamingSession._({required this.file, required this.authService});

  // ── Factory ───────────────────────────────────────────────────────────────

  static Future<SmartStreamingSession> create({
    required CloudFile file,
    required TelegramAuthService authService,
    StreamBufferCallback? onBuffer,
  }) async {
    final session = SmartStreamingSession._(
      file: file,
      authService: authService,
    );
    await session._init(onBuffer: onBuffer);
    return session;
  }

  // ── Part size (15 MB is optimal balance of rapid startup and deep throughput)

  static int _calcPartSize(int totalBytes) {
    if (totalBytes < 100 * _kMB) return 10 * _kMB;
    return 15 * _kMB;
  }

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> _init({StreamBufferCallback? onBuffer}) async {
    _totalBytes = file.sizeBytes;
    _partSize   = _calcPartSize(_totalBytes);

    final partCount = (_totalBytes / _partSize).ceil();
    parts = List.generate(partCount, (i) {
      final start = i * _partSize;
      final end   = min(start + _partSize, _totalBytes);
      return StreamPart(index: i, byteStart: start, byteEnd: end);
    });

    debugPrint('[Stream] ${file.name}: ${_totalBytes ~/ _kMB}MB, '
        '$partCount parts × ${_partSize ~/ _kMB}MB');

    final tmp = await getTemporaryDirectory();
    _sessionDir = Directory(
        '${tmp.path}/lc_str_${file.telegramMessageId}_${DateTime.now().millisecondsSinceEpoch}');
    await _sessionDir!.create(recursive: true);

    onBuffer?.call(0.1, false);

    // Download Part 0 first (container headers + first ~35-45s of video)
    await _downloadPartDirect(0);

    if (_disposed) return;

    if (parts.isNotEmpty && parts[0].status == PartStatus.ready) {
      await _startServer();
      onBuffer?.call(1.0, true);
      debugPrint('[Stream] Part 0 ready. HTTP proxy online on port $_serverPort');
    } else {
      throw Exception('Failed to download initial playback buffer');
    }

    // Immediately trigger continuous prefetch ahead
    _scheduleWindowDownloads();
  }

  // ── Priority-Queued Serial Worker ─────────────────────────────────────────

  void _enqueue(int pIdx, {bool urgent = false}) {
    if (pIdx < 0 || pIdx >= parts.length || _disposed) return;
    final part = parts[pIdx];
    if (part.status == PartStatus.ready || part.status == PartStatus.downloading) return;

    _queue.remove(pIdx);
    if (urgent) {
      _queue.insert(0, pIdx);
    } else {
      _queue.add(pIdx);
    }
    _runWorker();
  }

  void _runWorker() {
    if (_workerActive || _disposed) return;
    _workerActive = true;
    _workerLoop();
  }

  Future<void> _workerLoop() async {
    while (!_disposed) {
      if (_queue.isEmpty) {
        // Double-check if any parts in ahead window need prefetching
        _scheduleWindowDownloads();
        if (_queue.isEmpty) break;
      }

      final nextIdx = _queue.removeAt(0);
      if (nextIdx >= parts.length) continue;
      final part = parts[nextIdx];
      if (part.status == PartStatus.ready) continue;

      await _downloadPartDirect(nextIdx);

      // Continuously keep queue filled ahead
      if (!_disposed) {
        _scheduleWindowDownloads();
      }
    }
    _workerActive = false;
  }

  Future<void> _downloadPartDirect(int idx) async {
    if (idx >= parts.length || _disposed) return;
    final part = parts[idx];
    if (part.status == PartStatus.ready) return;

    part.status = PartStatus.downloading;
    try {
      final path = await _fetchPartBytes(part);
      if (_disposed) {
        try { File(path).deleteSync(); } catch (_) {}
        part.status = PartStatus.idle;
        return;
      }
      part.localPath = path;
      part.status    = PartStatus.ready;
      debugPrint('[Stream] Part $idx/$parts.length ready (${part.byteLength ~/ _kMB}MB)');
    } catch (e) {
      part.status = PartStatus.idle;
      debugPrint('[Stream] Part $idx notice: $e');
    }
  }

  // ── TDLib byte-range fetch ────────────────────────────────────────────────

  Future<String> _fetchPartBytes(StreamPart part) async {
    final tdlib    = TdlibService.instance;
    final destPath = '${_sessionDir!.path}/p${part.index.toString().padLeft(4, '0')}.tmp';
    final destFile = File(destPath);

    // If destination part file already exists and is fully downloaded, reuse it
    if (await destFile.exists() && await destFile.length() >= part.byteLength) {
      return destPath;
    }

    final chunkIds = file.chunkMessageIds;
    if (chunkIds.isEmpty) {
      // Single Telegram message: serialized TDLib range download with fast 2MB read chunks
      await tdlib.downloadFileRange(
        file.telegramMessageId,
        destPath: destPath,
        offset: part.byteStart,
        limit:  part.byteLength,
      );
    } else {
      // Multi-chunk file
      await _fetchFromChunks(part, chunkIds, destPath, tdlib);
    }
    return destPath;
  }

  Future<void> _fetchFromChunks(
    StreamPart part,
    List<int> chunkIds,
    String destPath,
    TdlibService tdlib,
  ) async {
    final chunkSize  = (_totalBytes / chunkIds.length).ceil();
    final chunkStart = part.byteStart ~/ chunkSize;
    final chunkEnd   = (part.byteEnd - 1) ~/ chunkSize;

    final sink = File(destPath).openWrite();
    try {
      for (int ci = chunkStart; ci <= chunkEnd && ci < chunkIds.length; ci++) {
        final chunkGlobalStart = ci * chunkSize;
        final chunkGlobalEnd   = min(chunkGlobalStart + chunkSize, _totalBytes);
        final readFrom = max(part.byteStart, chunkGlobalStart) - chunkGlobalStart;
        final readTo   = min(part.byteEnd,   chunkGlobalEnd)   - chunkGlobalStart;
        final cached   = await tdlib.downloadFileToCache(chunkIds[ci]);
        await sink.addStream(File(cached).openRead(readFrom, readTo));
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  // ── Local HTTP server ─────────────────────────────────────────────────────

  Future<void> _startServer() async {
    _server     = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _serverPort = _server!.port;
    debugPrint('[Stream] HTTP proxy listening on port $_serverPort');
    _server!.listen(_handleRequest, onError: (_) {});
  }

  String get streamUrl => 'http://127.0.0.1:$_serverPort/stream';

  String _contentType() {
    final ext = file.extension.toLowerCase();
    if (ext == 'mkv') return 'video/x-matroska';
    if (ext == 'mp4') return 'video/mp4';
    if (ext == 'webm') return 'video/webm';
    if (ext == 'avi') return 'video/x-msvideo';
    if (ext == 'mp3') return 'audio/mpeg';
    if (ext == 'aac') return 'audio/aac';
    if (ext == 'flac') return 'audio/flac';
    return file.mimeType ?? 'application/octet-stream';
  }

  Future<void> _handleRequest(HttpRequest req) async {
    if (_disposed) {
      req.response
        ..statusCode = HttpStatus.serviceUnavailable
        ..close();
      return;
    }

    // Unbuffer output to stream chunks over HTTP socket without latency
    req.response.bufferOutput = false;

    // HEAD request
    if (req.method == 'HEAD') {
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.set('Accept-Ranges', 'bytes')
        ..headers.set('Content-Length', _totalBytes.toString())
        ..headers.set('Content-Type', _contentType());
      await req.response.close();
      return;
    }

    // Parse Range header
    int rangeStart = 0;
    int rangeEnd   = _totalBytes - 1;
    bool isRange   = false;
    final rangeH   = req.headers.value('range');
    if (rangeH != null) {
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeH);
      if (m != null) {
        rangeStart = int.parse(m.group(1)!);
        final es   = m.group(2)!;
        rangeEnd   = es.isNotEmpty ? int.parse(es) : _totalBytes - 1;
        isRange    = true;
      }
    }
    rangeEnd = rangeEnd.clamp(0, _totalBytes - 1);
    final responseLen = rangeEnd - rangeStart + 1;

    // Push prefetch window forward based on actual bytes requested
    final nowPart = rangeStart ~/ _partSize;
    if (nowPart >= _currentPart) {
      _currentPart = nowPart;
      _scheduleWindowDownloads();
    }

    req.response.statusCode =
        isRange ? HttpStatus.partialContent : HttpStatus.ok;
    req.response.headers
      ..set('Accept-Ranges', 'bytes')
      ..set('Content-Length', responseLen.toString())
      ..set('Content-Type', _contentType())
      ..set('Connection', 'keep-alive')
      ..set('Cache-Control', 'no-cache');

    if (isRange) {
      req.response.headers
          .set('Content-Range', 'bytes $rangeStart-$rangeEnd/$_totalBytes');
    }

    try {
      int remaining = responseLen;
      int offset    = rangeStart;
      while (remaining > 0 && !_disposed) {
        final pIdx = offset ~/ _partSize;
        if (pIdx >= parts.length) break;
        await _waitForPart(pIdx);
        if (_disposed) break;
        final part = parts[pIdx];
        final lp   = part.localPath;
        if (lp == null || !File(lp).existsSync()) break;
        final pOff  = offset - part.byteStart;
        final avail = part.byteLength - pOff;
        final toR   = min(remaining, avail);
        await req.response.addStream(File(lp).openRead(pOff, pOff + toR));
        offset    += toR;
        remaining -= toR;
      }
    } catch (e) {
      debugPrint('[Stream] Socket event: $e');
    } finally {
      try { await req.response.close(); } catch (_) {}
    }
  }

  Future<void> _waitForPart(int pIdx) async {
    if (pIdx >= parts.length || _disposed) return;
    final part = parts[pIdx];
    if (part.status == PartStatus.ready) return;

    // High-priority insert at head of queue
    _enqueue(pIdx, urgent: true);

    while (part.status != PartStatus.ready && !_disposed) {
      await Future.delayed(const Duration(milliseconds: 30));
    }
  }

  // ── Deep Ahead Window (8 parts = 120 MB buffer) ───────────────────────────

  void _scheduleWindowDownloads() {
    if (_disposed) return;
    final keepS = max(0, _currentPart - _kBehindWindow);
    final keepE = min(parts.length - 1, _currentPart + _kAheadWindow);

    // Evict slices too far behind
    for (final p in parts) {
      if (p.index < keepS && p.status == PartStatus.ready) {
        _evictPart(p);
      }
    }

    // Queue all parts ahead up to keepE
    for (int i = _currentPart; i <= keepE; i++) {
      if (parts[i].status == PartStatus.idle) {
        _enqueue(i, urgent: false);
      }
    }
  }

  void _evictPart(StreamPart part) {
    final path    = part.localPath;
    part.localPath = null;
    part.status   = PartStatus.evicted;
    if (path != null) try { File(path).deleteSync(); } catch (_) {}
  }

  // ── Dispose ───────────────────────────────────────────────────────────────

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _queue.clear();

    try { await _server?.close(force: true); } catch (_) {}

    try {
      await TdlibService.instance.cancelFileDownload(file.telegramMessageId);
    } catch (_) {}

    for (final part in parts) {
      final lp = part.localPath;
      if (lp != null) try { File(lp).deleteSync(); } catch (_) {}
    }
    try {
      if (_sessionDir != null && await _sessionDir!.exists()) {
        await _sessionDir!.delete(recursive: true);
      }
    } catch (_) {}
    debugPrint('[Stream] Session cleanly disposed: ${file.name}');
  }
}
