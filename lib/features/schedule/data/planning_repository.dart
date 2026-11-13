import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../../core/local_store.dart';
import '../../../services/ai_types.dart';
import '../models/planning_models.dart';

/// Persists planning conversations outside settings. A conversation is tied to
/// one plan scope (or a new-plan scope with a null plan id); deleting the plan
/// removes its conversations through the foreign key.
class PlanningRepository {
  PlanningRepository(this.store);

  final LocalStore store;
  static const uuid = Uuid();

  PlanningConversation? latestForPlan(String? planId) {
    final rows = planId == null
        ? store.selectRows(
            'SELECT data FROM planning_conversations '
            'WHERE plan_id IS NULL ORDER BY updated_at DESC, id LIMIT 1',
          )
        : store.selectRows(
            'SELECT data FROM planning_conversations '
            'WHERE plan_id = ? ORDER BY updated_at DESC, id LIMIT 1',
            [planId],
          );
    return rows.isEmpty
        ? null
        : PlanningConversation.fromJson(_decode(rows.first));
  }

  PlanningConversation getOrCreate({String? planId}) {
    final existing = latestForPlan(planId);
    if (existing != null) return existing;
    return createConversation(planId: planId);
  }

  PlanningConversation createConversation({String? planId}) {
    final now = DateTime.now();
    final conversation = PlanningConversation(
      id: uuid.v4(),
      planId: planId,
      createdAt: now,
      updatedAt: now,
    );
    store.transact(() => _writeConversation(conversation));
    return conversation;
  }

  PlanningConversation? getConversation(String id) {
    final rows = store.selectRows(
      'SELECT data FROM planning_conversations WHERE id = ?',
      [id],
    );
    return rows.isEmpty
        ? null
        : PlanningConversation.fromJson(_decode(rows.first));
  }

  List<PlanningMessage> messages(String conversationId) {
    final rows = store.selectRows(
      'SELECT data FROM planning_messages WHERE conversation_id = ? '
      'ORDER BY sequence, id',
      [conversationId],
    );
    return rows.map((row) => PlanningMessage.fromJson(_decode(row))).toList();
  }

  PlanningMessage? getMessage(String id) {
    final rows = store.selectRows(
      'SELECT data FROM planning_messages WHERE id = ?',
      [id],
    );
    return rows.isEmpty
        ? null
        : PlanningMessage.fromJson(_decode(rows.first));
  }

  void markApplied(String messageId) {
    store.transact(() {
      final message = getMessage(messageId);
      if (message == null) return;
      final data = message.copyWith(applied: true).toJson();
      store.executeSql('UPDATE planning_messages SET data = ? WHERE id = ?', [
        jsonEncode(data),
        messageId,
      ]);
    });
  }

  PlanningMessage appendMessage({
    required String conversationId,
    required PlanningRole role,
    required PlanningKind kind,
    required String text,
    String? requestId,
    PlanningProposal? proposal,
    List<PlanningQuestion> questions = const [],
    String? model,
    TokenUsage? usage,
    bool failed = false,
    List<String> missingMaterial = const [],
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    return store.transact(() {
      final conversation = getConversation(conversationId);
      if (conversation == null) {
        throw StateError('Planning conversation no longer exists.');
      }
      final rows = store.selectRows(
        'SELECT COALESCE(MAX(sequence), -1) + 1 AS next '
        'FROM planning_messages WHERE conversation_id = ?',
        [conversationId],
      );
      final sequence = (rows.first['next'] as num).toInt();
      final message = PlanningMessage(
        id: uuid.v4(),
        conversationId: conversationId,
        sequence: sequence,
        role: role,
        kind: kind,
        text: text,
        createdAt: at,
        requestId: requestId,
        proposal: proposal,
        questions: questions,
        model: model,
        usage: usage,
        failed: failed,
        missingMaterial: missingMaterial,
      );
      store.executeSql(
        '''
        INSERT INTO planning_messages
          (id, conversation_id, sequence, role, kind, created_at, request_id, data)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          message.id,
          conversationId,
          sequence,
          role.name,
          kind.name,
          at.millisecondsSinceEpoch,
          requestId,
          jsonEncode(message.toJson()),
        ],
      );
      _writeConversation(
        conversation.copyWith(updatedAt: at),
      );
      return message;
    });
  }

  void attachConversationToPlan(String conversationId, String planId) {    store.transact(() {
      final conversation = getConversation(conversationId);
      if (conversation == null) return;
      final updated = conversation.copyWith(planId: planId);
      _writeConversation(updated);
    });
  }

  void deleteConversation(String id) {
    store.transact(() {
      store.executeSql('DELETE FROM planning_conversations WHERE id = ?', [id]);
    });
  }

  void _writeConversation(PlanningConversation conversation) {
    store.executeSql(
      '''
      INSERT INTO planning_conversations
        (id, plan_id, created_at, updated_at, data)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET plan_id=excluded.plan_id,
        updated_at=excluded.updated_at, data=excluded.data
      ''',
      [
        conversation.id,
        conversation.planId,
        conversation.createdAt.millisecondsSinceEpoch,
        conversation.updatedAt.millisecondsSinceEpoch,
        jsonEncode(conversation.toJson()),
      ],
    );
  }

  static Map<String, dynamic> _decode(Map<String, Object?> row) =>
      Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map);
}
