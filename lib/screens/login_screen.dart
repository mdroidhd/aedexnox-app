import 'dart:collection';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/aedex_api.dart';
import '../services/session_service.dart';

/// Login en la página propia del sitio dentro de un WebView.
///
/// La web bloquea WebViews con dos comprobaciones de cliente:
///  - UA con `; wv` o `Version/4.0 ... Chrome`.
///  - UA-CH con marca "Google Chrome" y `window.chrome` indefinido.
/// Aquí se usa un UA de Chrome móvil sin `wv` y se define `window.chrome`
/// antes de que corra el JS del sitio. También se quita X-Requested-With.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  InAppWebViewController? _controller;
  bool _saving = false;

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

  Future<void> _finish() async {
    if (_saving) return;
    setState(() => _saving = true);
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            token == null
                ? 'Cookies guardadas. Si no hay token, reinicia la app y vuelve a abrir la cuenta.'
                : 'Sesión guardada. Ya puedes leer más de 3 capítulos.',
          ),
        ),
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo guardar la sesión: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cuenta de Aedex'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _finish,
            child: const Text('Listo'),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: const Color(0xFFFF3563).withOpacity(0.12),
            padding: const EdgeInsets.all(12),
            child: const Text(
              'Inicia sesión aquí. Cuando termines, pulsa "Listo": la app '
              'guardará las cookies y las usará para el resto de capítulos.',
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
          if (_saving)
            const LinearProgressIndicator()
          else
            const SizedBox(height: 4),
        ],
      ),
    );
  }
}
