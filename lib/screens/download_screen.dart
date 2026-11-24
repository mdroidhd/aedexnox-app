import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/chapter_item.dart';
import '../models/series_item.dart';
import '../services/cache_service.dart';

/// Se inyecta antes de que cargue la página.
///
/// 1. Neutraliza los detectores de devtools basados en consola (si no, el
///    lector muestra "Contenido Protegido" y deja los canvas en blanco).
/// 2. Expone funciones para consultar el estado y exportar cada canvas.
const String _initScript = r'''
(() => {
  const o = console;
  const keep = a => (a === null || (typeof a !== 'object' && typeof a !== 'function'));
  const log = o.log.bind(o);
  o.log = (...a) => log(...a.map(x => keep(x) ? x : '[blob]'));
  o.table = () => {};
  o.clear = () => {};
  o.dir = () => {};

  window.__aedexInfo = function() {
    const cs = [...document.querySelectorAll('canvas.manga-page-canvas')];
    return JSON.stringify({
      count: cs.length,
      ready: cs.map((c, i) => (c.width > 500 && !String(c.className).includes('hidden')) ? i : -1).filter(i => i >= 0),
      text: (document.body.innerText || '').slice(0, 300),
      url: location.href
    });
  };

  window.__aedexScroll = function(dy) { window.scrollBy(0, dy || 1200); };

  window.__aedexGrabSend = function(i) {
    const cs = document.querySelectorAll('canvas.manga-page-canvas');
    const c = cs[i];
    if (!c || c.width < 500) {
      window.flutter_inappwebview.callHandler('aedexPageError', i, 'not-ready');
      return;
    }
    const t = document.createElement('canvas');
    t.width = c.width;
    t.height = c.height;
    t.getContext('2d').drawImage(c, 0, 0);
    const d = t.toDataURL('image/webp', 0.95);
    const b64 = d.split(',')[1] || '';
    const CH = 200000;
    const n = Math.ceil(b64.length / CH) || 1;
    window.flutter_inappwebview.callHandler('aedexPageStart', i, n);
    for (let k = 0; k < n; k++) {
      window.flutter_inappwebview.callHandler('aedexPageChunk', i, k, b64.slice(k * CH, (k + 1) * CH));
    }
    window.flutter_inappwebview.callHandler('aedexPageEnd', i);
  };
})();
''';

class DownloadScreen extends StatefulWidget {
  final SeriesItem series;
  final ChapterItem chapter;

  const DownloadScreen({
    super.key,
    required this.series,
    required this.chapter,
  });

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  InAppWebViewController? _controller;
  Timer? _poll;

  final Set<int> _saved = {};
  final Set<int> _requested = {};
  final Map<int, List<String>> _chunks = {};

  int _total = 0;
  bool _finished = false;
  bool _captchaHint = false;
  String _status = 'Cargando lector...';
  String? _error;
  late DateTime _started;

  @override
  void initState() {
    super.initState();
    _started = DateTime.now();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startPolling());
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 900), (_) => _tick());
  }

  Future<void> _tick() async {
    if (_finished || _controller == null) return;

    if (DateTime.now().difference(_started).inSeconds > 150) {
      _finish(
        success: _saved.isNotEmpty,
        message: _saved.isEmpty ? 'Tiempo de espera agotado' : null,
      );
      return;
    }

    dynamic raw;
    try {
      raw = await _controller!.evaluateJavascript(
        source: 'window.__aedexInfo ? window.__aedexInfo() : ""',
      );
    } catch (_) {
      return;
    }

    final info = _parseInfo(raw);
    if (info == null) return;

    final count = (info['count'] as num?)?.toInt() ?? 0;
    final ready = ((info['ready'] as List?) ?? const [])
        .map((e) => (e as num).toInt())
        .toList();
    final text = (info['text'] ?? '').toString();

    if (text.contains('Verificación anti-bot') && !_captchaHint) {
      setState(() {
        _captchaHint = true;
        _status = 'Toca la casilla de Cloudflare en la página';
      });
    }

    if (count == 0) {
      // Intentar pulsar el widget de Turnstile (si el navegador lo permite).
      try {
        await _controller!.evaluateJavascript(source: '''
          (function(){
            const inp = document.querySelector('input[name=cf-turnstile-response]');
            if (!inp) return;
            let n = inp;
            for (let i = 0; i < 8 && n; i++) {
              const r = n.getBoundingClientRect();
              if (r.width >= 250 && r.width <= 340 && r.height >= 55 && r.height <= 90) {
                const el = document.elementFromPoint(r.x + 28, r.y + r.height / 2);
                if (el) {
                  el.dispatchEvent(new MouseEvent('click', {
                    bubbles: true, clientX: r.x + 28, clientY: r.y + r.height / 2
                  }));
                }
                break;
              }
              n = n.parentElement;
            }
          })();
        ''');
      } catch (_) {}
      return;
    }

    if (count != _total) {
      setState(() => _total = count);
    }

    // Cargar las páginas perezosas.
    try {
      await _controller!.evaluateJavascript(
        source: 'window.__aedexScroll && window.__aedexScroll(1200)',
      );
    } catch (_) {}

    for (final i in ready) {
      if (_saved.contains(i) || _requested.contains(i)) continue;
      _requested.add(i);
      setState(() {
        _status = 'Extrayendo páginas (${_saved.length}/$_total)...';
      });
      try {
        await _controller!.evaluateJavascript(
          source: 'window.__aedexGrabSend($i)',
        );
      } catch (_) {
        _requested.remove(i);
      }
    }

    if (_total > 0 && _saved.length >= _total && !_finished) {
      await _finish(success: true);
    }
  }

  Map<String, dynamic>? _parseInfo(dynamic raw) {
    if (raw == null) return null;
    var s = raw.toString();
    try {
      dynamic v = jsonDecode(s);
      if (v is String) v = jsonDecode(v);
      if (v is Map) return Map<String, dynamic>.from(v);
    } catch (_) {}
    return null;
  }

  Future<void> _finish({required bool success, String? message}) async {
    if (_finished) return;
    _finished = true;
    _poll?.cancel();

    if (!success) {
      if (mounted) {
        setState(() => _error = message ?? 'No se pudo preparar el capítulo');
      }
      return;
    }

    try {
      final dir = await CacheService.chapterDir(
        widget.series.slug,
        widget.chapter.slug,
      );
      final indices = _saved.toList()..sort();
      final paths = indices
          .map((i) => '${dir.path}/${(i + 1).toString().padLeft(3, '0')}.webp')
          .toList();
      await CacheService.saveChapter(
        widget.series.slug,
        widget.chapter,
        paths,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final url =
        'https://aedexnox.com/comic/${widget.series.slug}/${widget.chapter.slug}?modo=gratis';

    return Scaffold(
      appBar: AppBar(
        title: Text('Capítulo ${widget.chapter.number}'),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: const Color(0xFF151520),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text(
              _error ?? _status,
              style: TextStyle(
                fontSize: 13,
                color: _error != null ? Colors.redAccent : Colors.white70,
              ),
            ),
          ),
          if (_captchaHint)
            Container(
              width: double.infinity,
              color: const Color(0xFFFF3563).withOpacity(0.15),
              padding: const EdgeInsets.all(10),
              child: const Text(
                'Si aparece "Verificación anti-bot", toca la casilla de Cloudflare '
                'en la página. La descarga sigue sola después.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(url)),
              initialSettings: InAppWebViewSettings(
                userAgent:
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
                useWideViewPort: true,
                loadsImagesAutomatically: true,
                javaScriptEnabled: true,
                domStorageEnabled: true,
                thirdPartyCookiesEnabled: true,
                mediaPlaybackRequiresUserGesture: false,
              ),
              initialUserScripts: UnmodifiableListView<UserScript>([
                UserScript(
                  source: _initScript,
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                ),
              ]),
              onWebViewCreated: (controller) {
                _controller = controller;

                controller.addJavaScriptHandler(
                  handlerName: 'aedexPageStart',
                  callback: (args) {
                    final i = (args[0] as num).toInt();
                    final n = (args[1] as num).toInt();
                    _chunks[i] = List<String>.filled(n, '');
                    return null;
                  },
                );

                controller.addJavaScriptHandler(
                  handlerName: 'aedexPageChunk',
                  callback: (args) {
                    final i = (args[0] as num).toInt();
                    final k = (args[1] as num).toInt();
                    final data = args[2].toString();
                    final list = _chunks[i];
                    if (list != null && k >= 0 && k < list.length) {
                      list[k] = data;
                    }
                    return null;
                  },
                );

                controller.addJavaScriptHandler(
                  handlerName: 'aedexPageEnd',
                  callback: (args) async {
                    final i = (args[0] as num).toInt();
                    final list = _chunks.remove(i);
                    if (list == null) return null;

                    try {
                      final dir = await CacheService.chapterDir(
                        widget.series.slug,
                        widget.chapter.slug,
                      );
                      final file = File(
                        '${dir.path}/${(i + 1).toString().padLeft(3, '0')}.webp',
                      );
                      await file.writeAsBytes(
                        base64Decode(list.join()),
                        flush: true,
                      );
                      _saved.add(i);
                      if (mounted) setState(() {});
                      if (_total > 0 &&
                          _saved.length >= _total &&
                          !_finished) {
                        await _finish(success: true);
                      }
                    } catch (e) {
                      if (mounted) {
                        setState(() {
                          _error = 'Error guardando página ${i + 1}: $e';
                        });
                      }
                    }
                    return null;
                  },
                );

                controller.addJavaScriptHandler(
                  handlerName: 'aedexPageError',
                  callback: (args) {
                    final i = (args[0] as num).toInt();
                    _requested.remove(i);
                    return null;
                  },
                );
              },
              onLoadStop: (controller, url) async {
                // La página de anuncios puede recargar el lector: permitimos
                // reintentar las páginas que no llegaron a guardarse.
                _requested.clear();
              },
            ),
          ),
          LinearProgressIndicator(
            value: _total == 0
                ? null
                : (_saved.length / _total).clamp(0.0, 1.0).toDouble(),
          ),
        ],
      ),
    );
  }
}
