import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/chapter_item.dart';
import '../models/series_item.dart';
import '../services/aedex_api.dart';
import '../services/cache_service.dart';
import '../services/reader_service.dart';
import 'download_screen.dart';
import 'login_screen.dart';

/// Lector vertical. Si el capítulo no está descargado, abre una sesión del
/// lector y va pidiendo las páginas conforme se ven (lazy load), guardándolas
/// en disco. Así no se descargan 20 páginas de golpe.
class ReaderScreen extends StatefulWidget {
  final SeriesItem series;
  final ChapterItem chapter;

  const ReaderScreen({
    super.key,
    required this.series,
    required this.chapter,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final Map<int, String> _files = {};
  final List<int> _queue = [];
  final Set<int> _queued = {};
  final Set<int> _loading = {};
  final Set<int> _failed = {};

  ReaderSession? _session;
  int _count = 0;
  bool _opening = true;
  bool _pumping = false;
  bool _disposed = false;
  bool _needsLogin = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final local = CacheService.getPagePaths(
      widget.series.slug,
      widget.chapter.slug,
    );
    if (local.isNotEmpty) {
      for (var i = 0; i < local.length; i++) {
        if (File(local[i]).existsSync()) _files[i] = local[i];
      }
      if (_files.isNotEmpty && widget.chapter.downloaded) {
        _count = local.length;
        _opening = false;
        if (mounted) setState(() {});
        return;
      }
    }
    await _openStreaming();
  }

  Future<void> _openStreaming() async {
    if (!mounted) return;
    setState(() {
      _opening = true;
      _error = null;
      _needsLogin = false;
    });

    _failed.clear();
    try {
      final session =
          await ReaderService(AedexApi()).openChapter(widget.series.slug, widget.chapter.slug);
      final directory = await CacheService.chapterDir(
        widget.series.slug,
        widget.chapter.slug,
      );

      _session = session;
      _count = session.handles.length;
      for (var i = 0; i < _count; i++) {
        final file = File(_pagePath(directory, i));
        if (await file.exists() && await file.length() > 0) {
          _files[i] = file.path;
        }
      }

      if (!mounted) return;
      setState(() => _opening = false);
      await _maybeComplete();
    } on LoginRequiredException {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _needsLogin = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _error = error.toString();
      });
    }
  }

  String _pagePath(Directory directory, int index) =>
      '${directory.path}/${(index + 1).toString().padLeft(3, '0')}.jpg';

  void _need(int index) {
    if (_session == null ||
        _files.containsKey(index) ||
        _queued.contains(index) ||
        _loading.contains(index) ||
        _failed.contains(index)) {
      return;
    }
    _queued.add(index);
    _queue.add(index);
    _pump();
  }

  Future<void> _pump() async {
    if (_pumping || _session == null) return;
    _pumping = true;

    while (_queue.isNotEmpty && !_disposed) {
      final index = _queue.removeAt(0);
      _queued.remove(index);
      _loading.add(index);

      try {
        final bytes = await _session!.fetchPage(_session!, index);
        final directory = await CacheService.chapterDir(
          widget.series.slug,
          widget.chapter.slug,
        );
        final file = File(_pagePath(directory, index));
        await file.writeAsBytes(bytes, flush: true);
        if (!_disposed) {
          setState(() => _files[index] = file.path);
        }
        await _maybeComplete();
        await Future<void>.delayed(const Duration(milliseconds: 120));
      } catch (error) {
        _failed.add(index);
        if (!_disposed) {
          setState(() => _error = error.toString());
        }
      } finally {
        _loading.remove(index);
      }
    }

    _pumping = false;
  }

  Future<void> _maybeComplete() async {
    if (_count == 0 || _files.length < _count) return;
    final paths = List<String?>.generate(_count, (i) => _files[i]);
    if (paths.any((p) => p == null)) return;
    await CacheService.saveChapter(
      widget.series.slug,
      widget.chapter,
      paths.cast<String>(),
    );
  }

  Future<void> _downloadAll() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => DownloadScreen(
          series: widget.series,
          chapter: widget.chapter,
        ),
      ),
    );
    if (ok == true && mounted) {
      final local = CacheService.getPagePaths(
        widget.series.slug,
        widget.chapter.slug,
      );
      if (local.isNotEmpty) {
        setState(() {
          _files
            ..clear();
          for (var i = 0; i < local.length; i++) {
            _files[i] = local[i];
          }
          _count = local.length;
        });
      }
    }
  }

  Future<void> _login() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
    if (ok == true) await _openStreaming();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          '${widget.series.title} · Cap. ${widget.chapter.number}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_count > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  '${_files.length}/$_count',
                  style: const TextStyle(fontSize: 12, color: Colors.white54),
                ),
              ),
            ),
          if (_count > 0)
            IconButton(
              tooltip: 'Descargar todo',
              icon: const Icon(Icons.download_outlined),
              onPressed: _downloadAll,
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_opening) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_needsLogin) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock_outline, size: 56),
              const SizedBox(height: 12),
              const Text(
                'Inicia sesión para leer más de 3 capítulos.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _login,
                icon: const Icon(Icons.login),
                label: const Text('Iniciar sesión'),
              ),
            ],
          ),
        ),
      );
    }

    if (_error != null && _count == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _openStreaming,
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: _count,
      itemBuilder: (context, index) => _LazyPage(
        index: index,
        path: _files[index],
        onNeed: _need,
      ),
    );
  }
}

class _LazyPage extends StatefulWidget {
  final int index;
  final String? path;
  final void Function(int index) onNeed;

  const _LazyPage({
    required this.index,
    required this.path,
    required this.onNeed,
  });

  @override
  State<_LazyPage> createState() => _LazyPageState();
}

class _LazyPageState extends State<_LazyPage> {
  @override
  void initState() {
    super.initState();
    widget.onNeed(widget.index);
  }

  @override
  void didUpdateWidget(covariant _LazyPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.path == null) widget.onNeed(widget.index);
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.path;
    if (path == null) {
      return Container(
        height: 420,
        color: Colors.black,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: 10),
            Text(
              'Página ${widget.index + 1}',
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Image.file(
        File(path),
        fit: BoxFit.fitWidth,
        width: double.infinity,
        errorBuilder: (_, __, ___) => const SizedBox(
          height: 200,
          child: Center(child: Icon(Icons.broken_image_outlined)),
        ),
      ),
    );
  }
}
