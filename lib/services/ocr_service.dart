import 'dart:async';

import 'package:flutter/services.dart';

/// One OCR line in the unrotated displayed page coordinate space (0..1).
///
/// Native implementations must normalize against the *decoded* image size,
/// including any EXIF orientation, before returning a result. A rendered PDF
/// page is already in this coordinate space.
class OcrBlock {
  const OcrBlock({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    this.confidence,
  });

  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;
  final double? confidence;

  factory OcrBlock.fromMap(Map<Object?, Object?> map) {
    double number(String key) => (map[key] as num).toDouble();
    final left = number('left');
    final top = number('top');
    final right = number('right');
    final bottom = number('bottom');
    if (![left, top, right, bottom].every((n) => n.isFinite) ||
        left < 0 ||
        top < 0 ||
        right > 1 ||
        bottom > 1 ||
        right < left ||
        bottom < top) {
      throw const FormatException('OCR returned invalid page coordinates.');
    }
    return OcrBlock(
      text: map['text'] as String,
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      confidence: (map['confidence'] as num?)?.toDouble(),
    );
  }
}

class OcrAvailability {
  const OcrAvailability({
    required this.available,
    required this.backend,
    this.languages = const [],
    this.message = '',
  });

  final bool available;
  final String backend;
  final List<String> languages;
  final String message;
}

class OcrPage {
  const OcrPage({
    required this.text,
    required this.blocks,
    required this.width,
    required this.height,
    required this.backend,
  });

  final String text;
  final List<OcrBlock> blocks;
  final int width;
  final int height;
  final String backend;
}

class OcrException implements Exception {
  const OcrException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

/// Local OCR only: this service has no HTTP client, URL, or cloud fallback.
class OcrService {
  OcrService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('local_study/ocr');

  final MethodChannel _channel;

  Future<OcrAvailability> availability() async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'availability',
      );
      if (raw == null) throw const FormatException('Missing OCR status.');
      return OcrAvailability(
        available: raw['available'] == true,
        backend: raw['backend'] as String? ?? 'unknown',
        languages: (raw['languages'] as List<Object?>? ?? const [])
            .whereType<String>()
            .toList(growable: false),
        message: raw['message'] as String? ?? '',
      );
    } on MissingPluginException {
      return const OcrAvailability(
        available: false,
        backend: 'unavailable',
        message: '当前平台没有本地 OCR 引擎。可阅读原页并手动校正文字。',
      );
    } on PlatformException catch (error) {
      return OcrAvailability(
        available: false,
        backend: 'unavailable',
        message: error.message ?? '本地 OCR 引擎不可用。',
      );
    }
  }

  Future<OcrPage> recognizeImage(String path, {String? language}) async {
    if (path.trim().isEmpty) {
      throw const OcrException('invalid_path', '请选择本机图片。');
    }
    try {
      final raw = await _channel
          .invokeMapMethod<Object?, Object?>('recognizeImage', {
            'path': path,
            'language': ?language,
          })
          .timeout(const Duration(seconds: 90));
      if (raw == null) throw const FormatException('Missing OCR result.');
      final width = (raw['width'] as num).toInt();
      final height = (raw['height'] as num).toInt();
      if (width <= 0 || height <= 0) {
        throw const FormatException('Invalid OCR image dimensions.');
      }
      return OcrPage(
        text: raw['text'] as String,
        blocks: (raw['blocks'] as List<Object?>)
            .map((block) => OcrBlock.fromMap(block as Map<Object?, Object?>))
            .toList(growable: false),
        width: width,
        height: height,
        backend: raw['backend'] as String,
      );
    } on MissingPluginException {
      throw const OcrException('unavailable', '当前平台没有本地 OCR 引擎。');
    } on TimeoutException {
      throw const OcrException('timeout', '本页识别超时，可暂停队列后重试。');
    } on PlatformException catch (error) {
      throw OcrException(error.code, error.message ?? '本地 OCR 识别失败。');
    } on FormatException {
      throw const OcrException('invalid_result', 'OCR 返回了无效的页面或坐标。');
    } on TypeError {
      throw const OcrException('invalid_result', 'OCR 返回了无效的数据。');
    }
  }
}
