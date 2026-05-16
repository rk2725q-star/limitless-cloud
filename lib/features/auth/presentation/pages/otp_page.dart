import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_routes.dart';
import '../../../../core/theme/app_theme.dart';
import '../../data/telegram_auth_service.dart';

class OtpPage extends ConsumerStatefulWidget {
  final Map<String, dynamic> args;
  const OtpPage({super.key, required this.args});

  @override
  ConsumerState<OtpPage> createState() => _OtpPageState();
}

class _OtpPageState extends ConsumerState<OtpPage> {
  final List<TextEditingController> _controllers = List.generate(5, (_) => TextEditingController());
  final List<FocusNode> _focusNodes = List.generate(5, (_) => FocusNode());
  bool _isLoading = false;
  String? _errorMessage;
  int _resendCountdown = 60;
  bool _canResend = false;

  late String _phone;
  late String _phoneCodeHash;

  @override
  void initState() {
    super.initState();
    _phone = widget.args['phone'] ?? '';
    _phoneCodeHash = widget.args['phoneCodeHash'] ?? '';
    _startResendTimer();
  }

  void _startResendTimer() {
    setState(() {
      _resendCountdown = 60;
      _canResend = false;
    });
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return false;
      setState(() {
        _resendCountdown--;
        if (_resendCountdown <= 0) _canResend = true;
      });
      return _resendCountdown > 0;
    });
  }

  String get _otpCode => _controllers.map((c) => c.text).join();

  void _onOtpChanged(String value, int index) {
    if (value.isNotEmpty && index < 4) {
      _focusNodes[index + 1].requestFocus();
    }
    if (value.isEmpty && index > 0) {
      _focusNodes[index - 1].requestFocus();
    }
    if (_otpCode.length == 5) {
      _verifyOTP();
    }
  }

  Future<void> _verifyOTP() async {
    if (_otpCode.length < 5) {
      setState(() => _errorMessage = 'Please enter all 5 digits');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final authService = ref.read(telegramAuthServiceProvider);
    final result = await authService.verifyCode(
      phone: _phone,
      phoneCodeHash: _phoneCodeHash,
      code: _otpCode,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (result.success) {
      if (result.needsPassword) {
        // 2FA is enabled — navigate to password screen
        Navigator.of(context).pushNamed(
          AppRoutes.twoFactor,
          arguments: {'session_string': result.sessionString},
        );
      } else {
        // Fully authenticated — go home
        Navigator.of(context).pushNamedAndRemoveUntil(
          AppRoutes.home,
          (route) => false,
        );
      }
    } else {
      setState(() => _errorMessage = result.error ?? 'Invalid code');
      for (final c in _controllers) { c.clear(); }
      _focusNodes[0].requestFocus();
    }
  }

  Future<void> _resendOTP() async {
    if (!_canResend) return;
    final authService = ref.read(telegramAuthServiceProvider);
    await authService.sendCode(_phone);
    _startResendTimer();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('OTP resent to your Telegram account')),
      );
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) { c.dispose(); }
    for (final f in _focusNodes) { f.dispose(); }
    super.dispose();
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

              // ── Icon ──────────────────────────────────────────────────────
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha:0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppTheme.primary.withValues(alpha:0.3)),
                ),
                child: const Icon(Icons.message_rounded, color: AppTheme.primary, size: 36),
              )
                  .animate()
                  .scale(duration: 500.ms, curve: Curves.elasticOut),

              const SizedBox(height: 28),

              Text('Verify your\nTelegram Code', style: AppTheme.displayLarge)
                  .animate()
                  .fadeIn(delay: 100.ms)
                  .slideX(begin: -0.2, end: 0),

              const SizedBox(height: 12),

              RichText(
                text: TextSpan(
                  style: AppTheme.bodyMedium.copyWith(height: 1.6),
                  children: [
                    const TextSpan(text: 'Code sent to your Telegram app for\n'),
                    TextSpan(
                      text: _phone,
                      style: AppTheme.bodyMedium.copyWith(
                        color: AppTheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ).animate().fadeIn(delay: 250.ms),

              const SizedBox(height: 48),

              // ── OTP Input Fields ──────────────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: List.generate(5, (i) => _buildOtpBox(i)),
              ).animate().fadeIn(delay: 350.ms).slideY(begin: 0.2, end: 0),

              if (_errorMessage != null) ...[
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.error.withValues(alpha:0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.error.withValues(alpha:0.3)),
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

              // ── Verify Button ──────────────────────────────────────────────
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _verifyOTP,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
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
                          'Verify & Continue',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                ),
              ).animate().fadeIn(delay: 500.ms),

              const SizedBox(height: 28),

              // ── Resend ────────────────────────────────────────────────────
              Center(
                child: GestureDetector(
                  onTap: _canResend ? _resendOTP : null,
                  child: RichText(
                    text: TextSpan(
                      style: AppTheme.bodyMedium,
                      children: [
                        const TextSpan(text: "Didn't receive the code? "),
                        TextSpan(
                          text: _canResend
                              ? 'Resend'
                              : 'Resend in ${_resendCountdown}s',
                          style: TextStyle(
                            color: _canResend ? AppTheme.primary : AppTheme.textHint,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ).animate().fadeIn(delay: 600.ms),

              const SizedBox(height: 32),

              // ── Telegram Note ─────────────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF229ED9).withValues(alpha:0.1),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFF229ED9).withValues(alpha:0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, color: Color(0xFF229ED9), size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Open your Telegram app → check messages from "Telegram" to find your code.',
                        style: AppTheme.bodyMedium.copyWith(
                          color: const Color(0xFF229ED9).withValues(alpha:0.9),
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ).animate().fadeIn(delay: 700.ms),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOtpBox(int index) {
    return SizedBox(
      width: 56,
      height: 64,
      child: TextFormField(
        controller: _controllers[index],
        focusNode: _focusNodes[index],
        textAlign: TextAlign.center,
        keyboardType: TextInputType.number,
        maxLength: 1,
        style: AppTheme.headlineMedium.copyWith(fontWeight: FontWeight.w700),
        decoration: InputDecoration(
          counterText: '',
          contentPadding: EdgeInsets.zero,
          filled: true,
          fillColor: AppTheme.surfaceVariant,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: AppTheme.cardBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: AppTheme.cardBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: AppTheme.primary, width: 2),
          ),
        ),
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        onChanged: (v) => _onOtpChanged(v, index),
      ),
    );
  }
}
