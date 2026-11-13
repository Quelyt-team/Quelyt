/// Minute-of-day helpers used by every schedule model.
///
/// A block stores local wall-clock minutes (00:00 is 0, 24:00 is 1440). The
/// plan stores an IANA zone separately; no model converts a UTC instant into a
/// date key.
const int minutesPerDay = 24 * 60;

String formatMinuteOfDay(int minute) {
  if (minute < 0 || minute > minutesPerDay) {
    throw RangeError.range(minute, 0, minutesPerDay, 'minute');
  }
  final hour = minute ~/ 60;
  final rest = minute % 60;
  return '${hour.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}';
}

/// Parses `H:mm` or `HH:mm`.
int parseMinuteOfDay(String value) {
  final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value.trim());
  if (match == null) {
    throw FormatException('Expected HH:mm', value);
  }
  final hour = int.parse(match.group(1)!);
  final minute = int.parse(match.group(2)!);
  if (hour > 24 || minute > 59 || (hour == 24 && minute != 0)) {
    throw FormatException('Expected HH:mm within one day', value);
  }
  return hour * 60 + minute;
}

int? tryParseMinuteOfDay(String value) {
  try {
    return parseMinuteOfDay(value);
  } catch (_) {
    return null;
  }
}

String formatDuration(int minutes) {
  if (minutes < 0) throw ArgumentError.value(minutes, 'minutes');
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  if (hours == 0) return '$rest 分钟';
  if (rest == 0) return '$hours 小时';
  return '$hours 小时 $rest 分钟';
}

/// A half-open interval `[startMinute, endMinute)` inside one calendar day.
class TimeRange {
  const TimeRange(this.startMinute, this.endMinute);

  final int startMinute;
  final int endMinute;

  int get minutes => endMinute - startMinute;

  bool get isValid =>
      startMinute >= 0 &&
      endMinute <= minutesPerDay &&
      endMinute > startMinute;

  bool overlaps(TimeRange other) =>
      startMinute < other.endMinute && endMinute > other.startMinute;

  bool contains(TimeRange other) =>
      startMinute <= other.startMinute && endMinute >= other.endMinute;

  TimeRange? intersection(TimeRange other) {
    final start = startMinute > other.startMinute ? startMinute : other.startMinute;
    final end = endMinute < other.endMinute ? endMinute : other.endMinute;
    return end > start ? TimeRange(start, end) : null;
  }

  String get label => '${formatMinuteOfDay(startMinute)}–'
      '${formatMinuteOfDay(endMinute)}';

  @override
  bool operator ==(Object other) =>
      other is TimeRange &&
      startMinute == other.startMinute &&
      endMinute == other.endMinute;

  @override
  int get hashCode => Object.hash(startMinute, endMinute);

  @override
  String toString() => label;
}

/// Splits [range] by subtracting each busy interval.
List<TimeRange> subtractRanges(
  TimeRange range,
  Iterable<TimeRange> busy,
) {
  var parts = <TimeRange>[range];
  for (final block in busy) {
    if (!block.isValid) continue;
    final next = <TimeRange>[];
    for (final part in parts) {
      final overlap = part.intersection(block);
      if (overlap == null) {
        next.add(part);
        continue;
      }
      if (part.startMinute < overlap.startMinute) {
        next.add(TimeRange(part.startMinute, overlap.startMinute));
      }
      if (overlap.endMinute < part.endMinute) {
        next.add(TimeRange(overlap.endMinute, part.endMinute));
      }
    }
    parts = next;
    if (parts.isEmpty) break;
  }
  return parts;
}

/// Merges overlapping or touching ranges and sorts the result.
List<TimeRange> mergeRanges(Iterable<TimeRange> ranges) {
  final sorted = ranges.where((range) => range.isValid).toList()
    ..sort((a, b) => a.startMinute.compareTo(b.startMinute));
  final merged = <TimeRange>[];
  for (final range in sorted) {
    if (merged.isEmpty) {
      merged.add(range);
      continue;
    }
    final last = merged.last;
    if (range.startMinute <= last.endMinute) {
      merged[merged.length - 1] = TimeRange(
        last.startMinute,
        range.endMinute > last.endMinute ? range.endMinute : last.endMinute,
      );
    } else {
      merged.add(range);
    }
  }
  return merged;
}
