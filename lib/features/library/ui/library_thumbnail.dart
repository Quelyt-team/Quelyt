import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/models.dart';
import '../../../ui/theme/tokens.dart';
import '../services/library_thumbnail_service.dart';
import 'library_style.dart';

/// First-page cover with a format-glyph fallback. Rendering is lazy and only
/// requested for the currently visible detail panel.
class DocumentCoverImage extends StatefulWidget {
  const DocumentCoverImage({
    super.key,
    required this.document,
    required this.thumbnails,
    this.width = 88,
    this.height = 108,
    this.iconSize = 30,
  });

  final DocumentRecord document;
  final LibraryThumbnailService thumbnails;
  final double width;
  final double height;
  final double iconSize;

  @override
  State<DocumentCoverImage> createState() => _DocumentCoverImageState();
}

class _DocumentCoverImageState extends State<DocumentCoverImage> {
  Future<File?>? _future;

  @override
  void initState() {
    super.initState();
    _future = widget.thumbnails.coverFor(widget.document);
  }

  @override
  void didUpdateWidget(DocumentCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document.id != widget.document.id ||
        oldWidget.document.filePath != widget.document.filePath) {
      _future = widget.thumbnails.coverFor(widget.document);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _future,
      builder: (context, snapshot) {
        final cover = snapshot.data;
        if (cover != null && cover.existsSync()) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(Radii.sm),
            child: Image.file(
              cover,
              width: widget.width,
              height: widget.height,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              errorBuilder: (context, error, stack) => _fallback(context),
            ),
          );
        }
        return _fallback(context);
      },
    );
  }

  Widget _fallback(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: colors.surfaceRaised,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: colors.outline),
      ),
      child: Center(
        child: QIcon(
          documentIcon(widget.document.format),
          size: widget.iconSize,
          color: colors.inkMuted,
        ),
      ),
    );
  }
}
