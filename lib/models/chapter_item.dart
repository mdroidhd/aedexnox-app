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

  factory ChapterItem.fromApi(Map<String, dynamic> m) {
    final value = m['numero'];
    final number = value is num ? value.toDouble() : double.tryParse('$value') ?? 0;
    final slug = number.toString().replaceFirst(RegExp(r'\.0$'), '');
    return ChapterItem(slug: slug, number: number);
  }

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
