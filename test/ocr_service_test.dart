import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/services/ocr_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/local_study/ocr');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final service = OcrService(channel: channel);

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('reports unsupported platforms without pretending OCR ran', () async {
    final status = await service.availability();
    expect(status.available, isFalse);
    expect(status.backend, 'unavailable');
  });

  test(
    'preserves native capability and installed language information',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'availability');
        return {
          'available': false,
          'backend': 'windows_media_ocr',
          'languages': ['en-US'],
          'message': 'Package identity required.',
        };
      });
      final status = await service.availability();
      expect(status.available, isFalse);
      expect(status.languages, ['en-US']);
      expect(status.message, contains('identity'));
    },
  );

  test('passes local path and maps normalized OCR coordinates', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'recognizeImage');
      expect(call.arguments, {
        'path': '/private/page.png',
        'language': 'zh-Hans',
      });
      return {
        'text': '动量 momentum',
        'backend': 'mlkit_chinese_bundled',
        'width': 1200,
        'height': 1600,
        'blocks': [
          {
            'text': '动量 momentum',
            'left': 0.1,
            'top': 0.2,
            'right': 0.8,
            'bottom': 0.25,
            'confidence': 0.92,
          },
        ],
      };
    });
    final result = await service.recognizeImage(
      '/private/page.png',
      language: 'zh-Hans',
    );
    expect(result.text, '动量 momentum');
    expect(result.width, 1200);
    expect(result.blocks.single.left, 0.1);
    expect(result.blocks.single.confidence, 0.92);
  });

  test(
    'rejects invalid coordinates so citations cannot jump outside a page',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => {
          'text': 'bad box',
          'width': 100,
          'height': 100,
          'backend': 'test',
          'blocks': [
            {
              'text': 'bad box',
              'left': 0.9,
              'top': 0,
              'right': 0.1,
              'bottom': 1,
            },
          ],
        },
      );
      await expectLater(
        service.recognizeImage('/page.png'),
        throwsA(
          isA<OcrException>().having((e) => e.code, 'code', 'invalid_result'),
        ),
      );
    },
  );

  test('reports a native failure without inventing recognized text', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
        code: 'language_unavailable',
        message: 'No local model.',
      );
    });
    await expectLater(
      service.recognizeImage('/page.png'),
      throwsA(
        isA<OcrException>().having(
          (e) => e.code,
          'code',
          'language_unavailable',
        ),
      ),
    );
  });

  test(
    'rejects an empty image path before invoking the native engine',
    () async {
      var invoked = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        invoked = true;
        return null;
      });
      await expectLater(
        service.recognizeImage(' '),
        throwsA(isA<OcrException>()),
      );
      expect(invoked, isFalse);
    },
  );
}
