import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/constants/app_routes.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/file_utils.dart';
import '../../../../core/services/auto_backup_service.dart';
import '../../../auth/data/telegram_auth_service.dart';
import '../../../drive/data/firestore_metadata_service.dart';
import '../../../drive/presentation/providers/drive_provider.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  AutoBackupConfig _backupConfig = const AutoBackupConfig();
  bool _loadingBackup = true;

  @override
  void initState() {
    super.initState();
    _loadBackupConfig();
  }

  Future<void> _loadBackupConfig() async {
    final cfg = await AutoBackupService.instance.loadConfig();
    if (mounted) {
      setState(() {
        _backupConfig = cfg;
        _loadingBackup = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final stats = ref.watch(userStatsProvider);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Profile card with Nickname & Custom ID ─────────────────────────
          stats.when(
            data: (data) => _ProfileCard(
              data: data,
              onEdit: () => _showEditProfileDialog(context, data),
            ),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
          const SizedBox(height: 20),

          // ── Auto Backup Section (Google Photos style) ─────────────────────
          Row(
            children: [
              const Icon(Icons.backup_rounded, color: AppTheme.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                'Auto Backup (Google Photos Style)',
                style: AppTheme.titleMedium.copyWith(color: AppTheme.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!_loadingBackup) _buildAutoBackupCard(),
          const SizedBox(height: 20),

          // ── Storage Section ───────────────────────────────────────────────
          Text('Storage', style: AppTheme.titleMedium.copyWith(color: AppTheme.textSecondary)),
          const SizedBox(height: 8),
          stats.when(
            data: (data) {
              final used = (data['totalStorageUsed'] ?? 0) as int;
              return _SettingCard(children: [
                _InfoRow(label: 'Storage Used', value: FileUtils.formatFileSize(used)),
                const _InfoRow(label: 'Storage Limit', value: 'Unlimited (Telegram)'),
                const _InfoRow(label: 'Provider', value: 'Telegram Saved Messages'),
              ]);
            },
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
          const SizedBox(height: 20),

          // ── Security Section ──────────────────────────────────────────────
          Text('Security', style: AppTheme.titleMedium.copyWith(color: AppTheme.textSecondary)),
          const SizedBox(height: 8),
          const _SettingCard(children: [
            ListTile(
              leading: Icon(Icons.security_rounded, color: AppTheme.primary),
              title: Text('End-to-End Encryption'),
              subtitle: Text('All files encrypted by Telegram MTProto'),
              trailing: Icon(Icons.check_circle_rounded, color: AppTheme.success, size: 20),
              contentPadding: EdgeInsets.zero,
            ),
            ListTile(
              leading: Icon(Icons.lock_rounded, color: AppTheme.secondary),
              title: Text('Zero-Knowledge Storage'),
              subtitle: Text('We never see your file contents'),
              trailing: Icon(Icons.check_circle_rounded, color: AppTheme.success, size: 20),
              contentPadding: EdgeInsets.zero,
            ),
          ]),
          const SizedBox(height: 20),

          // ── About Section ─────────────────────────────────────────────────
          Text('About', style: AppTheme.titleMedium.copyWith(color: AppTheme.textSecondary)),
          const SizedBox(height: 8),
          const _SettingCard(children: [
            _InfoRow(label: 'App Name', value: AppConstants.appName),
            _InfoRow(label: 'Version', value: AppConstants.appVersion),
            _InfoRow(label: 'Backend', value: 'Telegram MTProto API'),
          ]),
          const SizedBox(height: 24),

          // ── Sign Out ──────────────────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            height: 52,
            child: OutlinedButton.icon(
              onPressed: () => _logout(context, ref),
              icon: const Icon(Icons.logout_rounded, color: AppTheme.error),
              label: const Text('Sign Out',
                  style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.w600)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppTheme.error),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  // ── Auto Backup UI Card ───────────────────────────────────────────────────

  Widget _buildAutoBackupCard() {
    final cfg = _backupConfig;
    final usedMB = (cfg.todayUsageBytes / (1024 * 1024)).toStringAsFixed(1);
    final limitLabel = cfg.dailyLimitMB > 0 ? '${cfg.dailyLimitMB} MB' : 'Unlimited';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Master toggle
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Auto Backup Camera',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
            subtitle: const Text(
              'Automatically upload camera captures to Limitless Cloud',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
            value: cfg.isEnabled,
            activeThumbColor: AppTheme.primary,
            onChanged: (val) async {
              await AutoBackupService.instance.updateConfig(isEnabled: val);
              await _loadBackupConfig();
            },
          ),
          const Divider(height: 20),

          // 2. Folder Source
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_special_rounded, color: AppTheme.folderColor),
            title: const Text('Backup Folder', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              cfg.cameraFolderPath,
              style: const TextStyle(fontSize: 12, color: AppTheme.textHint),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.check_rounded, color: AppTheme.success, size: 18),
          ),

          // 3. Videos toggle (Default only photos)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Backup Camera Videos', style: TextStyle(fontSize: 14)),
            subtitle: const Text('Default is photos only. Enable to also back up videos.',
                style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            value: cfg.backupVideos,
            activeThumbColor: AppTheme.accent,
            onChanged: (val) async {
              await AutoBackupService.instance.updateConfig(backupVideos: val);
              await _loadBackupConfig();
            },
          ),

          const Divider(height: 20),

          // 4. Daily Schedule Window (Runs once per day & terminates)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule_rounded, color: AppTheme.accent),
            title: const Text('Daily Backup Time', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              '${cfg.scheduleLabel}\nRuns once per day and terminates immediately after work.',
              style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
            ),
            trailing: const Icon(Icons.chevron_right_rounded, color: AppTheme.textHint, size: 20),
            onTap: () => _showScheduleDialog(context, cfg.scheduledHour),
          ),

          const Divider(height: 20),

          // 5. Daily Data Limit Selector
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.data_usage_rounded, color: AppTheme.warning),
            title: const Text('Daily Backup Limit', style: TextStyle(fontSize: 14)),
            subtitle: Text('Prevents mobile data overuse: $limitLabel per day',
                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppTheme.surfaceVariant,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                limitLabel,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.primary),
              ),
            ),
            onTap: () => _showDataLimitDialog(context),
          ),

          // 5. Today's usage progress
          if (cfg.dailyLimitMB > 0) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Today\'s usage: $usedMB MB / $limitLabel',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
                Text(
                  '${(cfg.usagePercent * 100).toInt()}%',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: cfg.hasReachedDailyLimit ? AppTheme.error : AppTheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: cfg.usagePercent,
                minHeight: 6,
                backgroundColor: AppTheme.surfaceVariant,
                valueColor: AlwaysStoppedAnimation(
                  cfg.hasReachedDailyLimit ? AppTheme.error : AppTheme.primary,
                ),
              ),
            ),
          ],

          const SizedBox(height: 16),

          // 6. Manual trigger button & Live Status
          StreamBuilder<AutoBackupProgress>(
            stream: AutoBackupService.instance.progressStream,
            initialData: AutoBackupService.instance.currentProgress,
            builder: (context, snapshot) {
              final prog = snapshot.data ?? const AutoBackupProgress();
              final isRunning = prog.status == AutoBackupStatus.backingUp ||
                  prog.status == AutoBackupStatus.scanning;

              return Column(
                children: [
                  if (prog.message.isNotEmpty) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        children: [
                          if (isRunning) ...[
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primary),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                            child: Text(
                              prog.message,
                              style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton.icon(
                      onPressed: isRunning
                          ? null
                          : () {
                              final auth = ref.read(telegramAuthServiceProvider);
                              final meta = ref.read(firestoreServiceProvider);
                              AutoBackupService.instance.runBackup(
                                authService: auth,
                                metadataService: meta,
                                isManual: true,
                              );
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.cloud_upload_rounded, size: 20),
                      label: Text(
                        isRunning ? 'Backing Up…' : 'Back Up Now',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),

          const SizedBox(height: 12),

          // 7. Intelligent Single-Run Daily Status Badge
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: cfg.isCompletedForToday
                  ? AppTheme.success.withValues(alpha: 0.12)
                  : AppTheme.surfaceVariant,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: cfg.isCompletedForToday
                    ? AppTheme.success.withValues(alpha: 0.3)
                    : AppTheme.cardBorder,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  cfg.isCompletedForToday
                      ? Icons.check_circle_rounded
                      : Icons.battery_saver_rounded,
                  size: 18,
                  color: cfg.isCompletedForToday ? AppTheme.success : AppTheme.accent,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        cfg.isCompletedForToday
                            ? 'Today\'s Backup Done (Terminated)'
                            : 'Smart Daily Auto-Backup',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: cfg.isCompletedForToday ? AppTheme.success : AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        cfg.isCompletedForToday
                            ? 'Background process terminated completely. Zero 24/7 battery drain.'
                            : 'Auto-starts once per day at scheduled time, backs up, and terminates.',
                        style: const TextStyle(fontSize: 10, color: AppTheme.textHint),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Daily Schedule Dialog ──────────────────────────────────────────────────

  Future<void> _showScheduleDialog(BuildContext context, int currentHour) async {
    final schedules = [
      (2, 'Overnight (02:00 AM) — Idle & Sleep (Recommended)'),
      (6, 'Early Morning (06:00 AM)'),
      (9, 'Morning (09:00 AM)'),
      (14, 'Afternoon (02:00 PM)'),
      (21, 'Night (09:00 PM)'),
    ];

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: const EdgeInsets.all(20),
        decoration: const BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Select Daily Backup Time',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
            ),
            const SizedBox(height: 6),
            const Text(
              'Runs once per day and terminates immediately after work to save battery.',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            ...schedules.map((s) {
              final isSelected = s.$1 == currentHour;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  s.$1 == 2 ? Icons.nightlight_round : Icons.wb_sunny_rounded,
                  color: isSelected ? AppTheme.primary : AppTheme.textHint,
                ),
                title: Text(
                  s.$2,
                  style: TextStyle(
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    color: isSelected ? AppTheme.primary : AppTheme.textPrimary,
                    fontSize: 13,
                  ),
                ),
                trailing: isSelected
                    ? const Icon(Icons.check_circle_rounded, color: AppTheme.primary)
                    : null,
                onTap: () async {
                  await AutoBackupService.instance.updateConfig(scheduledHour: s.$1);
                  await _loadBackupConfig();
                  if (context.mounted) Navigator.pop(context);
                },
              );
            }),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  // ── Daily Data Limit Dialog ────────────────────────────────────────────────

  Future<void> _showDataLimitDialog(BuildContext context) async {
    final options = [50, 100, 200, 500, 1000, 0]; // 0 = unlimited

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: const EdgeInsets.all(20),
        decoration: const BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Daily Data Limit',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
            const SizedBox(height: 6),
            const Text('Controls background data usage per day:',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            const SizedBox(height: 16),
            ...options.map((mb) {
              final label = mb == 0
                  ? 'Unlimited'
                  : (mb >= 1000 ? '1 GB / day' : '$mb MB / day');
              final isSelected = _backupConfig.dailyLimitMB == mb;

              return ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                title: Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
                trailing: isSelected
                    ? const Icon(Icons.check_circle_rounded, color: AppTheme.primary)
                    : null,
                onTap: () async {
                  Navigator.pop(context);
                  await AutoBackupService.instance.updateConfig(dailyLimitMB: mb);
                  await _loadBackupConfig();
                },
              );
            }),
            ListTile(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              title: const Text('Custom MB…', style: TextStyle(fontWeight: FontWeight.w500)),
              trailing: const Icon(Icons.edit_rounded, size: 18, color: AppTheme.textHint),
              onTap: () {
                Navigator.pop(context);
                _showCustomLimitDialog(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCustomLimitDialog(BuildContext context) async {
    final ctrl = TextEditingController(text: _backupConfig.dailyLimitMB.toString());
    await showDialog(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Custom Daily Limit'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'Limit in MB',
            suffixText: 'MB',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dlgCtx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final val = int.tryParse(ctrl.text.trim());
              if (val != null && val > 0) {
                Navigator.pop(dlgCtx);
                await AutoBackupService.instance.updateConfig(dailyLimitMB: val);
                await _loadBackupConfig();
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // ── Edit Profile & Nickname Dialog ─────────────────────────────────────────

  Future<void> _showEditProfileDialog(
      BuildContext context, Map<String, dynamic> currentData) async {
    final nickCtrl = TextEditingController(
      text: (currentData['nickname'] ?? currentData['displayName'] ?? '').toString(),
    );
    final idCtrl = TextEditingController(
      text: (currentData['customId'] ?? currentData['username'] ?? '').toString(),
    );

    await showDialog(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.edit_rounded, color: AppTheme.primary, size: 22),
            SizedBox(width: 10),
            Text('Edit Nickname & ID'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Set a custom name and unique ID so other Limitless Cloud users can find and share files with you easily.',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: nickCtrl,
              decoration: const InputDecoration(
                labelText: 'Nickname / Display Name',
                hintText: 'e.g. Arun Kumar',
                prefixIcon: Icon(Icons.badge_rounded),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: idCtrl,
              decoration: const InputDecoration(
                labelText: 'Unique ID / Handle',
                hintText: 'e.g. arun_cloud',
                prefixText: '@',
                prefixIcon: Icon(Icons.alternate_email_rounded),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dlgCtx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final newNick = nickCtrl.text.trim();
              final newId = idCtrl.text.trim();
              if (newNick.isNotEmpty || newId.isNotEmpty) {
                await ref.read(telegramAuthServiceProvider).updateNickname(
                      nickname: newNick,
                      customId: newId,
                    );
                ref.invalidate(userStatsProvider);
                if (context.mounted) Navigator.pop(dlgCtx);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _logout(BuildContext context, WidgetRef ref) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Sign Out?'),
        content: const Text('You will need to log in again with your Telegram number.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await ref.read(telegramAuthServiceProvider).logout();
      if (context.mounted) {
        Navigator.pushNamedAndRemoveUntil(context, AppRoutes.phoneInput, (_) => false);
      }
    }
  }
}

// ── Profile Card Widget with Nickname & ID ───────────────────────────────────

class _ProfileCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final VoidCallback onEdit;
  const _ProfileCard({required this.data, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final name = (data['displayName'] ?? 'User').toString();
    final phone = (data['phoneNumber'] ?? '').toString();
    final customId = (data['customId'] ?? data['username'] ?? '').toString();

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF1A2040), Color(0xFF1A1535)]),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: const BoxDecoration(
              gradient: AppTheme.primaryGradient,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                name.isNotEmpty ? name[0].toUpperCase() : 'U',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 24,
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: AppTheme.titleLarge.copyWith(fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (phone.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(phone,
                      style: AppTheme.bodyMedium.copyWith(color: AppTheme.primary)),
                ],
                if (customId.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '@$customId',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.primary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            onPressed: onEdit,
            icon: const Icon(Icons.edit_rounded, color: AppTheme.primary, size: 20),
            tooltip: 'Edit nickname & ID',
          ),
        ],
      ),
    );
  }
}

class _SettingCard extends StatelessWidget {
  final List<Widget> children;
  const _SettingCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(children: children),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Text(label, style: AppTheme.bodyMedium),
          const Spacer(),
          Text(value, style: AppTheme.bodyLarge.copyWith(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
