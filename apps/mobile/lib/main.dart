import 'package:flutter/material.dart';

import 'app/app_scope.dart';
import 'app/shell.dart';
import 'core/theme.dart';
import 'data/api.dart';
import 'data/auth_repo.dart';
import 'features/auth/login_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final auth = AuthRepo();
  runApp(SoundFlowApp(authRepo: auth, api: Api(auth)));
}

class SoundFlowApp extends StatelessWidget {
  const SoundFlowApp({super.key, required this.authRepo, required this.api});

  final AuthRepo authRepo;
  final Api api;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      authRepo: authRepo,
      api: api,
      child: MaterialApp(
        title: 'SoundFlow',
        debugShowCheckedModeBanner: false,
        theme: Afisha.theme(),
        home: const _Gate(),
      ),
    );
  }
}

/// Ворота входа. Правило офлайн-первости: на старте НЕ ходим в сеть —
/// только проверяем сохранённый пропуск. Есть пропуск → сразу внутрь,
/// даже без интернета. Нет → экран входа.
class _Gate extends StatefulWidget {
  const _Gate();

  @override
  State<_Gate> createState() => _GateState();
}

class _GateState extends State<_Gate> {
  bool? _signedIn;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_signedIn == null) {
      AppScope.of(context).authRepo.hasToken().then((has) {
        if (mounted) setState(() => _signedIn = has);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return switch (_signedIn) {
      null => const Scaffold(body: Center(child: CircularProgressIndicator())),
      true => const Shell(),
      false => LoginScreen(onSignedIn: () => setState(() => _signedIn = true)),
    };
  }
}
