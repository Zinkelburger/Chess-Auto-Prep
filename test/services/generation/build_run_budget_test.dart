import 'package:chess_auto_prep/services/generation/build_run.dart';
import 'package:flutter_test/flutter_test.dart';

/// The thresholds that decide when a build stops working.
///
/// Pinned here because getting them wrong is invisible in a unit run and
/// expensive overnight: a Benko build with a 300-minute budget stopped its
/// search on time and then swept for 152 minutes more, because the coverage
/// sweep consulted neither of these.
void main() {
  group('BuildRun.budgetSpent', () {
    test('no budget is never spent', () {
      expect(BuildRun.budgetSpent(const Duration(hours: 10), 0), isFalse);
      expect(BuildRun.budgetSpent(const Duration(hours: 10), -1), isFalse);
      expect(
        BuildRun.budgetSpent(const Duration(hours: 10), 0, grace: 0.2),
        isFalse,
      );
    });

    test('spends exactly at the budget, not before', () {
      expect(BuildRun.budgetSpent(const Duration(minutes: 299), 300), isFalse);
      expect(BuildRun.budgetSpent(const Duration(minutes: 300), 300), isTrue);
      expect(BuildRun.budgetSpent(const Duration(minutes: 301), 300), isTrue);
    });

    test('grace extends the budget by its own share', () {
      // 300 minutes + 20% = 360.
      bool swept(int minutes) => BuildRun.budgetSpent(
        Duration(minutes: minutes),
        300,
        grace: BuildRun.coverageSweepGrace,
      );

      expect(swept(300), isFalse, reason: 'the sweep still has its grace');
      expect(swept(359), isFalse);
      expect(swept(360), isTrue);
      // The run that prompted this swept to 452 minutes.
      expect(swept(452), isTrue);
    });

    test('the sweep grace is bounded, so an overrun cannot be open-ended', () {
      expect(BuildRun.coverageSweepGrace, greaterThan(0));
      expect(BuildRun.coverageSweepGrace, lessThanOrEqualTo(0.5));
    });
  });
}
