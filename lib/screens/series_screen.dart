import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/chapter_item.dart';
import '../models/series_item.dart';
import '../services/aedex_client.dart';
import '../services/cache_service.dart';
import 'download_screen.dart';
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
      final fresh = await AedexClient.fetchChapters(widget.item.slug);
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

  Future<void> _open(ChapterItem ch) async {
    if (ch.downloaded) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ReaderScreen(series: widget.item, chapter: ch),
        ),
      );
      return;
    }

    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => DownloadScreen(series: widget.item, chapter: ch),
      ),
    );

    if (ok != true) return;
    await _load();
    if (!mounted) return;

    final updated = _chapters.firstWhere(
      (c) => c.slug == ch.slug,
      orElse: () => ch,
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReaderScreen(series: widget.item, chapter: updated),
      ),
    );
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
                          imageUrl: AedexClient.coverUrl(widget.item.coverPath),
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
            ..._chapters.map(
              (ch) => ListTile(
                leading: CircleAvatar(
                  backgroundColor: ch.downloaded
                      ? const Color(0xFFFF3563)
                      : const Color(0xFF1E1E2A),
                  child: Icon(
                    ch.downloaded ? Icons.download_done : Icons.menu_book,
                    size: 18,
                  ),
                ),
                title: Text('Capítulo ${ch.number}'),
                subtitle: ch.downloaded
                    ? Text(
                        '${ch.pages} páginas · offline',
                        style: const TextStyle(color: Colors.greenAccent),
                      )
                    : const Text('Sin descargar'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(ch),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
