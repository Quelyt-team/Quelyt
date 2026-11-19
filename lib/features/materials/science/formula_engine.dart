import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show rootBundle;

class FormulaGraphic {
  const FormulaGraphic(this.svg, this.widthEx, this.heightEx, this.depthEx);

  final String svg;
  final double widthEx;
  final double heightEx;
  final double depthEx;
}

class FormulaEngine {
  FormulaEngine._();

  static final shared = FormulaEngine._();
  static const version = 'mathjax-3.2.2-svg-1';
  final _cache = <(String, bool), Future<FormulaGraphic?>>{};
  Future<_FormulaRuntime?>? _runtime;
  Future<void> _queue = Future.value();

  Future<_FormulaRuntime?> _start() async {
    _FormulaRuntime? runtime;
    try {
      final script = await rootBundle.loadString('assets/science/mathjax.js');
      runtime = _FormulaRuntime();
      if (await runtime.evaluate(script) == null) return null;
      return runtime;
    } catch (_) {
      return null;
    }
  }

  Future<FormulaGraphic?> render(String latex, {required bool display}) {
    if (latex.isEmpty || latex.length > 4000) return Future.value(null);
    final key = (latex, display);
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached;
    }
    final result = _queue.then((_) => _render(latex, display));
    _queue = result.then<void>((_) {});
    _cache[key] = result;
    if (_cache.length > 192) _cache.remove(_cache.keys.first);
    return result;
  }

  Future<FormulaGraphic?> _render(String latex, bool display) async {
    final runtime = await (_runtime ??= _start());
    if (runtime == null) return null;
    try {
      final result = await runtime.evaluate(
        'globalThis.quelytFormula(${jsonEncode(latex)}, $display)',
      );
      if (result == null) return null;
      final data = jsonDecode(result) as Map;
      final svg = data['svg'] as String;
      final width = (data['width'] as num).toDouble();
      final height = (data['height'] as num).toDouble();
      final depth = (data['depth'] as num).toDouble();
      if (svg.length > 256000 ||
          !svg.startsWith('<svg ') ||
          !width.isFinite ||
          width <= 0 ||
          !height.isFinite ||
          height <= 0 ||
          !depth.isFinite) {
        return null;
      }
      return FormulaGraphic(svg, width, height, depth);
    } catch (_) {
      return null;
    }
  }
}

typedef _NativeEvaluate = Pointer<Utf8> Function(Pointer<Utf8>, Size);
typedef _NativeFree = Void Function(Pointer<Utf8>);

/// The native worker owns one engine on a thread with a known stack size.
/// Waiting for the worker also happens off the UI isolate.
class _FormulaRuntime {
  _FormulaRuntime() {
    final library = switch (Platform.operatingSystem) {
      'windows' => _openWindowsWorker(),
      'android' => DynamicLibrary.open('libquelyt_formula.so'),
      _ => throw UnsupportedError('Native formula worker is unavailable.'),
    };
    _evaluateAddress = library
        .lookup<NativeFunction<_NativeEvaluate>>('quelyt_formula_evaluate')
        .address;
    _freeAddress = library
        .lookup<NativeFunction<_NativeFree>>('quelyt_formula_free')
        .address;
  }

  late final int _evaluateAddress;
  late final int _freeAddress;

  static DynamicLibrary _openWindowsWorker() {
    // Flutter's test host does not run the Windows plugin registrant.
    DynamicLibrary.open('flutter_qjs_next_plugin.dll');
    return DynamicLibrary.open('quelyt_formula.dll');
  }

  Future<String?> evaluate(String source) {
    final evaluateAddress = _evaluateAddress;
    final freeAddress = _freeAddress;
    return Isolate.run(() => _evaluate(source, evaluateAddress, freeAddress));
  }

  static String? _evaluate(
    String source,
    int evaluateAddress,
    int freeAddress,
  ) => using((memory) {
    final evaluate = Pointer<NativeFunction<_NativeEvaluate>>.fromAddress(
      evaluateAddress,
    ).asFunction<Pointer<Utf8> Function(Pointer<Utf8>, int)>();
    final free = Pointer<NativeFunction<_NativeFree>>.fromAddress(freeAddress)
        .asFunction<void Function(Pointer<Utf8>)>();
    final code = source.toNativeUtf8(allocator: memory);
    final result = evaluate(code, code.length);
    if (result == nullptr) return null;
    try {
      return result.toDartString();
    } finally {
      free(result);
    }
  });
}
