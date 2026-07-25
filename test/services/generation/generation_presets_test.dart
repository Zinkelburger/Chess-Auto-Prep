import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/generation_presets.dart';

void main() {
  group('GenerationPresetStore', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('save, load, delete round-trip without start_fen', () async {
      final store = GenerationPresetStore();
      const config = TreeBuildConfig(
        startFen: 'some fen',
        playAsWhite: false,
        maxPly: 24,
        maiaElo: 1800,
      );

      await store.save('Anti-London', config);
      var loaded = await store.load();
      expect(loaded.keys, ['Anti-London']);
      expect(loaded['Anti-London']!.containsKey('start_fen'), isFalse);

      final restored = TreeBuildConfig.fromJson(
        loaded['Anti-London']!,
        startFen: 'other fen',
      );
      expect(restored.maxPly, 24);
      expect(restored.maiaElo, 1800);
      expect(restored.playAsWhite, isFalse);
      expect(restored.startFen, 'other fen');

      await store.delete('Anti-London');
      loaded = await store.load();
      expect(loaded, isEmpty);
    });

    test('corrupt stored JSON degrades to empty, not a crash', () async {
      SharedPreferences.setMockInitialValues({
        GenerationPresetStore.prefsKey: 'not json{',
      });
      expect(await GenerationPresetStore().load(), isEmpty);
    });
  });
}
