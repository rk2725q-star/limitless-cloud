import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_routes.dart';
import '../../../../core/theme/app_theme.dart';
import '../../data/telegram_auth_service.dart';

class TwoFactorPage extends ConsumerStatefulWidget {
  const TwoFactorPage({super.key});

  @override
  ConsumerState<TwoFactorPage> createState() => _TwoFactorPageState();
}

class _TwoFactorPageState extends ConsumerState<TwoFactorPage> {
  final _controller = TextEditingController();
  bool _isLoading = false;
  bool _obscure = true;
  String? _errorMessage;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final pwd = _controller.text.trim();
    if (pwd.isEmpty) {
      setState(() => _errorMessage = 'Enter your 2FA password');
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final authService = ref.read(telegramAuthServiceProvider);
    final result = await authService.verifyPassword(pwd);

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (result.success) {
      Navigator.of(context).pushNamedAndRemoveUntil(
        AppRoutes.home,
        (route) => false,
      );
    } else {
      setState(() => _errorMessage = result.error ?? 'Wrong password');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 16),

              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  color: AppTheme.secondary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppTheme.secondary.withValues(alpha: 0.3)),
                ),
                child: const Icon(Icons.lock_rounded, color: AppTheme.secondary, size: 36),
              ).animate().scale(duration: 500.ms, curve: Curves.elasticOut),

              const SizedBox(height: 28),

              Text('Two-Step\nVerification', style: AppTheme.displayLarge)
                  .animate()
                  .fadeIn(delay: 100.ms)
                  .slideX(begin: -0.2, end: 0),

              const SizedBox(height: 12),

              Text(
                'Your Telegram account has 2FA enabled.\nEnter your cloud password to continue.',
                style: AppTheme.bodyMedium.copyWith(height: 1.6),
              ).animate().fadeIn(delay: 250.ms),

              const SizedBox(height: 48),

              Text(
                'CLOUD PASSWORD',
                style: AppTheme.labelLarge.copyWith(letterSpacing: 1.2),
              ),
              const SizedBox(height: 10),

              TextField(
                controller: _controller,
                obscureText: _obscure,
                style: AppTheme.titleMedium,
                onSubmitted: (_) => _verify(),
                decoration: InputDecoration(
                  hintText: 'Enter your 2FA password',
                  prefixIcon: const Icon(Icons.lock_outline_rounded,
                      color: AppTheme.textHint, size: 20),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                      color: AppTheme.textHint,
                      size: 20,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ).animate().fadeIn(delay: 350.ms),

              if (_errorMessage != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.error.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.error.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: AppTheme.error, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: AppTheme.bodyMedium.copyWith(color: AppTheme.error),
                        ),
                      ),
                    ],
                  ),
                ).animate().shakeX(),
              ],

              const SizedBox(height: 40),

              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _verify,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.secondary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Text(
                          'Confirm Password',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                ),
              ).animate().fadeIn(delay: 500.ms),

              const SizedBox(height: 24),

              Center(
                child: Text(
                  'This is the password you set in Telegram Settings → Privacy & Security → Two-Step Verification.',
                  style: AppTheme.bodyMedium.copyWith(color: AppTheme.textHint),
                  textAlign: TextAlign.center,
                ),
              ).animate().fadeIn(delay: 600.ms),
            ],
          ),
        ),
      ),
    );
  }
}
