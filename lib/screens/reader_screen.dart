import 'dart:io';

import 'package:flutter/material.dart';

import '../models/chapter_item.dart';
import '../models/series_item.dart';
import '../services/cache_service.dart';

class ReaderScreen extends StatelessWidget {
  final SeriesItem series;
  final ChapterItem chapter;

  const ReaderScreen({
    super.key,
    required this.series,
    required this.chapter,
  });

  @override
  Widget build(BuildContext context) {
    final paths = CacheService.getPagePaths(series.slug, chapter.slug);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          '${series.title} · Cap. ${chapter.number}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: paths.isEmpty
          ? const Center(child: Text('No hay páginas descargadas'))
          : ListView.builder(
              itemCount: paths.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Image.file(
                  File(paths[i]),
                  fit: BoxFit.fitWidth,
                  width: double.infinity,
                  errorBuilder: (_, __, ___) => const SizedBox(
                    height: 200,
                    child: Center(child: Icon(Icons.broken_image_outlined)),
                  ),
                ),
              ),
            ),
    );
  }
}
