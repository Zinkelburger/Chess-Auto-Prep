import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MatchMode.fromName', () {
    test('finds a mode by its persisted name', () {
      expect(MatchMode.fromName('notContains'), MatchMode.notContains);
      expect(MatchMode.fromName('before'), MatchMode.before);
    });

    test('falls back to contains for an unknown name', () {
      expect(MatchMode.fromName('fuzzy'), MatchMode.contains);
    });
  });

  group('SliceConfig', () {
    test('round-trips through its JSON string', () {
      const config = SliceConfig(
        positionInput: '1. e4',
        additionalPositions: ['1. d4'],
        matchAny: true,
        headerFilters: [
          HeaderFilterConfig(field: 'White', mode: MatchMode.exact, value: 'X'),
        ],
        sequencePattern: 'Nf3 Nc6',
        sequenceGap: 2,
      );
      final back = SliceConfig.fromJsonString(config.toJsonString());
      expect(back.positionInput, '1. e4');
      expect(back.additionalPositions, ['1. d4']);
      expect(back.matchAny, isTrue);
      expect(back.headerFilters.single.mode, MatchMode.exact);
      expect(back.sequencePattern, 'Nf3 Nc6');
      expect(back.sequenceGap, 2);
      expect(back.isEmpty, isFalse);
    });

    test('unreadable JSON is an empty slice', () {
      expect(SliceConfig.fromJsonString('not json').isEmpty, isTrue);
      expect(SliceConfig.fromJsonString('[1, 2]').isEmpty, isTrue);
      expect(
        SliceConfig.fromJsonString('{"sequenceGap": "x"}').isEmpty,
        isTrue,
      );
    });

    test('blank inputs count as empty', () {
      const config = SliceConfig(
        positionInput: '  ',
        additionalPositions: [''],
        headerFilters: [
          HeaderFilterConfig(
            field: 'White',
            mode: MatchMode.contains,
            value: '',
          ),
        ],
      );
      expect(config.isEmpty, isTrue);
      expect(const SliceConfig().chipLabels, isEmpty);
    });
  });
}
