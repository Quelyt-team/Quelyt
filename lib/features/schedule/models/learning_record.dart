enum LearningFact { completed, partial, skipped, opened, noted }

extension LearningFactLabel on LearningFact {
  String get label => switch (this) {
    LearningFact.completed => '完成',
    LearningFact.partial => '部分完成',
    LearningFact.skipped => '跳过',
    LearningFact.opened => '打开',
    LearningFact.noted => '记录',
  };
}

/// A fact about what actually happened. Opening a page is not completion, and
/// the record keeps the difference.
class LearningRecord {
  LearningRecord({
    required this.id,
    this.blockId,
    this.taskId,
    required this.fact,
    required this.minutes,
    this.note = '',
    required this.occurredAt,
    required this.operationId,
  });

  final String id;
  final String? blockId;
  final String? taskId;
  final LearningFact fact;
  final int minutes;
  final String note;
  final DateTime occurredAt;
  final String operationId;

  Map<String, dynamic> toJson() => {
    'id': id,
    'blockId': blockId,
    'taskId': taskId,
    'fact': fact.name,
    'minutes': minutes,
    'note': note,
    'occurredAt': occurredAt.toIso8601String(),
    'operationId': operationId,
  };

  factory LearningRecord.fromJson(Map<String, dynamic> json) => LearningRecord(
    id: json['id'] as String,
    blockId: json['blockId'] as String?,
    taskId: json['taskId'] as String?,
    fact: LearningFact.values.byName(json['fact'] as String),
    minutes: (json['minutes'] as num).toInt(),
    note: json['note'] as String? ?? '',
    occurredAt: DateTime.parse(json['occurredAt'] as String),
    operationId: json['operationId'] as String,
  );
}
