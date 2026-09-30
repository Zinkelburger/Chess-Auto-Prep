import 'package:chess_auto_prep/ui/app_keys.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('keys are named the way a tooltip writes them', () {
    expect(AppKey.edit.label, 'Ctrl+E');
    expect(AppKey.pastePosition.label, 'Ctrl+Shift+V');
    expect(AppKey.settings.label, 'Ctrl+,');
    expect(AppKey.back.label, '←');
    expect(AppKey.historyBack.label, 'Alt+←');
    expect(AppKey.leave.label, 'Esc');
    expect(AppKey.typeMove.label, '/');
    expect(AppKey.flip.tip('Flip board'), 'Flip board (F)');
  });

  test('the Shortcuts list names every key but not the macOS twins', () {
    expect(AppKey.start.allLabels, 'Home / PgUp');
    expect(AppKey.edit.allLabels, 'Ctrl+E');
    expect(AppKey.enterVariation.allLabels, 'Enter');
    expect(AppKey.rate.allLabels, '1–4');
  });

  test('no key does two things in one place', () {
    for (final place in KeyPlace.values) {
      final seen = <String, AppKey>{};
      for (final key in AppKey.values.where((k) => k.place == place)) {
        for (final activator in key.keys) {
          final name = keyName(activator);
          expect(
            seen[name] ?? key,
            key,
            reason: '$name is both ${seen[name]} and $key in ${place.label}',
          );
          seen[name] = key;
        }
      }
    }
  });

  test('every action has its own name, so a Shortcuts row is findable', () {
    final names = AppKey.values.map((k) => k.action).toList();
    expect(names.toSet().length, names.length);
  });

  test('a key accepts its own press and no other', () {
    const down = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyF,
      logicalKey: LogicalKeyboardKey.keyF,
      timeStamp: Duration.zero,
    );
    expect(AppKey.flip.accepts(down), isTrue);
    expect(AppKey.engine.accepts(down), isFalse);
  });
}
