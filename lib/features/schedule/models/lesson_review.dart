import 'calendar_block.dart';
import 'daily_lesson.dart';
import 'learning_record.dart';
import 'study_task.dart';

/// A self-checked lesson attempt marked "needs review". It joins the formal
/// learning record to the task, block, lesson and exercise for the review page.
class LessonReviewItem {
  const LessonReviewItem({
    required this.record,
    required this.task,
    required this.block,
    required this.lesson,
    required this.exercise,
  });

  final LearningRecord record;
  final StudyTask task;
  final CalendarBlock? block;
  final DailyLesson lesson;
  final LessonExercise exercise;

  String get title => task.title;
  String get answer => record.note;
}
