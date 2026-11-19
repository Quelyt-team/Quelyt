import 'dart:convert';
import 'dart:typed_data';

/// Parsed text blocks extracted offline from a legacy `.doc` file (MS-CFB +
/// MS-DOC Word 97–2003 binary format, or disguised RTF / HTML saved with `.doc`).
class LegacyDocContent {
  const LegacyDocContent(this.blocks);

  final List<LegacyDocBlock> blocks;
}

sealed class LegacyDocBlock {
  const LegacyDocBlock();
}

final class LegacyDocParagraph extends LegacyDocBlock {
  const LegacyDocParagraph(this.text);
  final String text;
}

final class LegacyDocTable extends LegacyDocBlock {
  const LegacyDocTable(this.rows);
  final List<List<String>> rows;
}

final class LegacyDocPageBreak extends LegacyDocBlock {
  const LegacyDocPageBreak();
}

/// Offline parser for legacy `.doc` files:
/// 1. OLE2 Compound File Binary Format (`MS-CFB`) + Word 97–2003 (`MS-DOC`)
///    piece-table (`Clx`/`PlcPcd`) extractor supporting UTF-16LE (CJK/Unicode)
///    and compressed CP1252 runs, field-code stripping, and table reconstruction.
/// 2. RTF files saved with a `.doc` extension (`{\rtf...`).
/// 3. HTML/MHTML files saved with a `.doc` extension.
class LegacyDocParser {
  const LegacyDocParser();

  static const _ole2Magic = <int>[0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
  static const _zipMagic = <int>[0x50, 0x4B, 0x03, 0x04];

  static bool isZipBytes(Uint8List bytes) =>
      bytes.length >= 4 &&
      bytes[0] == _zipMagic[0] &&
      bytes[1] == _zipMagic[1] &&
      bytes[2] == _zipMagic[2] &&
      bytes[3] == _zipMagic[3];

  static bool isOle2Bytes(Uint8List bytes) {
    if (bytes.length < 512) return false;
    for (var i = 0; i < _ole2Magic.length; i++) {
      if (bytes[i] != _ole2Magic[i]) return false;
    }
    return true;
  }

  LegacyDocContent parse(Uint8List bytes) {
    if (isOle2Bytes(bytes)) {
      return _parseOle2Word(bytes);
    }
    final prefix = _asciiPrefix(bytes, 512).trimLeft();
    if (prefix.startsWith(r'{\rtf')) {
      return _parseRtf(bytes);
    }
    final lower = prefix.toLowerCase();
    if (lower.startsWith('<html') ||
        lower.startsWith('<!doctype') ||
        lower.startsWith('<meta') ||
        lower.contains('<body') ||
        lower.startsWith('mime-version:')) {
      return _parseHtmlLike(bytes);
    }
    throw const FormatException('无法识别此 DOC 文件格式，请确认文件未损坏。');
  }

  LegacyDocContent _parseOle2Word(Uint8List bytes) {
    final cfb = _CfbReader(bytes);
    final wordDoc = cfb.readStream('WordDocument');
    if (wordDoc == null || wordDoc.length < 68) {
      throw const FormatException('DOC 文件缺少 WordDocument 正文流。');
    }
    final fib = ByteData.sublistView(wordDoc);
    final wIdent = fib.getUint16(0, Endian.little);
    if (wIdent != 0xA5EC && wIdent != 0xA5DC) {
      throw const FormatException('此 OLE2 文件不是有效的 Word DOC 文档。');
    }
    final flags = fib.getUint16(10, Endian.little);
    final encrypted = (flags & 0x0100) != 0;
    if (encrypted) {
      throw const FormatException('此 DOC 文档已加密，暂不支持直接解析。');
    }

    String rawText;
    if (wIdent == 0xA5EC) {
      rawText = _extractWord97Text(cfb, wordDoc, flags);
    } else {
      rawText = _extractWord6Text(wordDoc);
    }
    return _buildBlocksFromRawWordText(rawText);
  }

  String _extractWord97Text(_CfbReader cfb, Uint8List wordDoc, int flags) {
    final fib = ByteData.sublistView(wordDoc);
    final use1Table = (flags & 0x0200) != 0;
    final tableStream =
        cfb.readStream(use1Table ? '1Table' : '0Table') ??
        cfb.readStream(use1Table ? '0Table' : '1Table');
    if (tableStream == null) {
      throw const FormatException('DOC 文件缺少样式与字符位置表（Table 流）。');
    }

    // Walk FIB variable sections: FibBase (32) -> csw + FibRgW -> cslw + FibRgLw -> cbRgFcLcb + FibRgFcLcb.
    var pos = 32;
    if (pos + 2 > wordDoc.length) {
      throw const FormatException('DOC 文件头不完整。');
    }
    final csw = fib.getUint16(pos, Endian.little);
    pos += 2 + csw * 2;
    if (pos + 2 > wordDoc.length) {
      throw const FormatException('DOC 文件头不完整。');
    }
    final cslw = fib.getUint16(pos, Endian.little);
    final fibRgLwStart = pos + 2;
    final ccpText = cslw > 3 && fibRgLwStart + 16 <= wordDoc.length
        ? fib.getUint32(fibRgLwStart + 12, Endian.little)
        : 0;
    pos = fibRgLwStart + cslw * 4;
    if (pos + 2 > wordDoc.length) {
      throw const FormatException('DOC 文件头不完整。');
    }
    final cbRgFcLcb = fib.getUint16(pos, Endian.little);
    final fibRgFcLcbStart = pos + 2;
    // Index 33 in FibRgFcLcb97 is (fcClx, lcbClx).
    if (cbRgFcLcb <= 33 || fibRgFcLcbStart + 34 * 8 > wordDoc.length) {
      throw const FormatException('DOC 文件缺少文本分片表索引（Clx）。');
    }
    final fcClx = fib.getUint32(fibRgFcLcbStart + 33 * 8, Endian.little);
    final lcbClx = fib.getUint32(fibRgFcLcbStart + 33 * 8 + 4, Endian.little);
    if (lcbClx == 0 || fcClx + lcbClx > tableStream.length) {
      throw const FormatException('DOC 文件文本分片表（Clx）超出范围。');
    }

    final tableData = ByteData.sublistView(tableStream);
    var offset = fcClx;
    final end = fcClx + lcbClx;
    final out = StringBuffer();
    var extractedChars = 0;

    while (offset < end) {
      final clxt = tableStream[offset];
      if (clxt == 0x01) {
        if (offset + 3 > end) break;
        final cbGrpprl = tableData.getUint16(offset + 1, Endian.little);
        offset += 3 + cbGrpprl;
      } else if (clxt == 0x02) {
        if (offset + 5 > end) break;
        final lcb = tableData.getUint32(offset + 1, Endian.little);
        final plcStart = offset + 5;
        if (lcb < 4 || plcStart + lcb > end) break;
        final pieceCount = (lcb - 4) ~/ 12;
        final pcdBase = plcStart + (pieceCount + 1) * 4;
        for (var i = 0; i < pieceCount; i++) {
          final cpStart = tableData.getUint32(plcStart + i * 4, Endian.little);
          final cpEnd = tableData.getUint32(
            plcStart + (i + 1) * 4,
            Endian.little,
          );
          if (cpEnd <= cpStart) continue;
          var charCount = cpEnd - cpStart;
          if (ccpText > 0 && extractedChars >= ccpText) break;
          if (ccpText > 0 && extractedChars + charCount > ccpText) {
            charCount = ccpText - extractedChars;
          }
          final pcdOffset = pcdBase + i * 8;
          if (pcdOffset + 8 > plcStart + lcb) break;
          final fcField = tableData.getUint32(pcdOffset + 2, Endian.little);
          final compressed = (fcField & 0x40000000) != 0;
          final byteOffset = compressed
              ? ((fcField & 0x3FFFFFFF) >> 1)
              : (fcField & 0x3FFFFFFF);
          if (compressed) {
            final safeEnd = (byteOffset + charCount).clamp(0, wordDoc.length);
            if (byteOffset < safeEnd) {
              out.write(_decodeCp1252(wordDoc, byteOffset, safeEnd));
            }
          } else {
            final byteLen = charCount * 2;
            final safeEnd = (byteOffset + byteLen).clamp(0, wordDoc.length);
            if (byteOffset < safeEnd) {
              final units = (safeEnd - byteOffset) ~/ 2;
              final codes = Uint16List(units);
              for (var k = 0; k < units; k++) {
                codes[k] = fib.getUint16(byteOffset + k * 2, Endian.little);
              }
              out.write(String.fromCharCodes(codes));
            }
          }
          extractedChars += charCount;
        }
        break;
      } else {
        break;
      }
    }
    return out.toString();
  }

  /// Basic fallback for pre-Word 97 (`0xA5DC`, Word 6.0/95) binary streams.
  String _extractWord6Text(Uint8List wordDoc) {
    final fib = ByteData.sublistView(wordDoc);
    final fcMin = fib.getUint32(24, Endian.little);
    final fcMac = fib.getUint32(28, Endian.little);
    if (fcMin >= fcMac || fcMac > wordDoc.length) {
      throw const FormatException('无法读取旧版 Word 6/95 正文范围。');
    }
    return _decodeCp1252(wordDoc, fcMin, fcMac);
  }

  LegacyDocContent _buildBlocksFromRawWordText(String raw) {
    final cleaned = _stripWordFields(raw);
    final blocks = <LegacyDocBlock>[];
    final pendingRows = <List<String>>[];
    var currentRow = <String>[];
    final cellBuf = StringBuffer();

    void flushTable() {
      if (currentRow.isNotEmpty) {
        pendingRows.add(currentRow);
        currentRow = [];
      }
      if (pendingRows.isNotEmpty) {
        blocks.add(LegacyDocTable(List.of(pendingRows)));
        pendingRows.clear();
      }
    }

    void flushParagraph() {
      final text = cellBuf.toString().trim();
      cellBuf.clear();
      if (text.isNotEmpty) {
        flushTable();
        blocks.add(LegacyDocParagraph(text));
      }
    }

    for (var i = 0; i < cleaned.length; i++) {
      final code = cleaned.codeUnitAt(i);
      if (code == 0x07) {
        // Table cell / row delimiter in MS-DOC.
        final cellText = cellBuf.toString().trim();
        cellBuf.clear();
        if (cellText.isEmpty && currentRow.isNotEmpty) {
          pendingRows.add(currentRow);
          currentRow = [];
        } else {
          currentRow.add(cellText);
        }
      } else if (code == 0x0D) {
        // Paragraph break.
        if (currentRow.isNotEmpty) {
          // Paragraph break inside a table cell.
          if (cellBuf.isNotEmpty) cellBuf.write('\n');
        } else {
          flushParagraph();
        }
      } else if (code == 0x0C) {
        flushParagraph();
        flushTable();
        if (blocks.isNotEmpty && blocks.last is! LegacyDocPageBreak) {
          blocks.add(const LegacyDocPageBreak());
        }
      } else if (code == 0x0B) {
        cellBuf.write('\n');
      } else if (code == 0x09) {
        cellBuf.write('    ');
      } else if (code >= 0x20 || code == 0x0A) {
        cellBuf.writeCharCode(code);
      }
    }
    flushParagraph();
    flushTable();
    return LegacyDocContent(blocks);
  }

  /// Strips Word field control sequences (`0x13 ... [0x14 visible] 0x15`) while
  /// preserving visible field results (e.g. hyperlinks, equation display text).
  String _stripWordFields(String input) {
    final out = StringBuffer();
    final stack = <bool>[]; // true = inside visible result (after 0x14)
    for (var i = 0; i < input.length; i++) {
      final code = input.codeUnitAt(i);
      if (code == 0x13) {
        stack.add(false);
      } else if (code == 0x14) {
        if (stack.isNotEmpty) stack[stack.length - 1] = true;
      } else if (code == 0x15) {
        if (stack.isNotEmpty) stack.removeLast();
      } else if (stack.isEmpty || stack.every((visible) => visible)) {
        out.writeCharCode(code);
      }
    }
    return out.toString();
  }

  LegacyDocContent _parseRtf(Uint8List bytes) {
    final source = latin1.decode(bytes, allowInvalid: true);
    final out = StringBuffer();
    final skipStack = <bool>[false];
    const skipDestinations = {
      'fonttbl',
      'colortbl',
      'stylesheet',
      'info',
      'pict',
      'object',
      'header',
      'footer',
      'headerl',
      'headerr',
      'footerl',
      'footerr',
      'listtable',
      'listoverridetable',
      'xmlnstbl',
      'themedata',
      'colorschememapping',
      'datastore',
      'latentstyles',
    };
    var ucSkip = 1;
    var i = 0;
    while (i < source.length) {
      final ch = source[i];
      if (ch == '{') {
        skipStack.add(skipStack.last);
        i++;
      } else if (ch == '}') {
        if (skipStack.length > 1) skipStack.removeLast();
        i++;
      } else if (ch == r'\') {
        i++;
        if (i >= source.length) break;
        final next = source[i];
        if (next == r'\' || next == '{' || next == '}') {
          if (!skipStack.last) out.write(next);
          i++;
        } else if (next == '*') {
          skipStack[skipStack.length - 1] = true;
          i++;
        } else if (next == '~') {
          if (!skipStack.last) out.write(' ');
          i++;
        } else if (next == '\n' || next == '\r') {
          if (!skipStack.last) out.write('\n');
          i++;
        } else if (next == "'") {
          // Hex-escaped byte(s), skip if suppressed.
          if (i + 2 < source.length) {
            final hex = int.tryParse(source.substring(i + 1, i + 3), radix: 16);
            if (!skipStack.last && hex != null) {
              out.writeCharCode(hex);
            }
            i += 3;
          } else {
            i++;
          }
        } else if (_isAsciiLetter(next.codeUnitAt(0))) {
          final start = i;
          while (i < source.length && _isAsciiLetter(source.codeUnitAt(i))) {
            i++;
          }
          final word = source.substring(start, i);
          int? param;
          final numStart = i;
          if (i < source.length && (source[i] == '-' || _isDigit(source.codeUnitAt(i)))) {
            i++;
            while (i < source.length && _isDigit(source.codeUnitAt(i))) {
              i++;
            }
            param = int.tryParse(source.substring(numStart, i));
          }
          if (i < source.length && source[i] == ' ') i++;

          if (skipDestinations.contains(word)) {
            skipStack[skipStack.length - 1] = true;
          } else if (!skipStack.last) {
            if (word == 'uc' && param != null && param >= 0) {
              ucSkip = param;
            } else if (word == 'u' && param != null) {
              final codeUnit = param < 0 ? param + 65536 : param;
              if (codeUnit >= 0x20) out.writeCharCode(codeUnit);
              // Skip fallback replacement characters after \uN.
              var skipped = 0;
              while (skipped < ucSkip && i < source.length) {
                if (source[i] == r'\' &&
                    i + 3 < source.length &&
                    source[i + 1] == "'") {
                  i += 4;
                } else if (source[i] == '{' || source[i] == '}') {
                  break;
                } else {
                  i++;
                }
                skipped++;
              }
            } else if (word == 'par' || word == 'line') {
              out.write('\n');
            } else if (word == 'tab') {
              out.write('    ');
            } else if (word == 'page') {
              out.write('\x0C');
            }
          }
        } else {
          i++;
        }
      } else if (ch == '\r' || ch == '\n') {
        i++;
      } else {
        if (!skipStack.last) out.write(ch);
        i++;
      }
    }
    final blocks = <LegacyDocBlock>[];
    for (final section in out.toString().split('\x0C')) {
      for (final line in section.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) blocks.add(LegacyDocParagraph(trimmed));
      }
      if (blocks.isNotEmpty && blocks.last is! LegacyDocPageBreak) {
        blocks.add(const LegacyDocPageBreak());
      }
    }
    if (blocks.isNotEmpty && blocks.last is LegacyDocPageBreak) {
      blocks.removeLast();
    }
    return LegacyDocContent(blocks);
  }

  LegacyDocContent _parseHtmlLike(Uint8List bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    final stripped = text
        .replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), '')
        .replaceAll(
          RegExp(r'</(?:p|div|h[1-6]|li|tr|br)\s*/?>', caseSensitive: false),
          '\n',
        )
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"');
    final blocks = <LegacyDocBlock>[
      for (final line in stripped.split('\n'))
        if (line.trim().isNotEmpty) LegacyDocParagraph(line.trim()),
    ];
    return LegacyDocContent(blocks);
  }

  static String _asciiPrefix(Uint8List bytes, int maxLen) {
    final len = bytes.length < maxLen ? bytes.length : maxLen;
    return String.fromCharCodes(bytes.sublist(0, len));
  }

  static bool _isAsciiLetter(int c) =>
      (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  static const _cp1252Extras = <int, int>{
    0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026,
    0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160,
    0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019,
    0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
    0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153,
    0x9E: 0x017E, 0x9F: 0x0178,
  };

  static String _decodeCp1252(Uint8List bytes, int start, int end) {
    final codes = Uint16List(end - start);
    for (var i = start; i < end; i++) {
      final b = bytes[i];
      codes[i - start] = _cp1252Extras[b] ?? b;
    }
    return String.fromCharCodes(codes);
  }
}

/// Minimal read-only Microsoft Compound File Binary Format (OLE2 / MS-CFB)
/// container reader.
class _CfbReader {
  _CfbReader(this.bytes) : _view = ByteData.sublistView(bytes) {
    final sectorShift = _view.getUint16(30, Endian.little);
    final miniSectorShift = _view.getUint16(32, Endian.little);
    if (sectorShift < 7 || sectorShift > 16 || miniSectorShift < 4 || miniSectorShift > sectorShift) {
      throw const FormatException('OLE2 扇区配置无效。');
    }
    sectorSize = 1 << sectorShift;
    miniSectorSize = 1 << miniSectorShift;
    firstDirSector = _view.getUint32(48, Endian.little);
    miniStreamCutoff = _view.getUint32(56, Endian.little);
    firstMiniFatSector = _view.getUint32(60, Endian.little);
    firstDifatSector = _view.getUint32(68, Endian.little);
    numDifatSectors = _view.getUint32(72, Endian.little);

    _fat = _loadFat();
    _miniFat = _loadMiniFat();
    _entries = _loadDirectory();
    final root = _entries.where((e) => e.type == 5).firstOrNull;
    _miniStream = root == null || root.startSector == _endOfChain
        ? Uint8List(0)
        : _readRegularStream(root.startSector, root.size);
  }

  static const int _endOfChain = 0xFFFFFFFE;
  static const int _freeSect = 0xFFFFFFFF;
  static const int _maxValidSect = 0xFFFFFFFA;

  final Uint8List bytes;
  final ByteData _view;
  late final int sectorSize;
  late final int miniSectorSize;
  late final int firstDirSector;
  late final int miniStreamCutoff;
  late final int firstMiniFatSector;
  late final int firstDifatSector;
  late final int numDifatSectors;

  late final List<int> _fat;
  late final List<int> _miniFat;
  late final List<_CfbEntry> _entries;
  late final Uint8List _miniStream;

  int _sectorOffset(int sectorId) => (sectorId + 1) * sectorSize;

  List<int> _loadFat() {
    final fatSectors = <int>[];
    for (var i = 0; i < 109; i++) {
      final sid = _view.getUint32(76 + i * 4, Endian.little);
      if (sid <= _maxValidSect) fatSectors.add(sid);
    }
    var difatSect = firstDifatSector;
    final seenDifat = <int>{};
    final intsPerSector = sectorSize ~/ 4;
    for (var step = 0;
        step < numDifatSectors &&
            difatSect <= _maxValidSect &&
            seenDifat.add(difatSect);
        step++) {
      final off = _sectorOffset(difatSect);
      if (off + sectorSize > bytes.length) break;
      for (var i = 0; i < intsPerSector - 1; i++) {
        final sid = _view.getUint32(off + i * 4, Endian.little);
        if (sid <= _maxValidSect) fatSectors.add(sid);
      }
      difatSect = _view.getUint32(off + (intsPerSector - 1) * 4, Endian.little);
    }

    final fat = <int>[];
    for (final sid in fatSectors) {
      final off = _sectorOffset(sid);
      if (off + sectorSize > bytes.length) continue;
      for (var i = 0; i < intsPerSector; i++) {
        fat.add(_view.getUint32(off + i * 4, Endian.little));
      }
    }
    return fat;
  }

  List<int> _loadMiniFat() {
    if (firstMiniFatSector > _maxValidSect) return const [];
    final raw = _readRegularStream(firstMiniFatSector, null);
    final view = ByteData.sublistView(raw);
    final count = raw.length ~/ 4;
    return List<int>.generate(
      count,
      (i) => view.getUint32(i * 4, Endian.little),
    );
  }

  List<_CfbEntry> _loadDirectory() {
    final raw = _readRegularStream(firstDirSector, null);
    final view = ByteData.sublistView(raw);
    final entries = <_CfbEntry>[];
    for (var off = 0; off + 128 <= raw.length; off += 128) {
      final type = raw[off + 66];
      if (type == 0) continue;
      final nameBytes = view.getUint16(off + 64, Endian.little).clamp(0, 64);
      final charLen = nameBytes >= 2 ? (nameBytes - 2) ~/ 2 : 0;
      final codes = Uint16List(charLen);
      for (var i = 0; i < charLen; i++) {
        codes[i] = view.getUint16(off + i * 2, Endian.little);
      }
      final name = String.fromCharCodes(codes);
      final startSector = view.getUint32(off + 116, Endian.little);
      final sizeLow = view.getUint32(off + 120, Endian.little);
      final sizeHigh = sectorSize >= 4096
          ? view.getUint32(off + 124, Endian.little)
          : 0;
      final size = (sizeHigh << 32) | sizeLow;
      entries.add(_CfbEntry(name, type, startSector, size));
    }
    return entries;
  }

  Uint8List? readStream(String name) {
    final lower = name.toLowerCase();
    final entry = _entries
        .where((e) => e.type == 2 && e.name.toLowerCase() == lower)
        .firstOrNull;
    if (entry == null) return null;
    if (entry.size == 0) return Uint8List(0);
    if (entry.size < miniStreamCutoff && _miniStream.isNotEmpty) {
      return _readMiniStream(entry.startSector, entry.size);
    }
    return _readRegularStream(entry.startSector, entry.size);
  }

  Uint8List _readRegularStream(int startSector, int? expectedSize) {
    final builder = BytesBuilder(copy: false);
    var sid = startSector;
    final visited = <int>{};
    var remaining = expectedSize;
    while (sid <= _maxValidSect && visited.add(sid)) {
      final off = _sectorOffset(sid);
      if (off < 0 || off >= bytes.length) break;
      final avail = (bytes.length - off).clamp(0, sectorSize);
      final take = remaining == null ? avail : remaining.clamp(0, avail);
      builder.add(Uint8List.sublistView(bytes, off, off + take));
      if (remaining != null) {
        remaining -= take;
        if (remaining <= 0) break;
      }
      if (sid >= _fat.length) break;
      sid = _fat[sid];
      if (sid == _endOfChain || sid == _freeSect) break;
    }
    return builder.takeBytes();
  }

  Uint8List _readMiniStream(int startSector, int expectedSize) {
    final builder = BytesBuilder(copy: false);
    var sid = startSector;
    final visited = <int>{};
    var remaining = expectedSize;
    while (sid <= _maxValidSect && visited.add(sid) && remaining > 0) {
      final off = sid * miniSectorSize;
      if (off < 0 || off >= _miniStream.length) break;
      final avail = (_miniStream.length - off).clamp(0, miniSectorSize);
      final take = remaining.clamp(0, avail);
      builder.add(Uint8List.sublistView(_miniStream, off, off + take));
      remaining -= take;
      if (sid >= _miniFat.length) break;
      sid = _miniFat[sid];
      if (sid == _endOfChain || sid == _freeSect) break;
    }
    return builder.takeBytes();
  }
}

class _CfbEntry {
  const _CfbEntry(this.name, this.type, this.startSector, this.size);
  final String name;
  final int type;
  final int startSector;
  final int size;
}
