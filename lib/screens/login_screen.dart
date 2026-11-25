import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/aedex_api.dart';
import '../services/session_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const String _loginUrl =
      'https://aedexnox.com/auth/login?callbackUrl=%2F';

  InAppWebViewController? _controller;
  bool _saving = false;
  bool _preparing = true;
  bool _captured = false;
  bool _uaRetry = false;
  String _cleanUa = '';
  String _debug = '';
  String _postHeaders = '';

  // Modo escritorio: el sitio acepta el login con UA de Chrome de escritorio,
  // pero Cloudflare Turnstile falla al resolver el captcha con UA de escritorio
  // en un dispositivo movil (incoherencia UA/plataforma). Se deja apagado: el
  // captcha debe resolverlo el WebView con su UA movil limpio.
  static const bool _desktopMode = false;

  static const String _desktopUaFallback =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36';

  static const String _mobileUaFallback =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

  String get _fallbackUa => _desktopMode ? _desktopUaFallback : _mobileUaFallback;

  /// UA de escritorio con la version real del motor del WebView.
  String _desktopUa(String rawUa) {
    final m = RegExp(r'Chrome/([0-9][0-9.]*)').firstMatch(rawUa);
    final version = m?.group(1) ?? '144.0.0.0';
    return 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/$version Safari/537.36';
  }

  /// Quita del UA nativo los marcadores que el sitio rechaza.
  String _cleanUserAgent(String raw) {
    if (raw.isEmpty) return raw;
    return raw
        .replaceAll(RegExp(r';\s*wv\b'), '')
        .replaceAll(RegExp(r'\bVersion/4\.0\s+'), '');
  }

  // ---------- 2) Captura el UA-CH real (antes de spoofear nada) ----------
  static const String _captureScript = r'''
(() => {
  try {
    const d = navigator.userAgentData;
    return JSON.stringify({
      ua: navigator.userAgent || '',
      brands: d ? d.brands : [],
      mobile: d ? !!d.mobile : false,
      platform: d ? d.platform : ''
    });
  } catch(e) { return '{}'; }
})();
''';

  // ---------- 3) Parche MINIMO: solo cambia "Android WebView" -> "Google Chrome" ----------
  String _spoofScript(String ua, Map<String, dynamic> uaCh) {
    final rawBrands = (uaCh['brands'] as List? ?? const []);
    final patchedBrands = rawBrands.map<Map<String, String>>((b) {
      final brand = (b['brand'] ?? '') as String;
      final version = (b['version'] ?? '') as String;
      final isWebView = brand.toLowerCase().contains('webview');
      return {'brand': isWebView ? 'Google Chrome' : brand, 'version': version};
    }).toList();

    final mobile = _desktopMode ? false : (uaCh['mobile'] ?? Platform.isAndroid);
    final platform = _desktopMode
        ? 'Linux'
        : (uaCh['platform'] ?? (Platform.isAndroid ? 'Android' : 'iOS'));

    return '''
(() => {
  const UA = ${jsonEncode(ua)};
  const BRANDS = ${jsonEncode(patchedBrands)};
  const MOBILE = ${jsonEncode(mobile)};
  const PLATFORM = ${jsonEncode(platform)};

  const define = (obj, prop, value) => {
    try { Object.defineProperty(obj, prop, { get: () => value, configurable: true }); } catch(e) {}
  };

  // navigator.userAgent coherente con el header
  define(Navigator.prototype, 'userAgent', UA);
  define(navigator, 'userAgent', UA);

  // navigator.userAgentData.brands SIN "Android WebView"
  try {
    const real = navigator.userAgentData;
    if (real) {
      const patched = Object.create(real);

      Object.defineProperty(patched, 'brands',  { get: () => BRANDS,   configurable: true });
      Object.defineProperty(patched, 'mobile',  { get: () => MOBILE,   configurable: true });
      Object.defineProperty(patched, 'platform',{ get: () => PLATFORM, configurable: true });

      const origHigh = real.getHighEntropyValues ? real.getHighEntropyValues.bind(real) : null;
      if (origHigh) {
        Object.defineProperty(patched, 'getHighEntropyValues', {
          configurable: true,
          value: async (hints) => {
            const r = await origHigh(hints);
            if (r) {
              if (Array.isArray(r.brands)) r.brands = BRANDS;
              if (Array.isArray(r.fullVersionList)) {
                r.fullVersionList = r.fullVersionList.map(b =>
                  b.brand.toLowerCase().includes('webview')
                    ? { brand: 'Google Chrome', version: b.version }
                    : b
                );
              }
            }
            return r;
          }
        });
      }

      define(Navigator.prototype, 'userAgentData', patched);
      define(navigator, 'userAgentData', patched);
    }
  } catch(e) {}

  // window.chrome que el WebView no expone por defecto
  try {
    if (typeof window.chrome === 'undefined') {
      window.chrome = { runtime: {}, loadTimes: () => {}, csi: () => {}, app: {} };
    }
  } catch(e) {}

  // Quitar X-Requested-With que añade el JS de la web (axios/fetch).
  // El servidor rechaza el login como WebViewNotAllowed si lo ve.
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
        for (const key of Object.keys(headers)) {
          if (key.toLowerCase() === 'x-requested-with') delete headers[key];
        }
      }
    };
    const originalFetch = window.fetch;
    window.fetch = function(input, init) {
      try { if (init) drop(init.headers); } catch(e) {}
      return originalFetch.call(window, input, init);
    };
    const originalSet = XMLHttpRequest.prototype.setRequestHeader;
    XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
      if (String(name).toLowerCase() === 'x-requested-with') return;
      return originalSet.call(this, name, value);
    };
  } catch(e) {}

  // webdriver false (por seguridad, aunque ya lo suele ser)
  define(Navigator.prototype, 'webdriver', false);
})();
''';
  }

  static const String _debugScript = r'''
(() => {
  try {
    // UA real de la cabecera HTTP (navigator.userAgent lo falseamos, la
    // cabecera no se puede falsear desde JS: es la que ve el servidor).
    if (!window.__aedexHdrStarted) {
      window.__aedexHdrStarted = true;
      fetch('https://httpbin.org/headers', {cache: 'no-store'})
        .then(r => r.json())
        .then(j => {
          const h = (j && j.headers) || {};
          window.__aedexHdr = h['User-Agent'] || h['user-agent'] || '(vacia)';
        })
        .catch(() => { window.__aedexHdr = 'no comprobable'; });
    }
    const ua = navigator.userAgent || '';
    const brands = (navigator.userAgentData && navigator.userAgentData.brands) || [];
    const hdr = window.__aedexHdr || 'comprobando...';
    const bad = /;\s*wv\b|Version\/4\.0|Android WebView/i.test(hdr);
    return JSON.stringify({
      hdr: hdr,
      bad: bad,
      nav: ua,
      brands: brands.map(b => b.brand + '/' + b.version).join(', ')
    });
  } catch(e) { return ''; }
})();
''';


  String _chromeFullVersion(String ua) {
    final m = RegExp(r'Chrome/([0-9][0-9.]*)').firstMatch(ua);
    final v = m?.group(1) ?? '131.0.0.0';
    return v.split('.').length >= 3 ? v : '$v.0.0.0';
  }

  /// Reescribe el User-Agent a nivel de motor con CDP.
  ///
  /// `setSettings(userAgent:)` no siempre llega a los XHR del login; esto sí,
  /// porque cambia la cabecera de todas las peticiones de la sesión. Además
  /// manda client hints de Google Chrome en vez de "Android WebView".
  Future<bool> _applyCdpUserAgent(InAppWebViewController controller) async {
    if (!Platform.isAndroid) return false;
    final ua = _cleanUa.isEmpty ? _fallbackUa : _cleanUa;
    final full = _chromeFullVersion(ua);
    final major = full.split('.').first;
    final metadata = <String, dynamic>{
      'brands': [
        {'brand': 'Chromium', 'version': major},
        {'brand': 'Google Chrome', 'version': major},
        {'brand': 'Not_A Brand', 'version': '24'},
      ],
      'fullVersionList': [
        {'brand': 'Chromium', 'version': full},
        {'brand': 'Google Chrome', 'version': full},
        {'brand': 'Not_A Brand', 'version': '24.0.0.0'},
      ],
      'fullVersion': full,
      'platform': _desktopMode ? 'Linux' : 'Android',
      'platformVersion': _desktopMode ? '6.1.0' : '14.0.0',
      'architecture': _desktopMode ? 'x86' : '',
      'model': _desktopMode ? '' : 'Pixel 8',
      'mobile': !_desktopMode,
      'bitness': _desktopMode ? '64' : '',
      'wow64': false,
    };
    try {
      await controller.callDevToolsProtocolMethod(methodName: 'Network.enable');
    } catch (_) {}
    try {
      await controller.callDevToolsProtocolMethod(
        methodName: 'Network.setUserAgentOverride',
        parameters: {
          'userAgent': ua,
          'acceptLanguage': 'es-ES,es;q=0.9',
          'platform': 'Android',
          'userAgentMetadata': metadata,
        },
      );
      return true;
    } catch (e) {
      debugPrint('cdp ua error: $e');
      return false;
    }
  }

  // ---------- Flujo de preparación ----------
  Future<void> _prepare(InAppWebViewController controller) async {
    try {
      String clean = _fallbackUa;
      try {
        final raw = await InAppWebViewController.getDefaultUserAgent();
        if (raw.isNotEmpty) {
          clean = _desktopMode ? _desktopUa(raw) : _cleanUserAgent(raw);
        }
      } catch (_) {}
      if (clean.isEmpty) clean = _fallbackUa;
      _cleanUa = clean;

      if (_cleanUa.isNotEmpty) {
        await controller.setSettings(
          settings: InAppWebViewSettings(
            userAgent: _cleanUa,
            javaScriptEnabled: true,
            domStorageEnabled: true,
            thirdPartyCookiesEnabled: true,
            mediaPlaybackRequiresUserGesture: false,
            requestedWithHeaderOriginAllowList: <String>{},
            useShouldOverrideUrlLoading: false,
            useShouldInterceptRequest: true,
            useWideViewPort: _desktopMode,
            loadWithOverviewMode: _desktopMode,
            supportZoom: true,
            builtInZoomControls: true,
            displayZoomControls: false,
          ),
        );
      }

      await _applyCdpUserAgent(controller);

      // about:blank para leer UA-CH real ANTES de la web
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri('about:blank')),
      );
    } catch (e) {
      debugPrint('prepare error: $e');
      if (mounted) setState(() => _preparing = false);
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(_loginUrl)));
    }
  }

  Future<void> _applySpoofAndLoad(InAppWebViewController controller) async {
    try {
      final raw = await controller.evaluateJavascript(source: _captureScript);
      final text = _plain(raw);
      Map<String, dynamic> uaCh = {};
      try {
        if (text.isNotEmpty) uaCh = jsonDecode(text) as Map<String, dynamic>;
      } catch (_) {}

      if (_cleanUa.isEmpty) _cleanUa = _fallbackUa;
      final script = _spoofScript(_cleanUa, uaCh);

      await controller.removeAllUserScripts();
      await controller.addUserScript(
        userScript: UserScript(
          source: script,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: false,
        ),
      );

      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(_loginUrl)));
    } catch (e) {
      debugPrint('spoof error: $e');
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(_loginUrl)));
    } finally {
      if (mounted) setState(() => _preparing = false);
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

  Future<void> _readDebug() async {
    try {
      final raw = await _controller?.evaluateJavascript(source: _debugScript);
      final text = _plain(raw);
      if (!mounted || text.isEmpty) return;
      Map<String, dynamic> d = {};
      try {
        d = jsonDecode(text) as Map<String, dynamic>;
      } catch (_) {}
      final hdr = (d['hdr'] ?? '') as String;
      final bad = d['bad'] == true;
      setState(() {
        _debug = bad
            ? 'UA ENVIADO: WebView (el servidor lo rechazara)\n$hdr'
            : 'UA enviado: limpio\n$hdr';
      });
      // Auto-cura: si la cabecera sigue saliendo como WebView, forzamos el UA
      // de reserva y recargamos una sola vez.
      if (bad && !_uaRetry) {
        _uaRetry = true;
        _cleanUa = _fallbackUa;
        final c = _controller;
        if (c != null) {
          await c.setSettings(
            settings: InAppWebViewSettings(
              userAgent: _cleanUa,
              javaScriptEnabled: true,
              domStorageEnabled: true,
              thirdPartyCookiesEnabled: true,
              mediaPlaybackRequiresUserGesture: false,
              requestedWithHeaderOriginAllowList: <String>{},
              useShouldOverrideUrlLoading: false,
            ),
          );
          await _applyCdpUserAgent(c);
          await _applySpoofAndLoad(c);
        }
      }
    } catch (_) {}
  }

  void _showHeaders() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cabeceras del POST de login'),
        content: SingleChildScrollView(
          child: SelectableText(
            _postHeaders.isEmpty
                ? 'Aún no se ha enviado ningún login. Pulsa Continuar en la página y vuelve a mirar.'
                : _postHeaders,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _postHeaders));
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Copiar'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  Future<void> _finish() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri('https://aedexnox.com'),
      );
      final values = <String, String>{};
      for (final c in cookies) {
        if (c.name.isNotEmpty) values[c.name] = c.value;
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
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo guardar la sesión: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cuenta de Aedex'),
        actions: [
          IconButton(
            tooltip: 'Cabeceras del POST',
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: _showHeaders,
          ),
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
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 9, color: Colors.white38),
              ),
            ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri('about:blank')),
              initialSettings: InAppWebViewSettings(
                userAgent: _cleanUa.isEmpty ? _fallbackUa : _cleanUa,
                useWideViewPort: _desktopMode,
                loadWithOverviewMode: _desktopMode,
                supportZoom: true,
                builtInZoomControls: true,
                displayZoomControls: false,
                javaScriptEnabled: true,
                domStorageEnabled: true,
                thirdPartyCookiesEnabled: true,
                mediaPlaybackRequiresUserGesture: false,
                requestedWithHeaderOriginAllowList: <String>{},
                useShouldOverrideUrlLoading: false,
                useShouldInterceptRequest: true,
              ),
              onWebViewCreated: (controller) {
                _controller = controller;
                _prepare(controller);
              },
              shouldInterceptRequest: (controller, request) async {
                final u = request.url.toString();
                if (u.contains('/api/auth/callback/credentials')) {
                  final h = (request.headers ?? const <String, String>{})
                      .entries
                      .map((e) => '${e.key}: ${e.value}')
                      .join('\n');
                  final txt = '${request.method} $u\n$h';
                  debugPrint('POSTHDR $txt');
                  if (mounted) setState(() => _postHeaders = txt);
                }
                return null;
              },
              onLoadStop: (controller, url) async {
                final u = url?.toString() ?? '';
                if (u == 'about:blank' && !_captured) {
                  _captured = true;
                  await _applySpoofAndLoad(controller);
                } else if (u.contains('/auth/login')) {
                  await _readDebug();
                }
              },
            ),
          ),
          if (_saving || _preparing)
            const LinearProgressIndicator()
          else
            const SizedBox(height: 4),
        ],
      ),
    );
  }
}
