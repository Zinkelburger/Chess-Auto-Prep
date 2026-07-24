import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/generation_presets.dart';

void main() {
  group('EffortPreset.detect', () {
    test('recognizes each named preset exactly', () {
      for (final preset in EffortPreset.all) {
        expect(
          EffortPreset.detect(
            maxPly: preset.maxPly,
            evalDepth: preset.evalDepth,
            ourMultipv: preset.ourMultipv,
            verifyFinal: preset.verifyFinal,
            wideOpening: preset.wideOpening,
          ),
          same(preset),
        );
      }
    });

    test('any customized knob yields null (Custom)', () {
      final s = EffortPreset.standard;
      expect(
        EffortPreset.detect(
          maxPly: s.maxPly + 1,
          evalDepth: s.evalDepth,
          ourMultipv: s.ourMultipv,
          verifyFinal: s.verifyFinal,
          wideOpening: s.wideOpening,
        ),
        isNull,
      );
      expect(
        EffortPreset.detect(
          maxPly: s.maxPly,
          evalDepth: s.evalDepth,
          ourMultipv: s.ourMultipv,
          verifyFinal: !s.verifyFinal,
          wideOpening: s.wideOpening,
        ),
        isNull,
      );
    });
  });

  group('detectStyle', () {
    test('round-trips every card style', () {
      for (final style in RepertoireStyle.values) {
        final setup = style == RepertoireStyle.system ? 'Be3 Qd2 f3' : '';
        expect(
          detectStyle(selectionMode: style.selectionMode, setupMoves: setup),
          style,
        );
      }
    });

    test('inexpressible combinations are Custom (null)', () {
      expect(
        detectStyle(selectionMode: SelectionMode.playable, setupMoves: ''),
        isNull,
      );
      expect(
        detectStyle(selectionMode: SelectionMode.dbWinRateOnly, setupMoves: ''),
        isNull,
      );
      // Setup moves outside expectimax cannot be shown as "My system".
      expect(
        detectStyle(selectionMode: SelectionMode.trappy, setupMoves: 'h4'),
        isNull,
      );
    });
  });

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
