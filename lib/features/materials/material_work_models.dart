import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/models.dart';
import '../../services/ai_gateway.dart';
import 'science/science_markup.dart';

enum MaterialAction {
  recognition('AI 识别', 'vision-1', 2600),
  exercise('试题解答', 'exercise-1', 2200),
  translation('论文翻译', 'translation-1', 1600),
  outline('论文导图', 'paper-map-1', 2400),
  videoQuestion('画面问答', 'video-question-1', 1200);

  const MaterialAction(this.label, this.templateVersion, this.maxOutput);
  final String label;
  final String templateVersion;
  final int maxOutput;
}

String materialDigest(Object? input) =>
    sha256.convert(utf8.encode(jsonEncode(input))).toString();

String formatMaterialTime(int milliseconds) {
  final duration = Duration(milliseconds: milliseconds);
  final hours = duration.inHours.toString().padLeft(2, '0');
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  final millis = duration.inMilliseconds
      .remainder(1000)
      .toString()
      .padLeft(3, '0');
  return '$hours:$minutes:$seconds.$millis';
}

Map<String, dynamic> materialJson(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

class MaterialImage {
  const MaterialImage(this.file, this.digest, this.label);
  final File file;
  final String digest;
  final String label;

  Future<ImageAttachment> load() async {
    final image = ImageAttachment(
      bytes: await file.readAsBytes(),
      mimeType: 'image/png',
      scopeLabel: label,
    );
    if (image.digest != digest) throw StateError('待发送截图发生变化，请重新预览。');
    return image;
  }
}

class MaterialUnit {
  MaterialUnit({
    required this.key,
    required this.label,
    required this.requestText,
    required List<Evidence> sources,
    required this.inputBudget,
    this.image,
    this.protectedText,
    this.translationSlot,
  }) : sources = List.unmodifiable(sources);

  final String key;
  final String label;
  final String requestText;
  final List<Evidence> sources;
  final MaterialImage? image;
  final ProtectedTranslation? protectedText;
  final String? translationSlot;
  final int inputBudget;
}

class MaterialResult {
  const MaterialResult({
    required this.key,
    required this.label,
    required this.text,
    required this.sources,
    this.data = const {},
    this.state = 'ready',
    this.issue,
    this.usage,
    this.reserved = 0,
    this.billedCharacters,
    this.billingUnit = 'token',
  });

  final String key;
  final String label;
  final String text;
  final List<Evidence> sources;
  final Map<String, dynamic> data;
  final String state;
  final String? issue;
  final TokenUsage? usage;
  final int reserved;
  final int? billedCharacters;
  final String billingUnit;

  bool get hasResult => state == 'ready' || state == 'verify';
  bool get needsVerification => state == 'verify';

  factory MaterialResult.fromRow(Map<String, Object?> row) {
    final raw = row['result'] as String?;
    final value = raw == null
        ? <String, dynamic>{}
        : materialJson(jsonDecode(raw));
    return MaterialResult(
      key: row['item_key'] as String,
      label: value['label'] as String? ?? '上一次请求',
      text: value['text'] as String? ?? '',
      sources: [
        for (final entry in value['sources'] as List? ?? const [])
          Evidence.fromJson(materialJson(entry)),
      ],
      data: materialJson(value['data']),
      state: row['state'] as String,
      issue: row['issue'] as String?,
      usage: row['usage'] == null
          ? null
          : TokenUsage.fromJson(
              materialJson(jsonDecode(row['usage'] as String)),
            ),
      reserved: (row['input_budget'] as int) + (row['output_budget'] as int),
      billedCharacters: value['billedCharacters'] as int?,
      billingUnit: value['billingUnit'] as String? ?? 'token',
    );
  }
}

class MaterialProgress {
  const MaterialProgress({
    required this.done,
    required this.total,
    required this.spent,
    required this.budget,
    this.estimated = 0,
    this.message = '',
  });

  final int done;
  final int total;
  final int spent;
  final int budget;
  final int estimated;
  final String message;
}

class ExerciseQuestion {
  const ExerciseQuestion(this.number, this.stem, this.sources);
  final String number;
  final String stem;
  final List<Evidence> sources;
}

/// Extracts all question numbers mentioned in a natural-language instruction,
/// e.g. "把第 3、7 题收进错题本" or "把第3题和第7题收进错题本".
Set<String> parseRequestedQuestionNumbers(String input) {
  final selected = <String>{};
  final pattern = RegExp(
    r'第\s*(\d+(?:\s*[、，,和及与\s]\s*\d+)*)\s*题',
  );
  for (final match in pattern.allMatches(input)) {
    final group = match.group(1) ?? '';
    for (final numMatch in RegExp(r'\d+').allMatches(group)) {
      final token = numMatch.group(0);
      if (token != null && token.isNotEmpty) selected.add(token);
    }
  }
  return selected;
}

class ProtectedTranslation {
  ProtectedTranslation(String input, {Map<String, String> glossary = const {}})
    : source = input {
    final formulas = parseFormulas(source);
    final candidates = <(int, int, String)>[
      for (final f in formulas)
        (f.start, f.end, source.substring(f.start, f.end)),
    ];
    final terms = glossary.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final term in terms.take(100)) {
      for (final match in RegExp(
        RegExp.escape(term),
        caseSensitive: false,
      ).allMatches(source)) {
        if (!candidates.any(
          (span) => match.start < span.$2 && match.end > span.$1,
        )) {
          candidates.add((match.start, match.end, glossary[term]!));
        }
      }
    }
    final pattern = RegExp(
      r'https?://[^\s]+|\b10\.\d{4,9}/[^\s]+|\[(?:\d+(?:[–,\- ]\d+)*|QZP\d{4})\]|'
      r'(?:Fig\.?|Table|Figure|图|表)\s*\d+[A-Za-z]?|'
      r'[-−+]?\d+(?:[.,]\d+)*(?:\s*(?:%|°C|μm|µm|nm|kg|mg|mm|mL|mol|kPa|MPa|Hz|J|g|m)(?![A-Za-z]))?',
      caseSensitive: false,
    );
    for (final match in pattern.allMatches(source)) {
      if (candidates.any(
        (span) => match.start < span.$2 && match.end > span.$1,
      )) {
        continue;
      }
      candidates.add((match.start, match.end, match[0]!));
    }
    candidates.sort((a, b) => a.$1.compareTo(b.$1));
    var offset = 0;
    final result = StringBuffer();
    for (final span in candidates) {
      final marker = '[QZP${_values.length.toString().padLeft(4, '0')}]';
      result.write(source.substring(offset, span.$1));
      result.write(marker);
      _values[marker] = span.$3;
      offset = span.$2;
    }
    result.write(source.substring(offset));
    masked = result.toString();
  }

  final String source;
  late final String masked;
  final _values = <String, String>{};

  String restore(String translation) {
    final pattern = RegExp(r'\[QZP\d{4}\]');
    final markers = pattern
        .allMatches(translation)
        .map((entry) => entry[0]!)
        .toList();
    if (markers.length != _values.length ||
        markers.toSet().length != _values.length ||
        !markers.every(_values.containsKey)) {
      throw const FormatException('译文缺少或重复了公式、数值或引文占位符。');
    }
    return translation.replaceAllMapped(pattern, (match) => _values[match[0]]!);
  }
}
