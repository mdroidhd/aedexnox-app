import 'package:http/http.dart' as http;

import '../models/chapter_item.dart';
import '../models/series_item.dart';

/// Cliente HTTP para el catálogo y la lista de capítulos.
///
/// No intenta replicar el lector (canvas + WASM + Turnstile). Eso lo hace el
/// WebView en [DownloadScreen]. Aquí solo se leen las páginas públicas de
/// listado, con una pausa entre peticiones para no disparar el anti-bot.
class AedexClient {
  static const String base = 'https://aedexnox.com';

  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  static DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<void> _throttle() async {
    final elapsed = DateTime.now().difference(_last).inMilliseconds;
    final wait = 900 - elapsed;
    if (wait > 0) await Future.delayed(Duration(milliseconds: wait));
    _last = DateTime.now();
  }

  static Future<String> _get(String path) async {
    await _throttle();
    final res = await http
        .get(
          Uri.parse('$base$path'),
          headers: {
            'User-Agent': _ua,
            'Accept-Language': 'es-ES,es;q=0.9',
            'Accept': 'text/html,application/xhtml+xml',
          },
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}');
    }
    return res.body;
  }

  static String coverUrl(String path) =>
      path.startsWith('http') ? path : '$base$path';

  /// Lee el listado de /comics desde el payload de Next.js.
  static Future<List<SeriesItem>> fetchCatalog() async {
    final html = await _get('/comics');
    final re = RegExp(
      r'\\"title\\":\\"([^"\\]*)\\",\\"series_slug\\":\\"([^"\\]*)\\",\\"thumbnail\\":\\"([^"\\]*)\\"',
    );
    final seen = <String>{};
    final out = <SeriesItem>[];
    for (final m in re.allMatches(html)) {
      final slug = m.group(2)!;
      if (!seen.add(slug)) continue;
      out.add(
        SeriesItem(
          slug: slug,
          title: m.group(1)!,
          coverPath: m.group(3)!,
        ),
      );
    }
    return out;
  }

  /// Lee los capítulos de la ficha de la serie.
  static Future<List<ChapterItem>> fetchChapters(String slug) async {
    final html = await _get('/comic/$slug');
    final map = <String, ChapterItem>{};

    // Las claves pueden venir en dos órdenes distintos dentro del JSON de Next.
    final a = RegExp(
      r'\\"chapter_number\\":([0-9.]+)[^{}]*?\\"chapter_slug\\":\\"([^"\\]+)\\"',
    );
    for (final m in a.allMatches(html)) {
      map[m.group(2)!] = ChapterItem(
        slug: m.group(2)!,
        number: double.tryParse(m.group(1)!) ?? 0,
      );
    }

    final b = RegExp(
      r'\\"chapter_slug\\":\\"([^"\\]+)\\"[^{}]*?\\"chapter_number\\":([0-9.]+)',
    );
    for (final m in b.allMatches(html)) {
      map[m.group(1)!] = ChapterItem(
        slug: m.group(1)!,
        number: double.tryParse(m.group(2)!) ?? 0,
      );
    }

    final list = map.values.toList()
      ..sort((x, y) => x.number.compareTo(y.number));
    return list;
  }
}
