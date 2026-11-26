import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/aedex_api.dart';
import '../services/session_service.dart';

/// Login en la propia página del sitio, dentro del WebView.
///
/// Es lo que hace la extensión de Mihon: el POST de credenciales y Turnstile
/// los resuelve la web, y la app solo recoge la sesión después. El access_token
/// que necesita el lector lo devuelve `/api/auth/session` con esa cookie.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const String _loginUrl =
      'https://aedexnox.com/auth/login?callbackUrl=%2F';

  /// UA de Chrome móvil limpio: sin `; wv` y sin `Version/4.0`.
  ///
  /// El servidor rechaza con WebViewNotAllowed cualquier UA que no lleve
  /// `Chrome/<n>` (probado), así que el truco de quitarlo no vale aquí.
  static const String _fallbackUa =
      'Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

  static const String _patchScript = r'''
(() => {
  // El sitio rechaza el login si ve X-Requested-With (lo añade el WebView).
  try {
    const drop = (headers) => {
      if (!headers) return;
      if (headers instanceof Headers) {
        headers.delete('X-Requested-With');
      } else if (Array.isArray(headers)) {
        for (let i = headers.length - 1; i >= 0; i--) {
          if (String(headers[i][0]).toLowerCase() === 'x-requested-with') headers.splice(i, 1);
        }
      } else {
        for (const k of Object.keys(headers)) {
          if (k.toLowerCase() === 'x-requested-with') delete headers[k];
        }
      }
    };
    const of = window.fetch;
    window.fetch = function(input, init) {
      try { if (init) drop(init.headers); } catch (e) {}
      return of.call(window, input, init);
    };
    const setH = XMLHttpRequest.prototype.setRequestHeader;
    XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
      if (String(name).toLowerCase() === 'x-requested-with') return;
      return setH.call(this, name, value);
    };
  } catch (e) {}
})();
''';

  InAppWebViewController? _controller;
  bool _busy = false;
  bool _patched = false;
  String _status = 'Inicia sesión en la página. La app recoge la sesión sola.';

  Future<void> _prepare(InAppWebViewController controller) async {
    var ua = _fallbackUa;
    try {
      final raw = await InAppWebViewController.getDefaultUserAgent();
      if (raw.isNotEmpty) ua = _cleanUa(raw);
    } catch (_) {}
    await controller.setSettings(
      settings: InAppWebViewSettings(
        userAgent: ua,
        javaScriptEnabled: true,
        domStorageEnabled: true,
        thirdPartyCookiesEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        requestedWithHeaderOriginAllowList: <String>{},
        useShouldInterceptRequest: false,
      ),
    );
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri('about:blank')));
  }

  /// Limpia el UA del WebView dejando la versión real de Chrome.
  String _cleanUa(String raw) {
    final version =
        RegExp(r'Chrome/([0-9][0-9.]*)').firstMatch(raw)?.group(1) ??
            '131.0.0.0';
    var ua = raw.replaceAll(RegExp(r';\s*wv\b'), '');
    ua = ua.replaceAll(RegExp(r'\bVersion/[0-9.]+\s*'), '');
    if (!ua.contains('Chrome/')) {
      ua = ua.replaceFirst('Mobile Safari', 'Chrome/$version Mobile Safari');
    }
    ua = ua.replaceAll(RegExp(r'\s{2,}'), ' ');
    return ua.trim();
  }

  Future<void> _inject(controller) async {
    await controller.removeAllUserScripts();
    await controller.addUserScript(
      userScript: UserScript(
        source: _patchScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: false,
      ),
    );
  }

  Future<void> _checkGuard() async {
    try {
      final raw = await _controller?.evaluateJavascript(
        source: 'document.body ? document.body.innerText.slice(0, 400) : ""',
      );
      final text = raw?.toString() ?? '';
      if (text.contains('Abre Aedex en tu navegador')) {
        if (mounted) {
          setState(() => _status =
              'La web sigue detectando el navegador integrado. Pulsa Recargar.');
        }
      }
    } catch (_) {}
  }

  Future<void> _pickSession() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Recogiendo la sesión…';
    });
    try {
      final values = <String, String>{};
      final list = await CookieManager.instance().getCookies(
        url: WebUri('https://aedexnox.com'),
      );
      for (final c in list) {
        if (c.name.isNotEmpty) values[c.name] = c.value;
      }
      if (!values.keys.any((k) => k.toLowerCase().contains('session-token'))) {
        setState(() {
          _busy = false;
          _status = 'Aún no hay sesión. Termina el login en la página y '
              'vuelve a pulsar Listo.';
        });
        return;
      }

      await SessionService.saveCookies(values);
      final api = AedexApi();
      api.http.seedCookies('aedexnox.com', values);
      final token = await api.ensureAccessToken();
      if (token == null || token.isEmpty) {
        setState(() {
          _busy = false;
          _status = 'Sesión guardada, pero el sitio no dio access_token. '
              'Pulsa Listo otra vez en unos segundos.';
        });
        return;
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'No se pudo recoger la sesión: $e';
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
        actions: [
          TextButton(
            onPressed: _busy ? null : _pickSession,
            child: const Text('Listo'),
          ),
          IconButton(
            tooltip: 'Recargar',
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller?.reload(),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: pink.withValues(alpha: 0.12),
            padding: const EdgeInsets.all(12),
            child: Text(
              _status,
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri('about:blank')),
              initialSettings: InAppWebViewSettings(
                userAgent: _fallbackUa,
                javaScriptEnabled: true,
                domStorageEnabled: true,
                thirdPartyCookiesEnabled: true,
                mediaPlaybackRequiresUserGesture: false,
                requestedWithHeaderOriginAllowList: <String>{},
              ),
              onWebViewCreated: (controller) {
                _controller = controller;
                _prepare(controller);
              },
              onLoadStop: (controller, url) async {
                final current = url?.toString() ?? '';
                if (current == 'about:blank') {
                  if (_patched) return;
                  _patched = true;
                  await _inject(controller);
                  await controller.loadUrl(
                    urlRequest: URLRequest(url: WebUri(_loginUrl)),
                  );
                  return;
                }
                if (current.contains('/auth/login')) {
                  await _checkGuard();
                  return;
                }
                // Ya no estamos en el login: la web ha iniciado sesión.
                if (mounted) {
                  setState(() => _status = 'Sesión iniciada. Recogiendo…');
                }
                await _pickSession();
              },
            ),
          ),
        ],
      ),
    );
  }
}
