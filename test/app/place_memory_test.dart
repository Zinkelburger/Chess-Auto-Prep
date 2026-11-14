// Where the window is, kept in the settings for the next launch: written
// when the place changes, not on every move, and no more once taken down.
import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/app/place_memory.dart';
import 'package:chess_auto_prep/storage/saved_place.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/window_fixture.dart';

void main() {
  late WindowFixture w;
  late SettingsStore settings;
  late PlaceMemory memory;
  late int writes;
  setUp(() {
    w = WindowFixture();
    settings = SettingsStore();
    writes = 0;
    settings.addListener(() => writes++);
    memory = PlaceMemory(
      settings: settings,
      requests: w.requests,
      session: w.session,
    );
  });
  tearDown(() {
    memory.dispose();
    settings.dispose();
    w.dispose();
  });

  SavedPlace? kept() => settings.value.lastPlace;

  test('nothing is kept before it starts', () async {
    await w.requests.open(kidMain);
    await pumpEventQueue();
    expect(kept(), isNull);
  });

  test('a new file or mode is kept', () async {
    memory.start();
    await w.requests.open(kidMain);
    await pumpEventQueue();
    expect(kept()?.path, kidMain.path);
    w.requests.switchTo(Mode.databases);
    await pumpEventQueue();
    expect(kept()?.mode, Mode.databases.name);
  });

  test('moves within the game write nothing', () async {
    memory.start();
    await w.requests.open(kidMain);
    await pumpEventQueue();
    final before = writes;
    w.session.cursor.forward();
    w.session.cursor.forward();
    await pumpEventQueue();
    expect(writes, before);
  });

  test('started twice, it writes a change once', () async {
    memory
      ..start()
      ..start();
    await w.requests.open(kidMain);
    await pumpEventQueue();
    expect(writes, 1);
  });

  test('taken down, it keeps nothing more', () async {
    memory.start();
    await w.requests.open(kidMain);
    await pumpEventQueue();
    memory.dispose();
    await w.requests.open(benkoMain);
    await pumpEventQueue();
    expect(kept()?.path, kidMain.path);
  });
}
