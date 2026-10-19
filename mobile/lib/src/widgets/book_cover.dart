/// A book's cover art (or a tidy placeholder when there is none).
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    required this.url,
    this.title,
    this.width = 56,
    this.height = 84,
    this.radius = 8,
  });

  final String? url;
  final String? title;
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final radiusValue = BorderRadius.circular(radius);
    // The placeholder follows the theme like every other surface.
    final background = Theme.of(context).colorScheme.surfaceContainerHigh;
    final cover = (url == null || url!.isEmpty)
        ? _placeholder(background)
        : CachedNetworkImage(
            imageUrl: url!,
            width: width,
            height: height,
            fit: BoxFit.cover,
            placeholder: (context, url) => _placeholder(background, loading: true),
            errorWidget: (context, url, error) => _placeholder(background),
          );
    return ClipRRect(
      borderRadius: radiusValue,
      child: SizedBox(width: width, height: height, child: cover),
    );
  }

  Widget _placeholder(Color background, {bool loading = false}) {
    final initial = (title == null || title!.trim().isEmpty)
        ? '?'
        : title!.trim().characters.first.toUpperCase();
    return Container(
      width: width,
      height: height,
      color: background,
      alignment: Alignment.center,
      child: loading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(
              initial,
              style: TextStyle(
                color: kSlate500,
                fontSize: (height / 3).clamp(14, 32),
                fontWeight: FontWeight.w600,
              ),
            ),
    );
  }
}
