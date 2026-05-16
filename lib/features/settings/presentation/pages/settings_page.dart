import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/constants/app_routes.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/file_utils.dart';
import '../../../auth/data/telegram_auth_service.dart';
import '../../../drive/presentation/providers/drive_provider.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(userStatsProvider);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(backgroundColor: AppTheme.background, title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Profile card
          stats.when(
            data: (data) => _ProfileCard(data: data),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
          const SizedBox(height: 20),

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

          Text('About', style: AppTheme.titleMedium.copyWith(color: AppTheme.textSecondary)),
          const SizedBox(height: 8),
          const _SettingCard(children: [
            _InfoRow(label: 'App Name', value: AppConstants.appName),
            _InfoRow(label: 'Version', value: AppConstants.appVersion),
            _InfoRow(label: 'Backend', value: 'Telegram MTProto API'),
          ]),
          const SizedBox(height: 24),

          // Logout
          SizedBox(
            width: double.infinity,
            height: 52,
            child: OutlinedButton.icon(
              onPressed: () => _logout(context, ref),
              icon: const Icon(Icons.logout_rounded, color: AppTheme.error),
              label: const Text('Sign Out', style: TextStyle(color: AppTheme.error, fontWeight: FontWeight.w600)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppTheme.error),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
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

class _ProfileCard extends StatelessWidget {
  final Map<String, dynamic> data;
  const _ProfileCard({required this.data});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF1A2040), Color(0xFF1A1535)]),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.primary.withValues(alpha:0.2)),
      ),
      child: Row(
        children: [
          Container(
            width: 56, height: 56,
            decoration: const BoxDecoration(gradient: AppTheme.primaryGradient, shape: BoxShape.circle),
            child: const Icon(Icons.person_rounded, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 16),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(data['displayName'] ?? 'User', style: AppTheme.titleLarge),
            Text(data['phoneNumber'] ?? '', style: AppTheme.bodyMedium.copyWith(color: AppTheme.primary)),
          ]),
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
