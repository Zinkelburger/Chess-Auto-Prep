import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/core/app_state.dart';

/// A build without the bughouse engine must not offer Bughouse Lab at all.
///
/// The engine is downloaded into `assets/bughouse/` at release time rather
/// than tracked in git, and `flutter build` treats a missing asset directory
/// as a printed warning rather than an error — so "compiled in, no engine
/// behind it" is an ordinary build, and every developer checkout is one until
/// `tools/fetch_bughouse.py` has run.
void main() {
  tearDown(unavailableModes.clear);

  test('by default every mode is offered', () {
    expect(AppMode.bughouse.isAvailable, isTrue);
    expect(availableModeMenuOrder(), kAppModeMenuOrder);
    expect(
      availableAppModeGroups().map((g) => g.heading),
      kAppModeGroups.map((g) => g.heading),
    );
  });

  test('an unavailable mode leaves the menu and the chord list', () {
    unavailableModes.add(AppMode.bughouse);

    expect(AppMode.bughouse.isAvailable, isFalse);
    expect(availableModeMenuOrder(), isNot(contains(AppMode.bughouse)));

    final lab = availableAppModeGroups().firstWhere((g) => g.heading == 'Lab');
    expect(lab.modes, [AppMode.engineTournament]);
  });

  test('the other modes keep the chord the menu taught them', () {
    final before = {
      for (final mode in kAppModeMenuOrder) mode: mode.shortcutNumber,
    };
    unavailableModes.add(AppMode.bughouse);

    for (final mode in availableModeMenuOrder()) {
      expect(
        mode.shortcutNumber,
        before[mode],
        reason: 'hiding an optional mode must not renumber ${mode.label}',
      );
    }
  });

  test('a group whose every mode is gone disappears with them', () {
    unavailableModes.addAll([AppMode.engineTournament, AppMode.bughouse]);
    expect(
      availableAppModeGroups().map((g) => g.heading),
      isNot(contains('Lab')),
    );
  });
}
