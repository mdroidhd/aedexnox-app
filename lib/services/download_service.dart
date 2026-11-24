import 'dart:io';
import 'dart:typed_data';

import 'reader_service.dart';

class DownloadService {
  final ReaderService reader;

  DownloadService(this.reader);

  Future<List<String>> download({
    required String slug,
    required String chapter,
    required Directory directory,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final session = await reader.openChapter(slug, chapter);
    final total = session.handles.length;
    final paths = <String>[];

    for (var i = 0; i < total; i++) {
      if (isCancelled?.call() == true) break;

      Uint8List? bytes;
      Object? lastError;
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          bytes = await reader.fetchPage(session, i);
          break;
        } catch (error) {
          lastError = error;
          if (attempt == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 700));
          }
        }
      }
      if (bytes == null) {
        throw lastError ?? ReaderException('No se pudo bajar la página ${i + 1}');
      }

      final file = File(
        '${directory.path}/${(i + 1).toString().padLeft(3, '0')}.jpg',
      );
      await file.writeAsBytes(bytes, flush: true);
      paths.add(file.path);
      onProgress?.call(i + 1, total);

      // Pequeña pausa para no disparar el limitador del lector.
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }

    return paths;
  }
}
