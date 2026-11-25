import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/aedex_api.dart';
import '../services/browser_ua.dart';

class CaptchaResult {
  final String token;      // Turnstile token para pasar al login de Dart
  final String userAgent;
  final Map<String, String> cookies;

  const CaptchaResult({
    required this.token,
    required this.userAgent,
    required this.cookies,
  });
}

/// Resuelve Cloudflare Turnstile en HTML interceptado (sin código de detección).
///
/// El HTML propio no tiene la guardia de WebView del sitio. El token de
/// Turnstile resultante se usa desde Dart para el POST al callback de NextAuth,
/// que tiene los headers correctos (sec-ch-ua con "Google Chrome").
class CaptchaScreen extends StatefulWidget {
  const CaptchaScreen({super.key});

  @override
  State<CaptchaScreen> createState() => _CaptchaScreenState();
}

class _CaptchaScreenState extends State<CaptchaScreen> {
  static const String _origin =
      'https://aedexnox.com/auth/login?callbackUrl=%2F';
  static const String _readScript = r'''
(() => {
  try {
    return JSON.stringify({
      t: window.__aedexToken || '',
      e: window.__aedexError || ''
    });
  } catch (e) { return '{}'; }
})();
''';

  final String _ua = BrowserUa.fallback;
  InAppWebViewController? _controller;
  String _sitekey = '';
  bool _busy = false;
  String _status = 'Preparando la verificación…';

  @override
  void initState() {
    super.initState();
    _loadSitekey();
  }

  Future<void> _loadSitekey() async {
    try {
      final info = await AedexApi().system();
      if (mounted) setState(() => _sitekey = info.turnstileSitekey);
    } catch (_) {}
  }

  String _html(String sitekey) {
    return '''<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
html,body{margin:0;height:100%;background:#0d0d1c;color:#fff;font-family:system-ui,-apple-system,sans-serif}
.wrap{height:100%;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:18px;padding:24px;box-sizing:border-box;text-align:center}
h1{font-size:17px;margin:0;font-weight:700}p{font-size:12px;color:#8b8ba3;margin:0}
</style></head><body>
<div class="wrap"><h1>Verificación</h1><p>Marca la casilla para continuar</p><div id="ts"></div></div>
<script src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit" async defer><\/script>
<script>
window.__aedexToken='';window.__aedexError='';
var iv=setInterval(function(){
  if(window.turnstile){clearInterval(iv);
    try{window.turnstile.render('#ts',{
      sitekey:'$sitekey',action:'login',theme:'dark',
      callback:function(t){window.__aedexToken=t;},
      'error-callback':function(e){window.__aedexError=String(e||'error');},
      'expired-callback':function(){window.__aedexToken='';}
    });}catch(e){window.__aedexError=String(e);}
  }
},300);
<\/script></body></html>''';
  }

  String _plain(dynamic raw) {
    if (raw == null) return '';
    var v = raw.toString();
    if (v.startsWith('"') && v.endsWith('"')) {
      try { v = jsonDecode(v).toString(); } catch (_) {}
    }
    return v;
  }

  Future<void> _finish(String token) async {
    if (_busy) return;
    setState(() { _busy = true; _status = 'Verificación lista. Entrando…'; });
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
              initialUserScripts: UnmodifiableListView<UserScript>([
                UserScript(
                  source: "window.chrome = window.chrome || { runtime: {} };",
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                ),
              ]),
              initialSettings: InAppWebViewSettings(
                userAgent: _ua,
                javaScriptEnabled: true,
                domStorageEnabled: true,
                thirdPartyCookiesEnabled: true,
                mediaPlaybackRequiresUserGesture: false,
                requestedWithHeaderOriginAllowList: <String>{},
                useShouldInterceptRequest: true,
              ),
              onWebViewCreated: (controller) {
                _controller = controller;
                controller.loadUrl(
                  urlRequest: URLRequest(url: WebUri(_origin)),
                );
              },
              shouldInterceptRequest: (controller, request) async {
                final u = request.url.toString();
                if (request.isForMainFrame != false &&
                    u.startsWith('https://aedexnox.com/auth/login')) {
                  final key = _sitekey.isNotEmpty
                      ? _sitekey
                      : '0x4AAAAAAGKc99U551pyrOVT';
                  return WebResourceResponse(
                    contentType: 'text/html',
                    contentEncoding: 'utf-8',
                    data: Uint8List.fromList(utf8.encode(_html(key))),
                  );
                }
                return null;
              },
              onLoadStop: (controller, url) async {
                final current = url?.toString() ?? '';
                if (current == 'about:blank') return;
                if (mounted) {
                  setState(() =>
                      _status = 'Marca la casilla de Cloudflare para continuar.');
                }
                for (var i = 0; i < 60; i++) {
                  await Future<void>.delayed(const Duration(milliseconds: 800));
                  if (!mounted || _busy) return;
                  final raw = await controller.evaluateJavascript(
                      source: _readScript);
                  Map<String, dynamic> d = {};
                  try {
                    final text = _plain(raw);
                    if (text.isNotEmpty) {
                      d = jsonDecode(text) as Map<String, dynamic>;
                    }
                  } catch (_) {}
                  final token = (d['t'] ?? '') as String;
                  final err = (d['e'] ?? '') as String;
                  if (token.isNotEmpty) {
                    await _finish(token);
                    return;
                  }
                  if (err.isNotEmpty && mounted) {
                    setState(() =>
                        _status = 'Cloudflare: $err. Pulsa Recargar.');
                  }
                }
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(
                'Este paso verifica tu identidad de forma segura.',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: 0.45),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
