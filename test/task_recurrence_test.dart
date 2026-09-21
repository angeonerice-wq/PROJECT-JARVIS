// タスク配信の繰り返し設定(recurrence)に関する判定ロジックの単体テスト。
// 過去に「対象日でない繰り返しタスクが、未完了にもかかわらず完了済みと
// 誤表示される」バグが発生したため、再発防止のために用意した。

import 'package:flutter_test/flutter_test.dart';
import 'package:project_jarvis/main.dart';

HistoryEntry _completionReport({required String taskId, required DateTime timestamp}) {
  return HistoryEntry(
    category: 'タスク完了',
    title: 'テストタスク',
    action: SuggestedAction.approveOnly,
    fields: const [],
    history: const [],
    timestamp: timestamp,
    sourceTaskId: taskId,
  );
}

AssignedTask _task({
  required TaskRecurrence recurrence,
  List<int> weekdays = const [],
  DateTime? startDate,
  DateTime? endDate,
}) {
  return AssignedTask(
    id: 'task-1',
    staffId: 'staff-1',
    assignedBy: 'sv-1',
    title: 'テストタスク',
    detail: '',
    createdAt: DateTime.now(),
    recurrence: recurrence,
    weekdays: weekdays,
    startDate: startDate,
    endDate: endDate,
  );
}

void main() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day, 10);
  final yesterday = today.subtract(const Duration(days: 1));
  // 今日以外の曜日(今日が月曜なら火曜、それ以外なら月曜)を「対象外の曜日」として使う。
  final otherWeekday = now.weekday == 1 ? 2 : 1;

  group('once', () {
    test('完了報告が無ければ要対応、完了実績も無し', () {
      final task = _task(recurrence: TaskRecurrence.once);
      expect(needsTaskActionToday(task, []), isTrue);
      expect(hasTaskCompletionRecord(task, []), isFalse);
    });

    test('過去(今日ではない日)の完了報告でも、全期間ベースで完了扱い', () {
      final task = _task(recurrence: TaskRecurrence.once);
      final entries = [_completionReport(taskId: task.id, timestamp: yesterday)];
      expect(needsTaskActionToday(task, entries), isFalse);
      expect(hasTaskCompletionRecord(task, entries), isTrue);
    });
  });

  group('daily', () {
    test('今日分の完了報告が無ければ要対応', () {
      final task = _task(recurrence: TaskRecurrence.daily);
      expect(needsTaskActionToday(task, []), isTrue);
      expect(hasTaskCompletionRecord(task, []), isFalse);
    });

    test('昨日分の完了報告だけでは今日はまだ要対応', () {
      final task = _task(recurrence: TaskRecurrence.daily);
      final entries = [_completionReport(taskId: task.id, timestamp: yesterday)];
      expect(needsTaskActionToday(task, entries), isTrue);
      expect(hasTaskCompletionRecord(task, entries), isFalse);
    });

    test('今日分の完了報告があれば要対応ではない', () {
      final task = _task(recurrence: TaskRecurrence.daily);
      final entries = [_completionReport(taskId: task.id, timestamp: today)];
      expect(needsTaskActionToday(task, entries), isFalse);
      expect(hasTaskCompletionRecord(task, entries), isTrue);
    });
  });

  group('weekly', () {
    test('今日が対象曜日、完了報告なし → 要対応、完了実績も無し', () {
      final task = _task(recurrence: TaskRecurrence.weekly, weekdays: [now.weekday]);
      expect(needsTaskActionToday(task, []), isTrue);
      expect(hasTaskCompletionRecord(task, []), isFalse);
    });

    test('今日が対象曜日、今日分の完了報告あり → 要対応ではない、完了実績あり', () {
      final task = _task(recurrence: TaskRecurrence.weekly, weekdays: [now.weekday]);
      final entries = [_completionReport(taskId: task.id, timestamp: today)];
      expect(needsTaskActionToday(task, entries), isFalse);
      expect(hasTaskCompletionRecord(task, entries), isTrue);
    });

    // 回帰テスト: 実際に発生したバグの再現ケース。
    // 今日が対象曜日に含まれない場合、完了報告が一度も無いのに
    // 「完了済み」と誤表示されていた(isTaskDoneForTodayがtrueを返していた)。
    test('今日が対象曜日でない、完了報告なし → 要対応ではないが、完了実績も無し', () {
      final task = _task(recurrence: TaskRecurrence.weekly, weekdays: [otherWeekday]);
      expect(needsTaskActionToday(task, []), isFalse,
          reason: '対象日でない日に「対応が必要」と出るのは望ましくない');
      expect(hasTaskCompletionRecord(task, []), isFalse,
          reason: '完了報告が無いのに「完了済み」と表示されるのが今回のバグだった');
    });
  });

  group('recurrenceLabel', () {
    test('once', () {
      expect(recurrenceLabel(_task(recurrence: TaskRecurrence.once)), '一度きり');
    });

    test('daily', () {
      expect(recurrenceLabel(_task(recurrence: TaskRecurrence.daily)), '毎日');
    });

    test('weekly: 火・金(選択順に関わらず曜日順に整列される)', () {
      // 金(5)→火(2)の順で選択しても、表示は曜日順(火・金)になることを確認する。
      final task = _task(recurrence: TaskRecurrence.weekly, weekdays: [5, 2]);
      expect(recurrenceLabel(task), '毎週(火・金)');
    });

    test('weekly: 単一曜日', () {
      final task = _task(recurrence: TaskRecurrence.weekly, weekdays: [1]);
      expect(recurrenceLabel(task), '毎週(月)');
    });

    test('dateRange', () {
      final task = _task(
        recurrence: TaskRecurrence.dateRange,
        startDate: DateTime(2026, 9, 22),
        endDate: DateTime(2026, 9, 30),
      );
      expect(recurrenceLabel(task), '期間指定(2026/09/22〜2026/09/30)');
    });
  });

  group('dateRange', () {
    test('今日が期間内、完了報告なし → 要対応', () {
      final task = _task(
        recurrence: TaskRecurrence.dateRange,
        startDate: today.subtract(const Duration(days: 1)),
        endDate: today.add(const Duration(days: 1)),
      );
      expect(needsTaskActionToday(task, []), isTrue);
      expect(hasTaskCompletionRecord(task, []), isFalse);
    });

    test('今日が期間外(既に終了)、完了報告なし → 要対応ではないが、完了実績も無し', () {
      final task = _task(
        recurrence: TaskRecurrence.dateRange,
        startDate: today.subtract(const Duration(days: 10)),
        endDate: today.subtract(const Duration(days: 2)),
      );
      expect(needsTaskActionToday(task, []), isFalse);
      expect(hasTaskCompletionRecord(task, []), isFalse);
    });
  });
}
