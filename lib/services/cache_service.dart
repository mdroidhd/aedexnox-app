import 'dart:io';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../models/chapter_item.dart';
import '../models/series_item.dart';

/// Todo lo que la app guarda en disco: catálogo, capítulos y rutas de páginas.
///
/// La idea es no volver a pedir a la web lo que ya tenemos. El catálogo y la
/// lista de capítulos viven en Hive; las imágenes viven como archivos WebP en
/// el directorio privado de la app.
class CacheService {
  /// Cambia cuando cambia el formato/mosaico de las páginas. Las descargas de
  /// una versión anterior se consideran inválidas y se vuelven a bajar.
  static const int pageVersion = 2;

  static late Box _series;
  static late Box _chapters;
  static late Box _pages;
  static late Box _meta;

  static Future<void> init() async {
    await Hive.initFlutter();
    _series = await Hive.openBox('series');
    _chapters = await Hive.openBox('chapters');
    _pages = await Hive.openBox('pages');
    _meta = await Hive.openBox('meta');
  }

  // ---------------- catálogo ----------------

  static List<SeriesItem> getSeries() {
    final out = <SeriesItem>[];
    for (final v in _series.values) {
      if (v is Map) out.add(SeriesItem.fromMap(v));
    }
    out.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return out;
  }

  static Future<void> saveSeries(List<SeriesItem> items) async {
    await _series.clear();
    for (final s in items) {
      await _series.put(s.slug, s.toMap());
    }
    await _meta.put('catalogAt', DateTime.now().toIso8601String());
  }

  static DateTime? get catalogAt {
    final v = _meta.get('catalogAt');
    return v == null ? null : DateTime.tryParse(v.toString());
  }

  // ---------------- capítulos ----------------

  static String _key(String slug, String ch) => '$slug|$ch';

  static List<ChapterItem> getChapters(String slug) {
    final out = <ChapterItem>[];
    for (final k in _chapters.keys) {
      if (k.toString().startsWith('$slug|')) {
        final v = _chapters.get(k);
        if (v is Map) {
          final item = ChapterItem.fromMap(v);
          final version = (v['version'] as num?)?.toInt();
          out.add(
            item.downloaded && version != pageVersion
                ? ChapterItem(slug: item.slug, number: item.number)
                : item,
          );
        }
      }
    }
    out.sort((a, b) => a.number.compareTo(b.number));
    return out;
  }

  static Future<void> saveChapters(String slug, List<ChapterItem> items) async {
    for (final c in items) {
      // No pisar el estado de descarga si ya existe.
      final existing = _chapters.get(_key(slug, c.slug));
      if (existing is Map && existing['downloaded'] == true) continue;
      await _chapters.put(_key(slug, c.slug), c.toMap());
    }
  }

  static bool isDownloaded(String slug, String ch) {
    final v = _chapters.get(_key(slug, ch));
    return v is Map &&
        v['downloaded'] == true &&
        (v['version'] as num?)?.toInt() == pageVersion;
  }

  // ---------------- páginas ----------------

  static List<String> getPagePaths(String slug, String ch) {
    final chapter = _chapters.get(_key(slug, ch));
    if (chapter is Map &&
        (chapter['version'] as num?)?.toInt() != pageVersion) {
      return const [];
    }
    final v = _pages.get(_key(slug, ch));
    if (v is List) return v.map((e) => e.toString()).toList();
    return const [];
  }

  static Future<Directory> chapterDir(String slug, String ch) async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/aedex/$slug/$ch');
    await dir.create(recursive: true);
    return dir;
  }

  static Future<void> saveChapter(
    String slug,
    ChapterItem ch,
    List<String> pagePaths,
  ) async {
    await _pages.put(_key(slug, ch.slug), pagePaths);
    final updated = ChapterItem(
      slug: ch.slug,
      number: ch.number,
      downloaded: true,
      pages: pagePaths.length,
    );
    final map = updated.toMap()..['version'] = pageVersion;
    await _chapters.put(_key(slug, ch.slug), map);
  }

  // ---------------- mantenimiento ----------------

  static Future<void> clearAll() async {
    await _series.clear();
    await _chapters.clear();
    await _pages.clear();
    await _meta.clear();
  }
}
