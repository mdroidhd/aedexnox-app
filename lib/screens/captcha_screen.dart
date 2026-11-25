import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/browser_ua.dart';
import '../services/webview_spoof.dart';

class CaptchaResult {
  final String token;
  final String userAgent;
  final Map<String, String> cookies;

  const CaptchaResult({
    required this.token,
    required this.userAgent,
    required this.cookies,
  });
}

/// Abre la página de login solo para resolver Cloudflare Turnstile y devuelve
/// el token junto con el User-Agent con el que se resolvió (el token va atado
/// a ese UA) y las cookies de la sesión.
class CaptchaScreen extends StatefulWidget {
  const CaptchaScreen({super.key});

  @override
  State<CaptchaScreen> createState() => _CaptchaScreenState();
}

class _CaptchaScreenState extends State<CaptchaScreen> {
  static const String _url = 'https://aedexnox.com/auth/login?callbackUrl=%2F';
  static const String _readScript = r'''
(() => {
  try {
    const el = document.querySelector('input[name="cf-turnstile-response"]');
    if (el && el.value) return el.value;
    const any = document.querySelector('[id$="_response"]');
    return any && any.value ? any.value : '';
  } catch (e) { return ''; }
})();
''';

  InAppWebViewController? _controller;
  String _ua = '';
  bool _spoofed = false;
  bool _busy = false;
  String _status = 'Esperando la verificación de Cloudflare…';
  int _ticks = 0;

  Future<void> _setup(InAppWebViewController controller) async {
    var ua = BrowserUa.fallback;
    try {
      ua = BrowserUa.clean(await InAppWebViewController.getDefaultUserAgent());
    } catch (_) {}
    _ua = ua;
    await controller.setSettings(
      settings: InAppWebViewSettings(
        userAgent: ua,
        javaScriptEnabled: true,
        domStorageEnabled: true,
        thirdPartyCookiesEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        requestedWithHeaderOriginAllowList: <String>{},
      ),
    );
    // about:blank primero para leer el UA-CH real y luego parchear antes de
    // que la web cargue su JS (su guardia mira las marcas del navegador).
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri('about:blank')));
  }

  Future<void> _poll() async {
    if (_busy) return;
    _ticks++;
    final raw = await _controller?.evaluateJavascript(source: _readScript);
    final token = _plain(raw);
    if (token.isNotEmpty && token.length > 20) {
      await _finish(token);
      return;
    }
    if (mounted && _ticks % 4 == 0) {
      setState(() => _status = 'Marca la casilla de Cloudflare para continuar.');
    }
  }

  String _plain(dynamic raw) {
    if (raw == null) return '';
    var v = raw.toString();
    if (v.startsWith('"') && v.endsWith('"')) {
      try {
        v = jsonDecode(v).toString();
      } catch (_) {}
    }
    return v;
  }

  Future<void> _finish(String token) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Verificación lista. Entrando…';
    });
    final cookies = <String, String>{};
    try {
      final list = await CookieManager.instance().getCookies(
        url: WebUri('https://aedexnox.com'),
      );
      for (final c in list) {
        if (c.name.isNotEmpty) cookies[c.name] = c.value;
      }
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pop(
      CaptchaResult(token: token, userAgent: _ua, cookies: cookies),
    );
  }

  @override
  Widget build(BuildContext context) {
    const pink = Color(0xFFFF3563);
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D1C),
      appBar: AppBar(
        title: const Text('Verificación'),
        backgroundColor: const Color(0xFF0D0D1C),
        foregroundColor: Colors.white,
        actions: [
          TextButton(
            onPressed: () => _controller?.reload(),
            child: const Text('Recargar'),
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
                javaScriptEnabled: true,
                domStorageEnabled: true,
                thirdPartyCookiesEnabled: true,
                mediaPlaybackRequiresUserGesture: false,
                requestedWithHeaderOriginAllowList: <String>{},
              ),
              onWebViewCreated: (controller) {
                _controller = controller;
                _setup(controller);
              },
              onLoadStop: (controller, url) async {
                final current = url?.toString() ?? '';
                if (current == 'about:blank') {
                  if (_spoofed) return;
                  _spoofed = true;
                  Map<String, dynamic> uaCh = {};
                  try {
                    final raw = await controller.evaluateJavascript(
                      source: WebViewSpoof.capture,
                    );
                    var text = raw?.toString() ?? '';
                    if (text.startsWith('"') && text.endsWith('"')) {
                      text = jsonDecode(text).toString();
                    }
                    if (text.isNotEmpty && text != 'null') {
                      uaCh = jsonDecode(text) as Map<String, dynamic>;
                    }
                  } catch (_) {}
                  try {
                    await controller.removeAllUserScripts();
                    await controller.addUserScript(
                      userScript: UserScript(
                        source: WebViewSpoof.script(_ua, uaCh),
                        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                        forMainFrameOnly: false,
                      ),
                    );
                  } catch (_) {}
                  await controller.loadUrl(
                    urlRequest: URLRequest(url: WebUri(_url)),
                  );
                  return;
                }
                for (var i = 0; i < 40; i++) {
                  await Future<void>.delayed(const Duration(milliseconds: 700));
                  if (!mounted || _busy) return;
                  await _poll();
                }
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Este paso solo sirve para el captcha. Tus datos se '
                      'envían después desde la app.',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            final raw =
                                await _controller?.evaluateJavascript(source: _readScript);
                            final token = _plain(raw);
                            if (token.isNotEmpty) {
                              await _finish(token);
                            } else {
                              setState(() => _status =
                                  'Aún no hay token. Marca la casilla de Cloudflare.');
                            }
                          },
                    child: const Text('Ya está'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
