/// Un capítulo de una serie.
class ChapterItem {
  final String slug;
  final double number;
  final bool downloaded;
  final int pages;

  const ChapterItem({
    required this.slug,
    required this.number,
    this.downloaded = false,
    this.pages = 0,
  });

  Map<String, dynamic> toMap() => {
        'slug': slug,
        'number': number,
        'downloaded': downloaded,
        'pages': pages,
      };

  factory ChapterItem.fromMap(Map<dynamic, dynamic> m) => ChapterItem(
        slug: (m['slug'] ?? '').toString(),
        number: (m['number'] is num)
            ? (m['number'] as num).toDouble()
            : double.tryParse('${m['number']}') ?? 0,
        downloaded: m['downloaded'] == true,
        pages: (m['pages'] is num)
            ? (m['pages'] as num).toInt()
            : int.tryParse('${m['pages']}') ?? 0,
      );
}
