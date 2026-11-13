import 'local_date.dart';

class CatchUpSuggestion {
  const CatchUpSuggestion({
    required this.date,
    required this.startMinute,
    required this.endMinute,
  });

  final LocalDate date;
  final int startMinute;
  final int endMinute;

  int get minutes => endMinute - startMinute;

  String get timeLabel {
    String format(int minute) =>
        '${(minute ~/ 60).toString().padLeft(2, '0')}:'
        '${(minute % 60).toString().padLeft(2, '0')}';
    return '${date.shortLabel} ${format(startMinute)}–${format(endMinute)}';
  }
}
