import 'package:chatdocsflutter/theme/palette.dart';
import 'package:chatdocsflutter/user_authentication/user_auth.dart';
import 'package:chatdocsflutter/widgets/common_widgets.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class LoginSignupScreen extends StatefulWidget {
  const LoginSignupScreen({super.key});

  @override
  State<LoginSignupScreen> createState() => _LoginSignupScreenState();
}

class _LoginSignupScreenState extends State<LoginSignupScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isSignUp = false;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<UserAuth>();

    return Scaffold(
      backgroundColor: Palette.bg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'ChatDocs',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: Palette.ink,
                    letterSpacing: -0.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  'ask questions about your own documents',
                  style: TextStyle(color: Palette.inkMuted, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Palette.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Palette.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _isSignUp ? 'create an account' : 'log in',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                          color: Palette.ink,
                        ),
                      ),
                      const SizedBox(height: 20),
                      _AuthField(
                        controller: _emailController,
                        label: 'email',
                        keyboardType: TextInputType.emailAddress,
                      ),
                      const SizedBox(height: 12),
                      _AuthField(
                        controller: _passwordController,
                        label: 'password',
                        obscure: true,
                      ),
                      if (auth.errorMessage != null) ...[
                        const SizedBox(height: 16),
                        ErrorBanner(message: auth.errorMessage!),
                      ],
                      const SizedBox(height: 20),
                      PrimaryButton(
                        label: _isSignUp ? 'sign up' : 'log in',
                        isLoading: auth.isLoading,
                        onPressed: () async {
                          final email = _emailController.text.trim();
                          final password = _passwordController.text.trim();
                          final success = _isSignUp
                              ? await auth.signUp(email, password)
                              : await auth.signIn(email, password);
                          if (success && _isSignUp && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'check your email to confirm your account',
                                ),
                              ),
                            );
                          }
                        },
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => setState(() => _isSignUp = !_isSignUp),
                        child: Text(
                          _isSignUp
                              ? 'already have an account? log in'
                              : "don't have an account? sign up",
                          style: const TextStyle(color: Palette.slate),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool obscure;
  final TextInputType? keyboardType;

  const _AuthField({
    required this.controller,
    required this.label,
    this.obscure = false,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      style: const TextStyle(color: Palette.ink),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Palette.inkMuted),
        filled: true,
        fillColor: Palette.bg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
      ),
    );
  }
}
