/// Una serie del catálogo.
class SeriesItem {
  final String slug;
  final String title;
  final String coverPath;
  final String description;

  const SeriesItem({
    required this.slug,
    required this.title,
    required this.coverPath,
    this.description = '',
  });

  Map<String, dynamic> toMap() => {
        'slug': slug,
        'title': title,
        'coverPath': coverPath,
        'description': description,
      };

  factory SeriesItem.fromMap(Map<dynamic, dynamic> m) => SeriesItem(
        slug: (m['slug'] ?? '').toString(),
        title: (m['title'] ?? '').toString(),
        coverPath: (m['coverPath'] ?? '').toString(),
        description: (m['description'] ?? '').toString(),
      );
}
