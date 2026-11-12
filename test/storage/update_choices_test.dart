import 'package:chess_auto_prep/storage/update_choices.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final checked = DateTime.utc(2026, 11, 2, 9, 30);
  final set = UpdateChoices(
    checkAutomatically: false,
    downloadAutomatically: false,
    lastChecked: checked,
    skipped: 'v2.0.5',
  );

  test('by default the app checks and downloads, and skips nothing', () {
    const choices = UpdateChoices.defaults;
    expect(choices.checkAutomatically, isTrue);
    expect(choices.downloadAutomatically, isTrue);
    expect(choices.lastChecked, isNull);
    expect(choices.skipped, isNull);
  });

  test('every choice survives a round trip, the time in UTC', () {
    expect(UpdateChoices.fromJson(set.toJson()), set);
    expect(UpdateChoices.fromJson(set.toJson()).hashCode, set.hashCode);
    final local = set.copyWith(lastChecked: checked.toLocal());
    expect(local.toJson()['lastChecked'], '2026-11-02T09:30:00.000Z');
  });

  test('nothing checked and nothing skipped are left out', () {
    expect(UpdateChoices.defaults.toJson(), {
      'checkAutomatically': true,
      'downloadAutomatically': true,
    });
  });

  test('anything unreadable reads as the default', () {
    expect(UpdateChoices.fromJson(null), UpdateChoices.defaults);
    expect(UpdateChoices.fromJson('choices'), UpdateChoices.defaults);
    expect(
      UpdateChoices.fromJson(const <String, Object?>{
        'checkAutomatically': 'no',
        'downloadAutomatically': 0,
        'lastChecked': 'yesterday',
        'skipped': 205,
      }),
      UpdateChoices.defaults,
    );
    expect(
      UpdateChoices.fromJson(const <String, Object?>{'lastChecked': 1}),
      UpdateChoices.defaults,
    );
  });

  test('choices are equal only when every one is', () {
    expect(set.copyWith(), set);
    final changed = {
      'checkAutomatically': set.copyWith(checkAutomatically: true),
      'downloadAutomatically': set.copyWith(downloadAutomatically: true),
      'lastChecked': set.copyWith(
        lastChecked: checked.add(const Duration(minutes: 1)),
      ),
      'skipped': set.copyWith(skipped: 'v2.0.6'),
    };
    for (final MapEntry(key: choice, value: other) in changed.entries) {
      expect(other == set, isFalse, reason: choice);
    }
  });
}
