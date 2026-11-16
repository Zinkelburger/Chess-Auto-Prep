// The workspace's wiring: the engine starts again only for a change to
// which engine it is, its threads or its table, not for more lines.
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_engine.dart';
import '../support/window_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the engine starts again for new threads, not for more lines', () async {
    var launches = 0;
    final w = WindowFixture(
      launchEngine: ({required cores, required memoryMb}) async {
        launches++;
        return Started(ScriptedEngine());
      },
    );
    addTearDown(w.dispose);
    await w.parts.start();
    await w.analysis.enable();
    await pumpEventQueue();
    expect(w.analysis.enabled, isTrue);
    final before = launches;
    expect(before, greaterThan(0));
    final settings = w.settings;
    await settings.update(
      settings.value.copyWith(engineLines: settings.value.engineLines + 1),
    );
    await pumpEventQueue();
    expect(launches, before, reason: 'more lines start nothing');
    await settings.update(
      settings.value.copyWith(engineCores: settings.value.engineCores + 1),
    );
    await pumpEventQueue();
    expect(launches, greaterThan(before));
  });
}
