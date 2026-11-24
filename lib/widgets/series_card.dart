import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/series_item.dart';
import '../services/aedex_api.dart';

class SeriesCard extends StatelessWidget {
  final SeriesItem item;
  final VoidCallback onTap;

  const SeriesCard({super.key, required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: CachedNetworkImage(
                imageUrl: AedexApi.coverUrl(item.coverPath),
                fit: BoxFit.cover,
                width: double.infinity,
                placeholder: (_, __) => Container(
                  color: const Color(0xFF171722),
                  child: const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
                errorWidget: (_, __, ___) => Container(
                  color: const Color(0xFF171722),
                  child: const Icon(Icons.broken_image_outlined),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
