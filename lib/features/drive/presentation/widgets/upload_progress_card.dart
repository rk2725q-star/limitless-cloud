import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../../core/theme/app_theme.dart';
import '../providers/drive_provider.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  UploadProgressOverlay
//  COLLAPSED: ring + "N uploading" + "X MB / Y GB" under title + thin bar
//  EXPANDED : per-task row with bytes, speed badge, bar, ETA
// ─────────────────────────────────────────────────────────────────────────────

// ── Helpers ──────────────────────────────────────────────────────────────────

String _fmtBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String _fmtSpeed(double bps) {
  if (bps <= 0) return '';
  if (bps >= 1024 * 1024) return '${(bps / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  if (bps >= 1024) return '${(bps / 1024).toStringAsFixed(0)} KB/s';
  return '${bps.toStringAsFixed(0)} B/s';
}

String _fmtEta(int secs) {
  if (secs <= 0) return '';
  if (secs < 60) return '${secs}s';
  if (secs < 3600) return '${secs ~/ 60}m ${secs % 60}s';
  final h = secs ~/ 3600;
  final m = (secs % 3600) ~/ 60;
  return '${h}h ${m}m';
}

// ─────────────────────────────────────────────────────────────────────────────

class UploadProgressOverlay extends ConsumerStatefulWidget {
  const UploadProgressOverlay({super.key});

  @override
  ConsumerState<UploadProgressOverlay> createState() =>
      _UploadProgressOverlayState();
}

class _UploadProgressOverlayState extends ConsumerState<UploadProgressOverlay>
    with SingleTickerProviderStateMixin {
  bool _expanded = true;
  late final AnimationController _expandCtrl;
  late final Animation<double> _expandAnim;

  @override
  void initState() {
    super.initState();
    _expandCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 280));
    _expandAnim = CurvedAnimation(parent: _expandCtrl, curve: Curves.easeInOut);
    _expandCtrl.forward();
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

    final active = tasks.where((t) => !t.isComplete && !t.hasError).toList();
    final done = tasks.where((t) => t.isComplete).length;
    final errors = tasks.where((t) => t.hasError).length;

    final overallProgress = active.isEmpty
        ? 1.0
        : active.fold(0.0, (s, t) => s + t.progress) / active.length;

    final overallTransferred =
        tasks.fold(0, (s, t) => s + (t.progress * t.totalBytes).round());
    final overallTotal = tasks.fold(0, (s, t) => s + t.totalBytes);

    final statusText = active.isNotEmpty
        ? '${active.length} uploading'
        : done > 0 && errors == 0
            ? 'All uploads complete ✓'
            : errors > 0
                ? '$errors failed'
                : '';

    final borderColor = errors > 0
        ? AppTheme.error.withValues(alpha: 0.45)
        : active.isNotEmpty
            ? AppTheme.primary.withValues(alpha: 0.35)
            : AppTheme.success.withValues(alpha: 0.45);

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
            border: Border.all(color: borderColor),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.38),
                blurRadius: 28,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Header ──────────────────────────────────────────────────────
              GestureDetector(
                onTap: _toggle,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 30,
                        height: 30,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            TweenAnimationBuilder<double>(
                              tween: Tween<double>(
                                  begin: 0,
                                  end: active.isEmpty ? 1.0 : overallProgress),
                              duration: const Duration(milliseconds: 300),
                              builder: (context, val, _) =>
                                  CircularProgressIndicator(
                                value: val,
                                strokeWidth: 3,
                                backgroundColor: AppTheme.surfaceVariant,
                                valueColor: AlwaysStoppedAnimation(
                                  active.isEmpty
                                      ? AppTheme.success
                                      : AppTheme.primary,
                                ),
                              ),
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
                            if (active.isNotEmpty && overallTotal > 0) ...[
                              const SizedBox(height: 2),
                              Text(
                                '${_fmtBytes(overallTransferred)} / ${_fmtBytes(overallTotal)}',
                                style: GoogleFonts.inter(
                                    fontSize: 10,
                                    color: AppTheme.textSecondary),
                              ),
                            ],
                          ],
                        ),
                      ),
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 280),
                        child: const Icon(Icons.keyboard_arrow_up_rounded,
                            color: AppTheme.textSecondary, size: 22),
                      ),
                    ],
                  ),
                ),
              ),

              // ── Overall bar ─────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                child: _ThinGradientBar(
                  value: overallProgress,
                  isError: errors > 0 && active.isEmpty,
                  isDone: active.isEmpty && errors == 0,
                ),
              ),

              // ── Expanded task list ───────────────────────────────────────────
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
//  Individual task row
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

  double _prevProgress = 0;
  DateTime _prevTime = DateTime.now();
  double _speedBps = 0;
  String _etaLabel = '';

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
    if ((newP - old.task.progress).abs() > 0.0005) {
      _barAnim = Tween<double>(begin: _barAnim.value, end: newP)
          .animate(CurvedAnimation(parent: _barCtrl, curve: Curves.easeOut));
      _barCtrl
        ..reset()
        ..forward();

      final now = DateTime.now();
      final dtMs = now.difference(_prevTime).inMilliseconds;
      final dp = newP - _prevProgress;

      if (dtMs >= 200 && dp > 0 && widget.task.totalBytes > 0) {
        final dt = dtMs / 1000.0;
        final bps = (dp * widget.task.totalBytes) / dt;
        final rem = (1.0 - newP) * widget.task.totalBytes;
        final etaSecs = bps > 0 ? (rem / bps).round() : 0;
        setState(() {
          _speedBps = bps;
          _etaLabel = _fmtEta(etaSecs);
        });
        _prevProgress = newP;
        _prevTime = now;
      }
    }
  }

  @override
  void dispose() {
    _barCtrl.dispose();
    super.dispose();
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
    final task = widget.task;
    final accent = _accentColor(task);
    final pct = (task.progress * 100).clamp(0, 100).toInt();

    final transferred =
        task.totalBytes > 0 ? (task.progress * task.totalBytes).round() : 0;
    final total = task.totalBytes;

    final speedLabel = _fmtSpeed(_speedBps);
    final hasSizeInfo = total > 0 && !task.isComplete && !task.hasError;
    final hasSpeedInfo = speedLabel.isNotEmpty && !task.isComplete && !task.hasError;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 5, 12, 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Extension badge
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
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

          // Main column
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Row 1: filename + %
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
                      task.hasError
                          ? 'Error'
                          : task.isComplete
                              ? 'Done'
                              : '$pct%',
                      style: GoogleFonts.outfit(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: accent,
                      ),
                    ),
                  ],
                ),

                // Row 2: bytes transferred / total  +  speed pill
                if (hasSizeInfo || hasSpeedInfo) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (hasSizeInfo)
                        Expanded(
                          child: Text(
                            '${_fmtBytes(transferred)} / ${_fmtBytes(total)}',
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              color: AppTheme.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      if (hasSpeedInfo)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            speedLabel,
                            style: GoogleFonts.outfit(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: accent,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],

                // Row 3: progress bar
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
                    style:
                        GoogleFonts.inter(fontSize: 10, color: AppTheme.error),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),

                // Row 4: ETA + phase label
                if (!task.hasError && !task.isComplete) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (task.totalChunks > 1) ...[
                        Text(
                          'Part ${task.currentChunk}/${task.totalChunks}',
                          style: GoogleFonts.outfit(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.accent,
                          ),
                        ),
                        if (_etaLabel.isNotEmpty || task.progress <= 0.0)
                          Text('  ·  ',
                              style: GoogleFonts.inter(
                                  fontSize: 9, color: AppTheme.textHint)),
                      ],
                      if (task.progress <= 0.0)
                        Text(
                          'Connecting to Telegram…',
                          style: GoogleFonts.inter(
                              fontSize: 9,
                              color: AppTheme.textHint,
                              fontStyle: FontStyle.italic),
                        )
                      else if (_etaLabel.isNotEmpty)
                        Text(
                          '$_etaLabel left',
                          style: GoogleFonts.inter(
                              fontSize: 9, color: AppTheme.textHint),
                        ),
                      if (_etaLabel.isNotEmpty && task.progress >= 0.91)
                        Text('  ·  ',
                            style: GoogleFonts.inter(
                                fontSize: 9, color: AppTheme.textHint)),
                      if (task.progress >= 0.91)
                        Text(
                          task.progress >= 1.0
                              ? 'Finishing…'
                              : 'Sending to Telegram…',
                          style: GoogleFonts.inter(
                              fontSize: 9, color: AppTheme.accent),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(width: 8),

          // Dismiss
          if (task.hasError || task.isComplete)
            GestureDetector(
              onTap: () =>
                  ref.read(driveProvider.notifier).dismissUploadTask(task.taskId),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  task.isComplete ? Icons.check_rounded : Icons.close_rounded,
                  color: accent,
                  size: 15,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Thin gradient progress bar
//  When value == 0.0 and not done/error, shows a pulsing indeterminate shimmer
//  so the user can see activity during the TDLib upload-registration phase.
// ─────────────────────────────────────────────────────────────────────────────

class _ThinGradientBar extends StatefulWidget {
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
  State<_ThinGradientBar> createState() => _ThinGradientBarState();
}

class _ThinGradientBarState extends State<_ThinGradientBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmer;

  @override
  void initState() {
    super.initState();
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: false);
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color c1 = widget.isError
        ? AppTheme.error
        : widget.isDone
            ? AppTheme.success
            : widget.accent ?? AppTheme.primary;
    final Color c2 = widget.isError
        ? AppTheme.error.withValues(alpha: 0.7)
        : widget.isDone
            ? AppTheme.success.withValues(alpha: 0.8)
            : widget.accent != null
                ? widget.accent!.withValues(alpha: 0.7)
                : AppTheme.secondary;

    final isIndeterminate =
        widget.value <= 0.0 && !widget.isDone && !widget.isError;

    return SizedBox(
      height: widget.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.height / 2),
        child: Stack(
          children: [
            // Track
            Container(color: AppTheme.surfaceVariant),

            if (isIndeterminate)
              // Pulsing shimmer sweep for 0% state
              AnimatedBuilder(
                animation: _shimmer,
                builder: (_, __) {
                  final t = _shimmer.value;
                  // Sweep a ~30% wide highlight across the bar
                  final start = (t - 0.35).clamp(0.0, 1.0);
                  final end = (t + 0.05).clamp(0.0, 1.0);
                  return FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: 1.0,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment(start * 2 - 1, 0),
                          end: Alignment(end * 2 - 1, 0),
                          colors: [
                            c1.withValues(alpha: 0.0),
                            c1.withValues(alpha: 0.55),
                            c1.withValues(alpha: 0.0),
                          ],
                          stops: const [0.0, 0.5, 1.0],
                        ),
                      ),
                    ),
                  );
                },
              )
            else
              // Determinate fill
              TweenAnimationBuilder<double>(
                tween:
                    Tween<double>(begin: 0, end: widget.value.clamp(0.0, 1.0)),
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
  }
}
