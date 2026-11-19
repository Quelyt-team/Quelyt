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
    final visual = documentFormatVisual(
      context,
      widget.document.format,
      originalName: widget.document.originalName,
      filePath: widget.document.filePath,
    );
    final showBadge = widget.height >= 72 && widget.width >= 60;
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: visual.background,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: visual.border),
      ),
      child: showBadge
          ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                QIcon(
                  visual.icon,
                  size: widget.iconSize,
                  color: visual.ink,
                  active: visual.icon == QIcons.fileVideo,
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: visual.ink.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    visual.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.labelSmall!.copyWith(
                      fontSize: 10.5,
                      height: 1.15,
                      letterSpacing: 0.4,
                      color: visual.ink,
                      fontWeight: FontWeight.w700,
                      fontFeatures: AppNumerals.tabular,
                    ),
                  ),
                ),
              ],
            )
          : Center(
              child: QIcon(
                visual.icon,
                size: widget.iconSize,
                color: visual.ink,
                active: visual.icon == QIcons.fileVideo,
              ),
            ),
    );
  }
}
