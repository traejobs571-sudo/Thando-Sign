import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';

import '../../services/db_service.dart';
import '../../utils/validators.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/primary_button.dart';
import '../../theme/app_theme.dart';

/// Self-serve password reset: enter the account email, the system validates
/// it and issues a 6-digit code (shown on screen — there is no mail
/// backend), then the user sets a new password.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  int _step = 0;
  bool _loading = false;
  String? _error;
  String? _issuedCode;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _requestCode() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final code = await context.read<DbService>().createPasswordReset(
        _email.text,
      );
      if (!mounted) return;
      if (code == null) {
        setState(() => _error = 'No account found with that email.');
      } else {
        setState(() {
          _issuedCode = code;
          _step = 1;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Something went wrong — try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reset() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ok = await context.read<DbService>().resetPasswordWithCode(
        _email.text,
        _code.text,
        _password.text,
      );
      if (!mounted) return;
      if (!ok) {
        setState(() => _error = 'Invalid or expired code — request a new one.');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Password reset — sign in with your new password.'),
          ),
        );
        context.go('/login');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Something went wrong — try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppGradients.dark),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: GlassCard(
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _step == 0 ? 'Forgot password' : 'Reset password',
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _step == 0
                            ? 'Enter your account email to get a reset code.'
                            : 'Enter the code and choose a new password.',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 22),
                      TextFormField(
                        controller: _email,
                        enabled: _step == 0,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          prefixIcon: Icon(Icons.email_outlined),
                        ),
                        validator: Validators.email,
                      ),
                      if (_step == 0) ...[
                        const SizedBox(height: 20),
                        PrimaryButton(
                          label: 'Get reset code',
                          icon: Icons.vpn_key_outlined,
                          isLoading: _loading,
                          onPressed: _requestCode,
                        ),
                      ] else ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: AppColors.accent.withValues(alpha: 0.4),
                            ),
                          ),
                          child: Column(
                            children: [
                              Text(
                                'Your reset code (valid 10 min)',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    _issuedCode ?? '',
                                    style: const TextStyle(
                                      fontSize: 30,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 6,
                                      color: AppColors.accent,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Copy code',
                                    icon: const Icon(
                                      Icons.copy,
                                      color: Colors.white,
                                      size: 18,
                                    ),
                                    onPressed: () => Clipboard.setData(
                                      ClipboardData(text: _issuedCode ?? ''),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _code,
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          decoration: const InputDecoration(
                            labelText: '6-digit code',
                            prefixIcon: Icon(Icons.pin_outlined),
                            counterText: '',
                          ),
                          validator: (v) => (v == null || v.trim().length != 6)
                              ? 'Enter the 6-digit code'
                              : null,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _password,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'New password',
                            prefixIcon: Icon(Icons.lock_outline),
                          ),
                          validator: Validators.password,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _confirm,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'Confirm password',
                            prefixIcon: Icon(Icons.lock_outline),
                          ),
                          validator: (v) => v != _password.text
                              ? 'Passwords do not match'
                              : null,
                        ),
                        const SizedBox(height: 20),
                        PrimaryButton(
                          label: 'Reset password',
                          icon: Icons.check,
                          isLoading: _loading,
                          onPressed: _reset,
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: _loading
                              ? null
                              : () => setState(() {
                                  _step = 0;
                                  _issuedCode = null;
                                  _error = null;
                                }),
                          child: const Text('Use a different email'),
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: const TextStyle(color: AppColors.error),
                        ),
                      ],
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => context.go('/login'),
                        child: const Text('Back to sign in'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
