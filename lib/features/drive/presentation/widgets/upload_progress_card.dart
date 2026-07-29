import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../../core/theme/app_theme.dart';
import '../providers/drive_provider.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  UploadProgressOverlay
//
//  A compact, non-intrusive upload progress panel anchored to the bottom.
//
//  COLLAPSED (default):
//    • Thin pill bar showing overall progress + "N uploading" text
//    • Tap to expand
//
//  EXPANDED:
//    • Full card for each upload task with gradient bar, %, speed, ETA
//    • Tap header to collapse
// ─────────────────────────────────────────────────────────────────────────────

class UploadProgressOverlay extends ConsumerStatefulWidget {
  const UploadProgressOverlay({super.key});

  @override
  ConsumerState<UploadProgressOverlay> createState() => _UploadProgressOverlayState();
}

class _UploadProgressOverlayState extends ConsumerState<UploadProgressOverlay>
    with SingleTickerProviderStateMixin {
  bool _expanded = true; // show expanded on first upload, collapse after
  late final AnimationController _expandCtrl;
  late final Animation<double> _expandAnim;

  @override
  void initState() {
    super.initState();
    _expandCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
    _expandAnim = CurvedAnimation(parent: _expandCtrl, curve: Curves.easeInOut);
    _expandCtrl.forward(); // start expanded
  }

  @override
  void dispose() {
    _expandCtrl.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    _expanded ? _expandCtrl.forward() : _expandCtrl.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(driveProvider).uploadTasks;
    if (tasks.isEmpty) return const SizedBox.shrink();

    // Overall progress = average of all active task progresses
    final active = tasks.where((t) => !t.isComplete && !t.hasError).toList();
    final done   = tasks.where((t) => t.isComplete).length;
    final errors = tasks.where((t) => t.hasError).length;
    final overallProgress = active.isEmpty
        ? 1.0
        : active.fold(0.0, (s, t) => s + t.progress) / active.length;

    final statusText = active.isNotEmpty
        ? '${active.length} uploading'
        : done > 0 && errors == 0
            ? 'All uploads complete ✓'
            : errors > 0
                ? '$errors failed'
                : '';

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: errors > 0
                  ? AppTheme.error.withValues(alpha: 0.4)
                  : active.isNotEmpty
                      ? AppTheme.primary.withValues(alpha: 0.35)
                      : AppTheme.success.withValues(alpha: 0.4),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 24,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Collapsed header (always visible) ────────────────────────
              GestureDetector(
                onTap: _toggle,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                  child: Row(
                    children: [
                      // Animated mini progress ring
                      SizedBox(
                        width: 28,
                        height: 28,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            TweenAnimationBuilder<double>(
                              tween: Tween<double>(begin: 0, end: active.isEmpty ? 1.0 : overallProgress),
                              duration: const Duration(milliseconds: 300),
                              builder: (context, val, child) {
                                return CircularProgressIndicator(
                                  value: val,
                                  strokeWidth: 3,
                                  backgroundColor: AppTheme.surfaceVariant,
                                  valueColor: AlwaysStoppedAnimation(
                                    active.isEmpty ? AppTheme.success : AppTheme.primary,
                                  ),
                                );
                              },
                            ),
                            if (active.isEmpty)
                              const Icon(Icons.check_rounded,
                                  size: 13, color: AppTheme.success)
                            else
                              Text(
                                '${(overallProgress * 100).toInt()}',
                                style: GoogleFonts.outfit(
                                    fontSize: 7,
                                    fontWeight: FontWeight.w800,
                                    color: AppTheme.primary),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),

                      // Status text
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              statusText,
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                            if (active.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                tasks.map((t) => t.fileName).take(2).join(', ') +
                                    (tasks.length > 2 ? '…' : ''),
                                style: GoogleFonts.inter(
                                    fontSize: 10,
                                    color: AppTheme.textSecondary),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),

                      // Expand/collapse chevron
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 300),
                        child: const Icon(Icons.keyboard_arrow_up_rounded,
                            color: AppTheme.textSecondary, size: 22),
                      ),
                    ],
                  ),
                ),
              ),

              // ── Thin overall progress bar (always visible) ────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                child: _ThinGradientBar(
                  value: overallProgress,
                  isError: errors > 0 && active.isEmpty,
                  isDone: active.isEmpty && errors == 0,
                ),
              ),

              // ── Expanded: individual task cards ───────────────────────────
              SizeTransition(
                sizeFactor: _expandAnim,
                axisAlignment: -1,
                child: Column(
                  children: [
                    const Divider(height: 1, color: AppTheme.cardBorder),
                    const SizedBox(height: 6),
                    ...tasks.map((t) => _TaskRow(key: ValueKey(t.taskId), task: t)),
                    const SizedBox(height: 6),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Individual task row inside the expanded panel
// ─────────────────────────────────────────────────────────────────────────────

class _TaskRow extends ConsumerStatefulWidget {
  final UploadTask task;
  const _TaskRow({super.key, required this.task});

  @override
  ConsumerState<_TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends ConsumerState<_TaskRow>
    with SingleTickerProviderStateMixin {
  late AnimationController _barCtrl;
  late Animation<double> _barAnim;

  // ETA tracking
  double _prevProgress = 0;
  DateTime _prevTime   = DateTime.now();
  String _speedLabel   = '';
  String _etaLabel     = '';

  @override
  void initState() {
    super.initState();
    _barCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500));
    _barAnim = Tween<double>(begin: 0, end: widget.task.progress)
        .animate(CurvedAnimation(parent: _barCtrl, curve: Curves.easeOut));
    _barCtrl.forward();
  }

  @override
  void didUpdateWidget(_TaskRow old) {
    super.didUpdateWidget(old);
    final newP = widget.task.progress;
    if ((newP - old.task.progress).abs() > 0.001) {
      _barAnim = Tween<double>(begin: _barAnim.value, end: newP)
          .animate(CurvedAnimation(parent: _barCtrl, curve: Curves.easeOut));
      _barCtrl..reset()..forward();

      final now = DateTime.now();
      final dt  = now.difference(_prevTime).inMilliseconds / 1000.0;
      final dp  = newP - _prevProgress;
      if (dt > 0.5 && dp > 0 && widget.task.totalBytes > 0) {
        final bps = (dp * widget.task.totalBytes) / dt;
        final rem = (1.0 - newP) * widget.task.totalBytes;
        final eta = (rem / bps).round();
        setState(() {
          _speedLabel = _fmtSpeed(bps);
          _etaLabel   = _fmtEta(eta);
        });
        _prevProgress = newP;
        _prevTime     = now;
      }
    }
  }

  @override
  void dispose() {
    _barCtrl.dispose();
    super.dispose();
  }

  String _fmtSpeed(double bps) {
    if (bps >= 1024 * 1024) return '${(bps / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    if (bps >= 1024) return '${(bps / 1024).toStringAsFixed(0)} KB/s';
    return '${bps.toStringAsFixed(0)} B/s';
  }

  String _fmtEta(int secs) {
    if (secs <= 0) return '';
    if (secs < 60) return '${secs}s left';
    if (secs < 3600) return '${secs ~/ 60}m left';
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    return '${h}h ${m}m left';
  }

  String _phaseLabel(double p) {
    if (p >= 1.0) return 'Complete ✓';
    if (p >= 0.91) return 'Sending to Telegram…';
    return 'Uploading…';
  }

  Color _accentColor(UploadTask t) {
    if (t.hasError) return AppTheme.error;
    if (t.isComplete) return AppTheme.success;
    if (t.progress >= 0.91) return AppTheme.accent;
    return AppTheme.primary;
  }

  String _ext(String name) {
    final i = name.lastIndexOf('.');
    if (i < 0) return 'FILE';
    return name.substring(i + 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final task   = widget.task;
    final accent = _accentColor(task);
    final pct    = (task.progress * 100).clamp(0, 100).toInt();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Extension badge
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: accent.withValues(alpha: 0.3)),
            ),
            child: Center(
              child: Text(
                _ext(task.fileName).length > 4
                    ? _ext(task.fileName).substring(0, 4)
                    : _ext(task.fileName),
                style: GoogleFonts.outfit(
                  fontSize: 8,
                  fontWeight: FontWeight.w800,
                  color: accent,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),

          // Main info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        task.fileName,
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      task.hasError ? 'Error' : task.isComplete ? 'Done' : '$pct%',
                      style: GoogleFonts.outfit(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: accent,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (!task.hasError)
                  AnimatedBuilder(
                    animation: _barAnim,
                    builder: (_, __) => _ThinGradientBar(
                      value: _barAnim.value,
                      isDone: task.isComplete,
                      isError: false,
                      accent: accent,
                      height: 4,
                    ),
                  ),
                if (task.hasError)
                  Text(
                    task.error ?? 'Upload failed',
                    style: GoogleFonts.inter(fontSize: 10, color: AppTheme.error),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (!task.hasError && !task.isComplete && (_speedLabel.isNotEmpty || _etaLabel.isNotEmpty))
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        if (_speedLabel.isNotEmpty)
                          Text(_speedLabel,
                              style: GoogleFonts.inter(
                                  fontSize: 9, color: AppTheme.textHint)),
                        if (_speedLabel.isNotEmpty && _etaLabel.isNotEmpty)
                          Text('  ·  ',
                              style: GoogleFonts.inter(
                                  fontSize: 9, color: AppTheme.textHint)),
                        if (_etaLabel.isNotEmpty)
                          Text(_etaLabel,
                              style: GoogleFonts.inter(
                                  fontSize: 9, color: AppTheme.textHint)),
                        // Phase label
                        if (task.progress >= 0.91)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Text(
                              _phaseLabel(task.progress),
                              style: GoogleFonts.inter(
                                  fontSize: 9, color: AppTheme.accent),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(width: 8),
          // Dismiss button for error/done
          if (task.hasError || task.isComplete)
            GestureDetector(
              onTap: () => ref.read(driveProvider.notifier)
                  .dismissUploadTask(task.taskId),
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  task.isComplete
                      ? Icons.check_rounded
                      : Icons.close_rounded,
                  color: accent,
                  size: 14,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Thin gradient progress bar (reused in header + task rows)
// ─────────────────────────────────────────────────────────────────────────────

class _ThinGradientBar extends StatelessWidget {
  final double value;
  final bool isDone;
  final bool isError;
  final Color? accent;
  final double height;

  const _ThinGradientBar({
    required this.value,
    required this.isDone,
    required this.isError,
    this.accent,
    this.height = 5,
  });

  @override
  Widget build(BuildContext context) {
    final Color c1 = isError
        ? AppTheme.error
        : isDone
            ? AppTheme.success
            : accent ?? AppTheme.primary;
    final Color c2 = isError
        ? AppTheme.error.withValues(alpha: 0.7)
        : isDone
            ? AppTheme.success.withValues(alpha: 0.8)
            : accent != null
                ? accent!.withValues(alpha: 0.7)
                : AppTheme.secondary;

    return LayoutBuilder(builder: (_, constraints) {
      final w = constraints.maxWidth;
      return SizedBox(
        height: height,
        width: w,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(height / 2),
          child: Stack(
            children: [
              // Track
              Container(color: AppTheme.surfaceVariant),
              // Fill
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: value.clamp(0.0, 1.0)),
                duration: const Duration(milliseconds: 300),
                builder: (context, val, child) {
                  return FractionallySizedBox(
                    widthFactor: val,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [c1, c2]),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      );
    });
  }
}
