import 'package:chess_auto_prep/v2/app/full_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('asks the desktop in order and leaves only what it entered', () async {
    final asked = <bool>[];
    final screen = FullScreen((on) async => asked.add(on), say: (_) {});
    expect(screen.leave(), isFalse, reason: 'not in full screen');
    screen.toggle();
    screen.toggle();
    screen.toggle();
    expect(screen.on, isTrue);
    expect(screen.leave(), isTrue);
    await pumpEventQueue();
    expect(asked, [true, false, true, false]);
  });

  test('a desktop that refuses is said, and the window is as it was', () async {
    final said = <String>[];
    final screen = FullScreen(
      (on) async => throw StateError('no window'),
      say: said.add,
    );
    screen.toggle();
    await pumpEventQueue();
    expect(screen.on, isFalse);
    expect(said.single, startsWith('Could not fill the screen'));
    expect(screen.leave(), isFalse, reason: 'Esc goes on to others');
  });
}
