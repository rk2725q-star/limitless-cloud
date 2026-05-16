import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_routes.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_theme.dart';
import '../../data/telegram_auth_service.dart';

class SplashPage extends ConsumerStatefulWidget {
  const SplashPage({super.key});

  @override
  ConsumerState<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends ConsumerState<SplashPage>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted) return;

    final authService = ref.read(telegramAuthServiceProvider);
    final isLoggedIn = await authService.isLoggedIn();

    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed(
      isLoggedIn ? AppRoutes.home : AppRoutes.phoneInput,
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // ── Logo ──────────────────────────────────────────────────────
              _buildLogo(),
              const SizedBox(height: 32),

              // ── App Name ──────────────────────────────────────────────────
              Text(
                AppConstants.appName,
                style: AppTheme.displayLarge.copyWith(
                  foreground: Paint()
                    ..shader = const LinearGradient(
                      colors: [Color(0xFF4F8CFF), Color(0xFF7C5CFF)],
                    ).createShader(const Rect.fromLTWH(0, 0, 300, 60)),
                ),
              )
                  .animate()
                  .fadeIn(delay: 600.ms, duration: 800.ms)
                  .slideY(begin: 0.3, end: 0),

              const SizedBox(height: 12),

              Text(
                AppConstants.appTagline,
                style: AppTheme.bodyMedium.copyWith(
                  letterSpacing: 0.5,
                ),
              )
                  .animate()
                  .fadeIn(delay: 900.ms, duration: 600.ms),

              const SizedBox(height: 80),

              // ── Loading Indicator ─────────────────────────────────────────
              _buildLoadingDots(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        return Container(
          width: 110,
          height: 110,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              colors: [Color(0xFF4F8CFF), Color(0xFF7C5CFF)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: AppTheme.primary.withValues(alpha:
                  0.3 + 0.2 * _pulseController.value,
                ),
                blurRadius: 30 + 10 * _pulseController.value,
                spreadRadius: 5 + 5 * _pulseController.value,
              ),
            ],
          ),
          child: const Icon(
            Icons.cloud_rounded,
            color: Colors.white,
            size: 56,
          ),
        );
      },
    )
        .animate()
        .scale(
          begin: const Offset(0.5, 0.5),
          end: const Offset(1.0, 1.0),
          duration: 700.ms,
          curve: Curves.elasticOut,
        )
        .fadeIn(duration: 400.ms);
  }

  Widget _buildLoadingDots() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(3, (i) {
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            color: AppTheme.primary,
            shape: BoxShape.circle,
          ),
        )
            .animate(onPlay: (c) => c.repeat())
            .scaleXY(
              begin: 0.5,
              end: 1.2,
              delay: (200 * i).ms,
              duration: 600.ms,
              curve: Curves.easeInOut,
            )
            .then()
            .scaleXY(
              begin: 1.2,
              end: 0.5,
              duration: 600.ms,
              curve: Curves.easeInOut,
            );
      }),
    ).animate().fadeIn(delay: 1200.ms, duration: 500.ms);
  }
}
