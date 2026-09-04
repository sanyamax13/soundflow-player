import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme.dart';

/// Вход один раз: логин + пароль. Дальше приложение живёт по пропуску,
/// в том числе офлайн.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onSignedIn});

  final VoidCallback onSignedIn;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _login = TextEditingController(text: 'alex');
  final _pass = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _login.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.of(context).authRepo.login(_login.text.trim(), _pass.text);
      if (mounted) widget.onSignedIn();
    } catch (_) {
      if (mounted) setState(() => _error = 'Не вошло. Проверь пароль и что сервер запущен.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('SoundFlow',
                    style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, color: Afisha.lime)),
                const SizedBox(height: 28),
                TextField(
                  controller: _login,
                  decoration: const InputDecoration(labelText: 'Логин'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pass,
                  obscureText: true,
                  onSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(labelText: 'Пароль'),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Войти'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!, style: const TextStyle(color: Afisha.lime)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
