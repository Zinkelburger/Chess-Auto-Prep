import 'package:chess_auto_prep/core/pgn/pgn_collection_helpers.dart';
import 'package:chess_auto_prep/core/slice_filter_controller.dart';
import 'package:chess_auto_prep/services/pgn_parsing_service.dart';
import 'package:flutter_test/flutter_test.dart';

const games = <GameRecord>[
  (headers: {'White': 'Alpha', 'Black': 'Beta'}, pgnText: '1. e4 e5 2. Nf3 *'),
  (headers: {'White': 'Beta', 'Black': 'Alpha'}, pgnText: '1. d4 d5 *'),
  (
    headers: {'White': 'Gamma', 'Black': 'Delta'},
    pgnText: '1. e4 c5 (1... e5) *',
  ),
];

void main() {
  for (final indexed in [false, true]) {
    test(
      'AND / OR positions, headers and sequence agree (index: $indexed)',
      () async {
        final index = indexed ? buildFenIndex(games) : null;
        Future<List<int>> run(SliceConfig config) =>
            applySliceConfig(config, games, fenIndex: index);
        expect(
          await run(
            const SliceConfig(
              positionInput: '1. e4',
              additionalPositions: ['1. e4 e5'],
            ),
          ),
          [0, 2],
        );
        expect(
          await run(
            const SliceConfig(
              positionInput: '1. e4',
              additionalPositions: ['1. d4'],
            ),
          ),
          isEmpty,
        );
        expect(
          await run(
            const SliceConfig(
              positionInput: '1. e4',
              additionalPositions: ['1. d4'],
              matchAny: true,
            ),
          ),
          [0, 1, 2],
        );
        expect(
          await run(
            const SliceConfig(
              positionInput: '1. c4',
              matchAny: true,
              headerFilters: [
                HeaderFilterConfig(
                  field: 'White',
                  mode: MatchMode.exact,
                  value: 'Beta',
                ),
              ],
            ),
          ),
          [1],
        );
        expect(
          await run(
            const SliceConfig(
              positionInput: '1. d4',
              matchAny: true,
              sequencePattern: 'Nf3',
            ),
          ),
          [0, 1],
        );
        expect(
          await run(
            const SliceConfig(positionInput: '1. e4', sequencePattern: 'Nf3'),
          ),
          [0],
        );
        expect(await run(const SliceConfig(matchAny: true)), [0, 1, 2]);
        expect(
          await run(
            const SliceConfig(
              matchAny: true,
              headerFilters: [
                HeaderFilterConfig(
                  field: 'White',
                  mode: MatchMode.exact,
                  value: 'Alpha',
                ),
                HeaderFilterConfig(
                  field: 'White',
                  mode: MatchMode.exact,
                  value: 'Beta',
                ),
              ],
            ),
          ),
          [0, 1],
        );
      },
    );
  }

  test(
    'positions and boolean logic round trip and reset with the controller',
    () {
      final controller = SliceFilterController();
      controller.positionText.text = '1. e4';
      controller.addPosition('1. d4');
      controller.setMatchAny(true);
      final saved = SliceConfig.fromJsonString(
        controller.buildConfig().toJsonString(),
      );
      final restored = SliceFilterController(initialConfig: saved);
      expect(restored.matchAny, isTrue);
      expect(restored.additionalPositionFens, [parseTargetFen('1. d4')]);
      restored.additionalPositions.single.text = 'bad position';
      expect(restored.hasInvalidPosition, isTrue);
      restored.removePosition(restored.additionalPositions.single);
      expect(restored.hasInvalidPosition, isFalse);
      restored.reset();
      expect(restored.matchAny, isFalse);
      expect(restored.additionalPositions, isEmpty);
      expect(restored.buildConfig().isEmpty, isTrue);
      expect(
        SliceConfig.fromJsonString('{"positionInput":"1. e4"}').matchAny,
        isFalse,
      );
      restored.dispose();
      controller.dispose();
    },
  );
}
