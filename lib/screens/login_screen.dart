import 'package:flutter/material.dart';

import '../services/aedex_api.dart';
import '../services/session_service.dart';
import 'captcha_screen.dart';

/// Login de Aedex: formulario nativo en Dart.
///
/// El captcha de Cloudflare se resuelve en una pantalla aparte con un WebView
/// (es el único sitio donde Turnstile funciona en un móvil) y de ahí se saca el
/// token. El POST de credenciales lo hace la app, así que el sitio no ve un
/// navegador integrado.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _verPassword = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      // 1) Captcha en el WebView.
      final captcha = await Navigator.of(context).push<CaptchaResult>(
        MaterialPageRoute(builder: (_) => const CaptchaScreen()),
      );
      if (captcha == null) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = 'Verificación cancelada.';
        });
        return;
      }

      // 2) POST desde Dart con ese token y ese mismo User-Agent.
      final api = AedexApi();
      api.http.seedCookies('aedexnox.com', captcha.cookies);
      final csrfToken = await api.csrf();
      final token = await api.login(
        email: _email.text,
        password: _password.text,
        csrfToken: csrfToken,
        turnstileToken: captcha.token,
        userAgent: captcha.userAgent,
      );

      await SessionService.saveCookies(
        api.http.exportCookies('aedexnox.com'),
      );
      await SessionService.saveAccessToken(token);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const pink = Color(0xFFFF3563);
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D1C),
      appBar: AppBar(
        title: const Text('Cuenta de Aedex'),
        backgroundColor: const Color(0xFF0D0D1C),
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '¡Gracias por volver!',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Entra con tu cuenta de Aedex para leer sin límites.',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    style: const TextStyle(color: Colors.white),
                    decoration: _decoration('Correo electrónico', Icons.mail, pink),
                    validator: (v) {
                      final t = (v ?? '').trim();
                      if (t.isEmpty) return 'Escribe tu correo';
                      if (!t.contains('@') || !t.contains('.')) {
                        return 'Correo no válido';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _password,
                    obscureText: !_verPassword,
                    autofillHints: const [AutofillHints.password],
                    style: const TextStyle(color: Colors.white),
                    decoration: _decoration('Contraseña', Icons.lock, pink).copyWith(
                      suffixIcon: IconButton(
                        icon: Icon(
                          _verPassword ? Icons.visibility_off : Icons.visibility,
                          color: Colors.white38,
                        ),
                        onPressed: () => setState(() => _verPassword = !_verPassword),
                      ),
                    ),
                    validator: (v) =>
                        (v ?? '').isEmpty ? 'Escribe tu contraseña' : null,
                    onFieldSubmitted: (_) => _submit(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      _error!,
                      style: const TextStyle(color: Color(0xFFFF6B8B), fontSize: 13),
                    ),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    height: 52,
                    child: FilledButton(
                      onPressed: _busy ? null : _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: pink,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Entrar',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Al pulsar Entrar se abre la verificación de Cloudflare. '
                    'Marca la casilla y el login se completa solo.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _decoration(String hint, IconData icon, Color accent) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white38),
      prefixIcon: Icon(icon, color: Colors.white38),
      filled: true,
      fillColor: const Color(0xFF161625),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFF2A2A3E)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: accent, width: 1.5),
      ),
      errorStyle: const TextStyle(color: Color(0xFFFF6B8B)),
    );
  }
}
