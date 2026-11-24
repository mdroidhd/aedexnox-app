import 'dart:collection';
import 'dart:convert';
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
/// Se fuerza un UA limpio, se oculta "Google Chrome" de UA-CH y se define
/// `window.chrome` antes de que corra el JS del sitio.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  InAppWebViewController? _controller;
  bool _saving = false;
  String _debug = '';

  static const String _cleanUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  static const String _loginScript = r'''
(() => {
  const CLEAN_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  const CLEAN_DATA = {
    brands: [
      { brand: 'Chromium', version: '131' },
      { brand: 'Not_A Brand', version: '24' }
    ],
    mobile: false,
    platform: 'Windows'
  };

  function define(obj, prop, value) {
    try {
      Object.defineProperty(obj, prop, {
        get: () => value,
        configurable: true
      });
    } catch (e) {}
  }

  define(Navigator.prototype, 'userAgent', CLEAN_UA);
  define(navigator, 'userAgent', CLEAN_UA);
  define(Navigator.prototype, 'userAgentData', CLEAN_DATA);
  define(navigator, 'userAgentData', CLEAN_DATA);
  define(navigator, 'webdriver', false);

  window.chrome = window.chrome || {
    runtime: {},
    loadTimes: function() {},
    csi: function() {},
    app: {}
  };

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

  static const String _debugScript = r'''
(() => {
  try {
    return JSON.stringify({
      ua: navigator.userAgent,
      brands: (navigator.userAgentData && navigator.userAgentData.brands || []).map(b => b.brand),
      chrome: typeof window.chrome
    });
  } catch (e) {
    return '';
  }
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

  String _plain(dynamic raw) {
    if (raw == null) return '';
    var value = raw.toString();
    if (value.startsWith('"') && value.endsWith('"')) {
      try {
        value = jsonDecode(value).toString();
      } catch (_) {}
    }
    return value;
  }

  Future<void> _readDebug() async {
    try {
      final raw = await _controller?.evaluateJavascript(source: _debugScript);
      final text = _plain(raw);
      if (mounted && text.isNotEmpty) setState(() => _debug = text);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cuenta de Aedex'),
        actions: [
          IconButton(
            tooltip: 'Recargar',
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller?.reload(),
          ),
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
              'Inicia sesión en la página. Cuando termines, pulsa "Listo": '
              'la app guardará la sesión y la usará para todos los capítulos.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          if (_debug.isNotEmpty)
            Container(
              width: double.infinity,
              color: Colors.black26,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Text(
                _debug,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 9, color: Colors.white38),
              ),
            ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri('https://aedexnox.com/auth/login?callbackUrl=%2F'),
              ),
              initialSettings: InAppWebViewSettings(
                userAgent: _cleanUa,
                javaScriptEnabled: true,
                domStorageEnabled: true,
                thirdPartyCookiesEnabled: true,
                mediaPlaybackRequiresUserGesture: false,
              ),
              initialUserScripts: UnmodifiableListView<UserScript>([
                UserScript(
                  source: _loginScript,
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                  forMainFrameOnly: false,
                ),
              ]),
              onWebViewCreated: (controller) {
                _controller = controller;
              },
              onLoadStop: (controller, url) async {
                await _readDebug();
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
