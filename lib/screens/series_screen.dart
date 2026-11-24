import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/chapter_item.dart';
import '../models/series_item.dart';
import '../services/aedex_api.dart';
import '../services/cache_service.dart';
import '../services/session_service.dart';
import 'download_screen.dart';
import 'login_screen.dart';
import 'reader_screen.dart';

class SeriesScreen extends StatefulWidget {
  final SeriesItem item;

  const SeriesScreen({super.key, required this.item});

  @override
  State<SeriesScreen> createState() => _SeriesScreenState();
}

class _SeriesScreenState extends State<SeriesScreen> {
  List<ChapterItem> _chapters = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    final cached = CacheService.getChapters(widget.item.slug);
    if (cached.isNotEmpty && !force) {
      setState(() {
        _chapters = cached;
        _loading = false;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final fresh = await AedexApi().chapters(widget.item.slug);
      await CacheService.saveChapters(widget.item.slug, fresh);
      final merged = CacheService.getChapters(widget.item.slug);
      if (!mounted) return;
      setState(() {
        _chapters = merged;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'No se pudieron cargar los capítulos.\n$e';
        _loading = false;
        _chapters = cached.isEmpty ? _chapters : cached;
      });
    }
  }

  Future<void> _login() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
    if (ok == true && mounted) setState(() {});
  }

  Future<void> _open(ChapterItem chapter) async {
    if (chapter.number > 3 && !SessionService.isLoggedIn) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Inicia sesión'),
          content: const Text(
            'Como invitado solo se pueden leer los 3 primeros capítulos. '
            'Inicia sesión con una cuenta gratuita para seguir.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Ahora no'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Iniciar sesión'),
            ),
          ],
        ),
      );
      if (go == true) await _login();
      return;
    }

    // Si no está descargado, el lector pide las páginas conforme se ven.
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReaderScreen(
          series: widget.item,
          chapter: chapter,
        ),
      ),
    );
  }

  Future<void> _download(ChapterItem chapter) async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => DownloadScreen(
          series: widget.item,
          chapter: chapter,
        ),
      ),
    );
    if (ok == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(force: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 110,
                    child: AspectRatio(
                      aspectRatio: 638 / 856,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: CachedNetworkImage(
                          imageUrl: AedexApi.coverUrl(widget.item.coverPath),
                          fit: BoxFit.cover,
                          placeholder: (_, __) =>
                              Container(color: const Color(0xFF171722)),
                          errorWidget: (_, __, ___) => Container(
                            color: const Color(0xFF171722),
                            child: const Icon(Icons.broken_image_outlined),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.item.title,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${_chapters.length} capítulos',
                          style: const TextStyle(color: Colors.white70),
                        ),
                        if (!SessionService.isLoggedIn) ...[
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _login,
                            icon: const Icon(Icons.login, size: 16),
                            label: const Text('Iniciar sesión'),
                          ),
                        ],
                        if (widget.item.description.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            widget.item.description,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white54,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (_loading && _chapters.isEmpty)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
            ..._chapters.map((chapter) {
              final locked =
                  chapter.number > 3 && !SessionService.isLoggedIn;
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: chapter.downloaded
                      ? const Color(0xFFFF3563)
                      : const Color(0xFF1E1E2A),
                  child: Icon(
                    locked
                        ? Icons.lock_outline
                        : chapter.downloaded
                            ? Icons.download_done
                            : Icons.menu_book,
                    size: 18,
                  ),
                ),
                title: Text('Capítulo ${chapter.number}'),
                subtitle: chapter.downloaded
                    ? Text(
                        '${chapter.pages} páginas · offline',
                        style: const TextStyle(color: Colors.greenAccent),
                      )
                    : Text(locked ? 'Inicia sesión para leerlo' : 'Sin descargar'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!locked)
                      IconButton(
                        tooltip: 'Descargar todo',
                        icon: const Icon(Icons.download_outlined),
                        onPressed: () => _download(chapter),
                      ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: () => _open(chapter),
              );
            }),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
