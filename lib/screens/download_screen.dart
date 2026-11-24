import 'package:flutter/material.dart';

import '../models/chapter_item.dart';
import '../models/series_item.dart';
import '../services/aedex_api.dart';
import '../services/cache_service.dart';
import '../services/download_service.dart';
import '../services/reader_service.dart';
import 'login_screen.dart';

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
  int _done = 0;
  int _total = 0;
  bool _running = true;
  bool _cancelled = false;
  bool _needsLogin = false;
  String _status = 'Preparando el lector...';
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    if (!mounted) return;
    setState(() {
      _running = true;
      _cancelled = false;
      _needsLogin = false;
      _error = null;
      _done = 0;
      _total = 0;
      _status = 'Preparando el lector...';
    });

    try {
      final api = AedexApi();
      final service = DownloadService(ReaderService(api));
      final directory = await CacheService.chapterDir(
        widget.series.slug,
        widget.chapter.slug,
      );

      final paths = await service.download(
        slug: widget.series.slug,
        chapter: widget.chapter.slug,
        directory: directory,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _done = done;
            _total = total;
            _status = 'Descargando $done/$total páginas...';
          });
        },
        isCancelled: () => _cancelled,
      );

      if (paths.isEmpty) {
        throw const ReaderException('No se descargó ninguna página');
      }

      await CacheService.saveChapter(
        widget.series.slug,
        widget.chapter,
        paths,
      );

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on LoginRequiredException {
      if (!mounted) return;
      setState(() {
        _running = false;
        _needsLogin = true;
        _status = 'Necesitas iniciar sesión para leer más de 3 capítulos.';
      });
    } on ReaderSessionExpired {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = 'La sesión del lector caducó. Vuelve a intentarlo.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _login() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
    if (ok == true && mounted) {
      _start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _total == 0 ? null : (_done / _total).clamp(0.0, 1.0).toDouble();

    return Scaffold(
      appBar: AppBar(
        title: Text('Capítulo ${widget.chapter.number}'),
        actions: [
          if (_running)
            TextButton(
              onPressed: () => setState(() => _cancelled = true),
              child: const Text('Cancelar'),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              _error != null
                  ? Icons.error_outline
                  : _needsLogin
                      ? Icons.lock_outline
                      : Icons.downloading,
              size: 64,
              color: _error != null ? Colors.redAccent : const Color(0xFFFF3563),
            ),
            const SizedBox(height: 20),
            Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ],
            const SizedBox(height: 24),
            if (_running)
              LinearProgressIndicator(value: progress)
            else if (_needsLogin)
              FilledButton.icon(
                onPressed: _login,
                icon: const Icon(Icons.login),
                label: const Text('Iniciar sesión'),
              )
            else
              FilledButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
              ),
            if (_running) ...[
              const SizedBox(height: 12),
              Text(
                'Descarga directa, sin WebView ni anuncios',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withOpacity(0.4),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
