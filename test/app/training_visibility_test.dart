// A Train tab sitting stays beside its controls: it pauses when its tab is
// closed or another mode comes up, and once resumed somewhere else it
// belongs to the mode it was resumed in.
import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/app/training_visibility.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WindowFixture w;
  late bool tabOpen;
  late SittingInView sitting;

  setUp(() async {
    w = WindowFixture();
    tabOpen = true;
    await w.requests.open(kidMain);
    w.requests.switchTo(Mode.trainer);
    await w.lineTrainer.reload();
    sitting = SittingInView(
      trainer: w.lineTrainer,
      requests: w.requests,
      trainTabOpen: () => tabOpen,
    );
    w.lineTrainer.learn();
    await pumpEventQueue();
  });
  tearDown(() {
    sitting.dispose();
    w.dispose();
  });

  bool suspended() => w.lineTrainer.lesson!.suspended;

  test('goes on where it started, with its tab open', () {
    expect(w.lineTrainer.lesson, isNotNull);
    sitting.check();
    expect(suspended(), isFalse);
  });

  test('pauses when its tab is closed', () {
    tabOpen = false;
    sitting.check();
    expect(suspended(), isTrue);
  });

  test('pauses when another mode comes up', () async {
    w.requests.switchTo(Mode.repertoires);
    await pumpEventQueue();
    expect(suspended(), isTrue);
  });

  test('resumed in another mode, it stays there', () async {
    w.requests.switchTo(Mode.repertoires);
    await pumpEventQueue();
    w.lineTrainer.resume();
    await pumpEventQueue();
    expect(suspended(), isFalse);
    sitting.check();
    expect(suspended(), isFalse);
    w.requests.switchTo(Mode.trainer);
    await pumpEventQueue();
    expect(suspended(), isTrue, reason: 'it belongs to the builder now');
  });
}
