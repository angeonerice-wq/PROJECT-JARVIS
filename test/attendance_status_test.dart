// SV手動勤怠ステータス変更機能の「新しい方を優先」解決ロジックの単体テスト。
// スタッフの自己申告とSVによる手動変更が同じ日に混在した場合、常に
// timestampが新しい方が勝つ必要がある(taskの繰り返し判定バグと同様、
// この種のロジックは単体テストで担保する)。

import 'package:flutter_test/flutter_test.dart';
import 'package:project_jarvis/main.dart';

HistoryEntry _attendanceEntry({
  required String staffId,
  required String category,
  required DateTime timestamp,
  bool isManualBySv = false,
}) {
  return HistoryEntry(
    staffId: staffId,
    category: category,
    title: category,
    timestamp: timestamp,
    action: SuggestedAction.approveOnly,
    fields: const [],
    history: const [],
    isManualBySv: isManualBySv,
  );
}

void main() {
  final now = DateTime.now();
  final earlier = DateTime(now.year, now.month, now.day, 8);
  final later = DateTime(now.year, now.month, now.day, 14);

  group('resolveLatestAttendanceByStaffId', () {
    test('対象スタッフのエントリが無ければ結果に含まれない', () {
      final result = resolveLatestAttendanceByStaffId([]);
      expect(result, isEmpty);
    });

    test('1件だけなら、それがそのまま採用される', () {
      final entry = _attendanceEntry(
          staffId: 's1', category: '勤怠(欠勤)', timestamp: earlier);
      final result = resolveLatestAttendanceByStaffId([entry]);
      expect(result['s1'], same(entry));
    });

    test('同じスタッフに複数件あれば、timestampが新しい方が勝つ(配列順に関わらず)', () {
      final oldEntry = _attendanceEntry(
          staffId: 's1', category: '勤怠(欠勤)', timestamp: earlier);
      final newEntry = _attendanceEntry(
          staffId: 's1', category: '勤怠(出勤)', timestamp: later);
      // 新しい方が先頭に来る順(SvReportStoreの実際の並び順)でも結果は変わらない。
      final result = resolveLatestAttendanceByStaffId([newEntry, oldEntry]);
      expect(result['s1'], same(newEntry));
    });

    test('自己申告(遅刻)より後にSVの手動変更(出勤)があれば、手動変更が勝つ', () {
      final selfReport = _attendanceEntry(
          staffId: 's1', category: '勤怠(遅刻)', timestamp: earlier);
      final manualOverride = _attendanceEntry(
        staffId: 's1',
        category: '勤怠(出勤)',
        timestamp: later,
        isManualBySv: true,
      );
      final result =
          resolveLatestAttendanceByStaffId([manualOverride, selfReport]);
      expect(result['s1']!.category, '勤怠(出勤)');
      expect(result['s1']!.isManualBySv, isTrue);
    });

    test('勤怠以外のcategoryは無視される', () {
      final unrelated = _attendanceEntry(
          staffId: 's1', category: 'タスク完了', timestamp: later);
      final result = resolveLatestAttendanceByStaffId([unrelated]);
      expect(result, isEmpty);
    });

    test('複数スタッフはそれぞれ独立して解決される', () {
      final e1 = _attendanceEntry(
          staffId: 's1', category: '勤怠(欠勤)', timestamp: earlier);
      final e2 = _attendanceEntry(
          staffId: 's2', category: '勤怠(有給)', timestamp: earlier);
      final result = resolveLatestAttendanceByStaffId([e1, e2]);
      expect(result['s1']!.category, '勤怠(欠勤)');
      expect(result['s2']!.category, '勤怠(有給)');
    });
  });
}
