import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class VideoExampleThumbnail extends StatefulWidget {
  const VideoExampleThumbnail({
    super.key,
    required this.sourceKey,
    required this.load,
  });

  final Object sourceKey;
  final Future<ui.Image> Function() load;

  @override
  State<VideoExampleThumbnail> createState() => _VideoExampleThumbnailState();
}

class _VideoExampleThumbnailState extends State<VideoExampleThumbnail> {
  ui.Image? _image;
  bool _failed = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _startLoad();
  }

  @override
  void didUpdateWidget(covariant VideoExampleThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceKey != widget.sourceKey) {
      _image?.dispose();
      _image = null;
      _failed = false;
      _startLoad();
    }
  }

  Future<void> _startLoad() async {
    final generation = ++_generation;
    try {
      final image = await widget.load();
      if (!mounted || generation != _generation) {
        image.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = image;
        _failed = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _generation++;
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image != null) {
      return RawImage(
        image: image,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
      );
    }
    if (_failed) {
      return const Center(
        child: Icon(
          Icons.broken_image_outlined,
          size: 20,
          color: Colors.white54,
        ),
      );
    }
    return const Center(
      child: SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}
