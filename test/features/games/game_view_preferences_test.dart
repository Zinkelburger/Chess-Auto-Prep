import 'package:chess_auto_prep/features/games/models/game_view_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('simple defaults and explicit display choices survive reload', () async {
    final initial = await GameViewPreferences.load();
    expect(initial.playback, isFalse);
    expect(initial.engine, isFalse);
    expect(initial.graph, isFalse);
    await initial
        .copyWith(
          playback: true,
          engine: true,
          graph: false,
          speed: 3,
          autoNext: true,
        )
        .save();
    final restored = await GameViewPreferences.load();
    expect(restored.playback, isTrue);
    expect(restored.engine, isTrue);
    expect(restored.graph, isFalse);
    expect(restored.speed, 3);
    expect(restored.autoNext, isTrue);
    await const GameViewPreferences().save();
    expect((await GameViewPreferences.load()).playback, isFalse);
  });

  test('invalid saved speed falls back to a usable value', () async {
    SharedPreferences.setMockInitialValues({'game_view.speed': -1.0});
    expect((await GameViewPreferences.load()).speed, 1);
  });
}
