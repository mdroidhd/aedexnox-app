import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/aedex_api.dart';
import '../services/session_service.dart';

/// Login en dos fases:
///  1. WebView en la página de login para resolver la verificación de Cloudflare.
///  2. POST de credenciales desde Dart (sin X-Requested-With), como hace la
///     extensión de Keiyoushi. Así el sitio no lo rechaza por ser un WebView.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();

  InAppWebViewController? _controller;
  Timer? _poll;
  bool _verified = false;
  bool _busy = false;
  String _turnstileToken = '';
  String? _error;

  String get _userAgent => Platform.isAndroid
      ? 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36'
      : 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
          'Mobile/15E148 Safari/604.1';

  static const String _loginScript = r'''
(() => {
  try { Object.defineProperty(navigator, 'webdriver', { get: () => false }); } catch (e) {}
  window.chrome = window.chrome || { runtime: {}, loadTimes: function(){}, csi: function(){}, app: {} };

  const dropHeader = (headers) => {
    if (!headers) return;
    if (headers instanceof Headers) {
      headers.delete('X-Requested-With');
    } else if (Array.isArray(headers)) {
      for (let i = headers.length - 1; i >= 0; i--) {
        if (String(headers[i][0]).toLowerCase() === 'x-requested-with') headers.splice(i, 1);
      }
    } else {
      for (const key of Object.keys(headers)) {
        if (key.toLowerCase() === 'x-requested-with') delete headers[key];
      }
    }
  };

  const originalFetch = window.fetch;
  window.fetch = function(input, init) {
    try { if (init) dropHeader(init.headers); } catch (e) {}
    return originalFetch.call(window, input, init);
  };

  const originalSet = XMLHttpRequest.prototype.setRequestHeader;
  XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
    if (String(name).toLowerCase() === 'x-requested-with') return;
    return originalSet.call(this, name, value);
  };
})();
''';

  static const String _tokenScript = r'''
(() => {
  const el = document.querySelector(
    'input[name="cf-turnstile-response"], textarea[name="cf-turnstile-response"], input[name="turnstileToken"]'
  );
  if (el && el.value) return el.value;
  try {
    if (window.turnstile && typeof window.turnstile.getResponse === 'function') {
      return window.turnstile.getResponse() || '';
    }
  } catch (e) {}
  return '';
})();
''';

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(milliseconds: 900), (_) => _checkToken());
  }

  Future<void> _checkToken() async {
    if (_verified || _busy || _controller == null) return;
    dynamic raw;
    try {
      raw = await _controller!.evaluateJavascript(source: _tokenScript);
    } catch (_) {
      return;
    }
    final token = _plain(raw);
    if (token.isEmpty) return;
    _poll?.cancel();
    if (mounted) {
      setState(() {
        _turnstileToken = token;
        _verified = true;
        _error = null;
      });
    }
  }

  String _plain(dynamic raw) {
    if (raw == null) return '';
    var value = raw.toString();
    if (value.startsWith('"') && value.endsWith('"')) {
      try {
        value = jsonDecode(value).toString();
      } catch (_) {}
    }
    return value.trim();
  }

  Future<void> _login() async {
    if (_busy) return;
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Escribe correo y contraseña.');
      return;
    }
    if (_turnstileToken.isEmpty) {
      setState(() => _verified = false);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final api = AedexApi();
      final csrf = await api.csrf();
      final token = await api.login(
        email: email,
        password: password,
        csrfToken: csrf,
        turnstileToken: _turnstileToken,
      );

      final cookies = api.http.exportCookies('aedexnox.com');
      await SessionService.saveCookies(cookies);
      await SessionService.saveAccessToken(token);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sesión iniciada. Ya puedes leer todo.')),
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      final message = error.toString().replaceFirst('Exception: ', '');
      setState(() {
        _busy = false;
        _error = message;
        if (message.toLowerCase().contains('verificaci') ||
            message.toLowerCase().contains('turnstile') ||
            message.toLowerCase().contains('webview')) {
          _verified = false;
          _turnstileToken = '';
          _restartPoll();
        }
      });
    }
  }

  void _restartPoll() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 900), (_) => _checkToken());
  }

  Future<void> _useWebViewSession() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri('https://aedexnox.com'),
      );
      final values = <String, String>{};
      for (final cookie in cookies) {
        if (cookie.name.isNotEmpty) values[cookie.name] = cookie.value;
      }
      await SessionService.saveCookies(values);

      final api = AedexApi();
      final token = await api.sessionToken();
      await SessionService.saveAccessToken(token);

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.toString();
      });
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cuenta de Aedex')),
      body: _verified ? _buildForm() : _buildVerification(),
    );
  }

  Widget _buildVerification() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          color: const Color(0xFFFF3563).withOpacity(0.12),
          padding: const EdgeInsets.all(12),
          child: const Text(
            '1) Resuelve la verificación de Cloudflare en esta página. '
            'No hace falta escribir aquí: el correo y la contraseña van en la '
            'pantalla siguiente.',
            style: TextStyle(fontSize: 12),
          ),
        ),
        Expanded(
          child: InAppWebView(
            initialUrlRequest: URLRequest(
              url: WebUri('https://aedexnox.com/auth/login?callbackUrl=%2F'),
            ),
            initialSettings: InAppWebViewSettings(
              userAgent: _userAgent,
              javaScriptEnabled: true,
              domStorageEnabled: true,
              thirdPartyCookiesEnabled: true,
              mediaPlaybackRequiresUserGesture: false,
            ),
            initialUserScripts: UnmodifiableListView<UserScript>([
              UserScript(
                source: _loginScript,
                injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              ),
            ]),
            onWebViewCreated: (controller) {
              _controller = controller;
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Esperando la verificación...',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: _busy ? null : _useWebViewSession,
                  child: const Text('Usar sesión del WebView'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildForm() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Icon(Icons.verified, color: Colors.greenAccent, size: 56),
        const SizedBox(height: 8),
        const Text(
          'Verificación completada',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Correo',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Contraseña',
            border: OutlineInputBorder(),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: const TextStyle(color: Colors.redAccent, fontSize: 12),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _login,
          child: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Entrar'),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () {
                  setState(() {
                    _verified = false;
                    _turnstileToken = '';
                    _error = null;
                  });
                  _restartPoll();
                },
          child: const Text('Repetir verificación'),
        ),
      ],
    );
  }
}
