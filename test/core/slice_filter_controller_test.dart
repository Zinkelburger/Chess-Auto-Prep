import 'package:chess_auto_prep/core/slice_filter_controller.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('starts empty with one default Date/after header row', () {
    final c = SliceFilterController();
    expect(c.positionFen, isNull);
    expect(c.hasSequenceFilter, isFalse);
    expect(c.headerRows, hasLength(1));
    expect(c.headerRows.first.field, 'Date');
    expect(c.headerRows.first.mode, MatchMode.after);
    expect(c.rawHeaderFilters, isEmpty, reason: 'empty value rows excluded');
    c.dispose();
  });

  test('pre-populates from an initial config', () {
    final c = SliceFilterController(
      initialConfig: const SliceConfig(
        positionInput: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -',
        headerFilters: [
          HeaderFilterConfig(
              field: 'White', mode: MatchMode.contains, value: 'Carlsen'),
        ],
        sequencePattern: 'e4 e5',
        sequenceGap: 2,
      ),
    );

    expect(c.positionFen, isNotNull);
    expect(c.sequenceText.text, 'e4 e5');
    expect(c.sequenceGap, 2);
    expect(c.headerRows, hasLength(1));
    expect(c.headerRows.first.value, 'Carlsen');
    c.dispose();
  });

  test('typed position input live-parses SAN sequence into a FEN', () {
    final c = SliceFilterController();
    c.positionText.text = '1. e4 c6';
    expect(c.positionFen, isNotNull);
    expect(c.positionParse.error, isNull);
    expect(c.hasPositionFilter, isTrue);

    c.clearPosition();
    expect(c.positionFen, isNull);
    expect(c.positionText.text, isEmpty);
    c.dispose();
  });

  test('live parse reports errors for invalid input', () {
    final c = SliceFilterController();
    c.positionText.text = '1. e4 zz9';
    expect(c.positionFen, isNull);
    expect(c.positionParse.error, isNotNull);
    c.dispose();
  });

  test('setPositionFen activates the filter directly', () {
    final c = SliceFilterController();
    c.setPositionFen('rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -');
    expect(c.hasPositionFilter, isTrue);
    // Re-capture with a different position replaces, never toggles off.
    c.setPositionFen(
        'rnbqkbnr/pp1ppppp/2p5/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq -');
    expect(c.hasPositionFilter, isTrue);
    expect(c.positionFen, contains('2p5'));
    c.dispose();
  });

  test('validateSequence flags invalid tokens', () {
    final c = SliceFilterController();
    c.sequenceText.text = 'e4 e5 [gap] f?!6';
    c.validateSequence();
    expect(c.sequenceError, isNotNull);

    c.sequenceText.text = 'e4 e5 [gap] f6';
    c.validateSequence();
    expect(c.sequenceError, isNull);
    expect(c.sequenceGroups, [
      ['e4', 'e5'],
      ['f6'],
    ]);
    c.dispose();
  });

  test('header row edits and buildConfig round-trip', () {
    final c = SliceFilterController();
    c.setHeaderField(0, 'White');
    c.setHeaderValue(0, 'Kasparov');
    c.addHeaderRow();
    c.setHeaderValue(1, 'Sicilian');
    c.sequenceText.text = 'd5 e5 [gap] f6';
    c.gapText.text = '3';

    final config = c.buildConfig();
    expect(config.headerFilters, hasLength(2));
    expect(config.headerFilters.first.field, 'White');
    expect(config.headerFilters.first.value, 'Kasparov');
    expect(config.sequencePattern, 'd5 e5 [gap] f6');
    expect(config.sequenceGap, 3);

    // Round-trip: a controller seeded from this config matches it.
    final c2 = SliceFilterController(initialConfig: config);
    expect(c2.buildConfig().toJsonString(), config.toJsonString());
    c.dispose();
    c2.dispose();
  });

  test('setHeaderField normalizes the match mode for numeric fields', () {
    final c = SliceFilterController();
    c.addHeaderRow(); // defaults: Black / contains
    c.setHeaderField(1, 'WhiteElo');
    expect(c.headerRows[1].mode, MatchMode.after,
        reason: 'contains is meaningless for Elo; switches to ≥');
    c.dispose();
  });

  test('removeHeaderRow deletes the row', () {
    final c = SliceFilterController();
    c.addHeaderRow();
    expect(c.headerRows, hasLength(2));
    c.removeHeaderRow(0);
    expect(c.headerRows, hasLength(1));
    c.dispose();
  });

  test('reset restores defaults and notifies', () {
    final c = SliceFilterController(
      initialConfig: const SliceConfig(sequencePattern: 'e4', sequenceGap: 9),
    );
    var notified = 0;
    c.addListener(() => notified++);
    c.positionText.text = '1. d4';

    c.reset();
    expect(c.positionFen, isNull);
    expect(c.sequenceText.text, isEmpty);
    expect(c.sequenceGap, 4);
    expect(c.headerRows, hasLength(1));
    expect(c.headerRows.first.field, 'Date');
    expect(notified, greaterThanOrEqualTo(2));
    c.dispose();
  });
}
