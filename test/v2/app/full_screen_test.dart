import 'package:chess_auto_prep/v2/app/full_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('asks the desktop in order and leaves only what it entered', () async {
    final asked = <bool>[];
    final screen = FullScreen((on) async => asked.add(on));
    expect(screen.leave(), isFalse, reason: 'not in full screen');
    screen.toggle();
    screen.toggle();
    screen.toggle();
    expect(screen.on, isTrue);
    expect(screen.leave(), isTrue);
    await pumpEventQueue();
    expect(asked, [true, false, true, false]);
  });

  test('a desktop that refuses does not stop the next request', () async {
    final asked = <bool>[];
    var refuse = true;
    final screen = FullScreen((on) async {
      if (refuse) {
        refuse = false;
        throw StateError('no window');
      }
      asked.add(on);
    });
    screen.toggle();
    screen.leave();
    await pumpEventQueue();
    expect(asked, [false]);
  });
}
