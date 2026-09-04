import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:chess_auto_prep/services/generation/line_pruner.dart';
import 'package:flutter_test/flutter_test.dart';

/// A line whose decisions are derived from its move order: one unit per odd
/// ply, keyed by the prefix that reaches it.
///
/// That is the relationship the extractor's position-keyed units have — two
/// lines sharing a move-order prefix share the decisions along it — without
/// needing a board. Deeper units are worth less, as reach probability makes
/// them in a real tree, so a test that passes here would also pass on values
/// the extractor produced.
ExtractedLine _line(List<String> movesSan, {double probability = 0.1}) =>
    ExtractedLine(
      movesSan: movesSan,
      movesUci: movesSan,
      probability: probability,
      coverageUnits: [
        for (var i = 1; i < movesSan.length; i += 2)
          LineCoverageUnit(
            key: movesSan.sublist(0, i + 1).join(' '),
            value: 1.0 / (i + 1),
          ),
      ],
    );

/// A line with decisions of its own, unrelated to its move order — the shape
/// a transposition produces, and the only way to write a test where "shares
/// most decisions" and "shares a move prefix" disagree.
ExtractedLine _lineWithUnits(
  List<String> movesSan,
  List<String> unitKeys, {
  double probability = 0.1,
}) => ExtractedLine(
  movesSan: movesSan,
  movesUci: movesSan,
  probability: probability,
  coverageUnits: [
    for (var i = 0; i < unitKeys.length; i++)
      LineCoverageUnit(key: unitKeys[i], value: 1.0 / (i + 1)),
  ],
);

const _shared = [
  'd4',
  'Nf6',
  'c4',
  'e6',
  'Nc3',
  'Bb4',
  'e3',
  'O-O',
  'Bd3',
  'd5',
  'Nf3',
  'c5',
  'O-O',
  'dxc4',
  'Bxc4',
];

/// A second fifteen-ply trunk sharing nothing with [_shared], so its twins
/// form a family of their own.
const _sicilian = [
  'e4',
  'c5',
  'Nf3',
  'd6',
  'd4',
  'cxd4',
  'Nxd4',
  'Nf6',
  'Nc3',
  'a6',
  'Be3',
  'e5',
  'Nb3',
  'Be6',
  'f3',
];

/// Lines agreeing for fifteen plies and parting only on the sixteenth: seven
/// of eight decisions shared, which is the shape that made a real build 90%
/// tail-only variants.
List<ExtractedLine> _tailTwins([int count = 6]) => [
  for (final tail in ['a', 'b', 'c', 'd', 'e', 'f'].take(count))
    _line([..._shared, tail]),
];

String _key(ExtractedLine l) => l.movesSan.join(' ');

void main() {
  group('LineDiversity', () {
    test('off keeps every tail-only twin, as it always did', () {
      final slice = LinePruner.rank(_tailTwins(), diversity: LineDiversity.off);
      expect(slice.all.length, 6);
      expect(slice.foldedCount, 0);
      expect(slice.droppedCount, 0);
    });

    test('the overlap cap keeps one twin and folds the rest into it', () {
      final slice = LinePruner.rank(
        _tailTwins(),
        diversity: const LineDiversity(maxOverlap: 0.7),
      );

      expect(
        slice.all.length,
        1,
        reason: 'all six teach the same seven decisions bar one',
      );
      expect(slice.foldedCount, 5);
      expect(slice.droppedCount, 0, reason: 'each has a host to hang off');

      final folds = slice.foldsFor(slice.length);
      expect(folds.keys.single, _key(slice.all.single));
      // They part at the last ply, so each sideline is a single move.
      expect(folds.values.single.map((f) => f.divergePly), everyElement(15));
      expect(
        folds.values.single.map((f) => f.line.movesSan.last).toSet(),
        {'a', 'b', 'c', 'd', 'e', 'f'}..remove(slice.all.single.movesSan.last),
      );
    });

    test('the same twins fail the new-share floor too', () {
      // One new decision in eight is 12.5%, under a quarter.
      final slice = LinePruner.rank(
        _tailTwins(),
        diversity: const LineDiversity(minNewShare: 0.25),
      );
      expect(slice.all.length, 1);
      expect(slice.foldedCount, 5);
    });

    test('one sideline, not one per sibling that teaches the same thing', () {
      // The bug this pins: rejecting a line does not mark its decisions
      // covered, so each sibling teaching exactly the same thing kept winning
      // a round with the same uncovered decision and each was folded — the
      // real Benko export wrote `11. Qc2 Nxa6` seven times, once per unplayed
      // White 12th move. With diversity off those siblings are never picked
      // at all, so folding them was strictly worse than the old behaviour.
      final siblings = [
        // A trailing opponent move adds no decision of ours, so these teach
        // exactly what the 'b' twin teaches.
        _line([..._shared, 'b', 'a3']),
        _line([..._shared, 'b', 'Be2']),
        _line([..._shared, 'b', 'Bc4']),
      ];
      final lines = [..._tailTwins(), ...siblings];

      final off = LinePruner.rank(lines, diversity: LineDiversity.off);
      expect(
        off.all.length,
        6,
        reason: 'without a bar the siblings never enter the ranking',
      );

      final slice = LinePruner.rank(
        lines,
        diversity: const LineDiversity(maxOverlap: 0.7),
      );
      expect(slice.all.length, 1);
      expect(
        slice.foldedCount,
        5,
        reason: 'the five other twins, and none of the three siblings',
      );
      final folded = slice
          .foldsFor(slice.length)
          .values
          .single
          .map((f) => f.line.movesSan.length);
      expect(
        folded,
        everyElement(_shared.length + 1),
        reason: 'a 17-ply sibling would be one of the repeats',
      );
    });

    test('a line that diverges early is kept, not folded', () {
      // Two genuinely different systems: they share one decision, so neither
      // is a near-copy of the other however long they both run.
      final lines = [
        _line([..._shared, 'Nbd7']),
        _line([
          'd4',
          'Nf6',
          'c4',
          'g6',
          'Nc3',
          'd5',
          'cxd5',
          'Nxd5',
          'e4',
          'Nxc3',
          'bxc3',
          'Bg7',
          'Nf3',
          'c5',
          'Rb1',
          'O-O',
        ]),
      ];
      final slice = LinePruner.rank(lines, diversity: LineDiversity.standard);
      expect(slice.all.length, 2);
      expect(slice.foldedCount, 0);
    });

    test('minNewShare counts decisions, not their reach value', () {
      // The shared opening decision is worth eight times the deepest one, so
      // a value-weighted floor would reject the second line for repeating it
      // alone. Counted, six of its eight decisions are new.
      final lines = [
        _line([..._shared, 'Nbd7']),
        _line([
          'd4',
          'Nf6',
          'c4',
          'e6',
          'Nc3',
          'Bb4',
          'Qc2',
          'O-O',
          'a3',
          'Bxc3+',
          'Qxc3',
          'b6',
          'Bg5',
          'Bb7',
          'f3',
          'h6',
        ]),
      ];
      final slice = LinePruner.rank(
        lines,
        diversity: const LineDiversity(minNewShare: 0.5),
      );
      expect(slice.all.length, 2);
    });

    test('a fold too long to be a note is dropped instead', () {
      // Same decisions bar one, reached by a move order that parts at ply 2:
      // writing it as a sideline would bury a whole second line inside the
      // first, so it goes rather than being buried.
      final keys = [for (var i = 0; i < 8; i++) 'u$i'];
      final lines = [
        _lineWithUnits([..._shared, 'Nbd7'], keys, probability: 0.5),
        _lineWithUnits(
          [
            'd4',
            'Nf6',
            'e3',
            'e6',
            'Nf3',
            'b6',
            'Bd3',
            'Bb7',
            'O-O',
            'd5',
            'c4',
            'Bd6',
            'Nc3',
            'O-O',
            'b3',
            'Nbd7',
          ],
          [...keys.take(7), 'u9'],
        ),
      ];
      final slice = LinePruner.rank(
        lines,
        diversity: const LineDiversity(maxOverlap: 0.7),
      );
      expect(slice.all.length, 1);
      expect(slice.foldedCount, 0);
      expect(slice.droppedCount, 1);
    });

    test('a fold is not rendered when the cut drops its host', () {
      // Two twin pairs that share nothing with each other. A cut of one line
      // keeps the first host, so only its fold has a mainline to hang off.
      final lines = [
        _line([..._shared, 'a'], probability: 0.4),
        _line([..._shared, 'b'], probability: 0.3),
        _line([..._sicilian, 'a'], probability: 0.2),
        _line([..._sicilian, 'b'], probability: 0.1),
      ];
      final slice = LinePruner.rank(
        lines,
        diversity: const LineDiversity(maxOverlap: 0.7),
      );
      expect(slice.all.length, 2);
      expect(slice.foldedCount, 2);
      expect(slice.foldsFor(2).length, 2);
      expect(
        slice.foldsFor(1).length,
        1,
        reason: 'the second host is not in a one-line cut',
      );
    });

    test('coverage splits into what is drilled and what is answered', () {
      final slice = LinePruner.rank(
        _tailTwins(),
        diversity: const LineDiversity(maxOverlap: 0.7),
      );
      // One mainline carrying six lines' worth of reach: the other five are
      // in the file as sidelines, so they are answered but never quizzed.
      expect(slice.coverageAt(slice.length), closeTo(1 / 6, 0.001));
      expect(slice.answeredCoverageAt(slice.length), closeTo(1.0, 0.001));

      final off = LinePruner.rank(_tailTwins(), diversity: LineDiversity.off);
      expect(
        off.answeredCoverageAt(off.length),
        off.coverageAt(off.length),
        reason: 'with nothing folded the two questions have one answer',
      );
    });

    test('answered coverage never exceeds the whole, or trails coverage', () {
      final slice = LinePruner.rank([
        ..._tailTwins(),
        _line([..._sicilian, 'Nf6'], probability: 0.2),
      ], diversity: const LineDiversity(maxOverlap: 0.7));
      for (var n = 1; n <= slice.length; n++) {
        expect(
          slice.answeredCoverageAt(n),
          lessThanOrEqualTo(1.0),
          reason: 'cut of $n',
        );
        expect(
          slice.answeredCoverageAt(n),
          greaterThanOrEqualTo(slice.coverageAt(n)),
          reason: 'cut of $n',
        );
      }
    });

    test('a rejected line still comes back to own a kept stub', () {
      // The stub names the owner's move order and outranks it, so the owner
      // is the one the bar rejects. A book naming a move order it does not
      // contain is the worse book, so the pin outranks the bar.
      final owner = _lineWithUnits(
        ['d4', 'Nf6', 'c4', 'e6'],
        ['u1', 'u2'],
        probability: 0.3,
      );
      const stub = ExtractedLine(
        movesSan: ['c4', 'e6', 'd4', 'Nf6'],
        movesUci: ['c4', 'e6', 'd4', 'Nf6'],
        probability: 0.9,
        coverageUnits: [
          LineCoverageUnit(key: 'u1', value: 2.0),
          LineCoverageUnit(key: 'u3', value: 1.5),
        ],
        transposesInto: ['d4', 'Nf6', 'c4', 'e6'],
      );
      final slice = LinePruner.rank([
        owner,
        stub,
      ], diversity: const LineDiversity(maxOverlap: 0.1));
      expect(slice.length, 1, reason: 'the owner failed the bar');
      expect(
        slice.take(1).map((l) => l.movesSan.first),
        containsAll(<String>['c4', 'd4']),
        reason: 'and is in the export anyway, because the stub names it',
      );
    });

    test('fromConfig reads the knobs the build was given', () {
      const config = TreeBuildConfig(
        startFen: kStandardStartFen,
        playAsWhite: true,
        lineMinNewShare: 0.4,
        lineMaxOverlap: 0.55,
        lineMaxFoldPlies: 3,
      );
      final d = LineDiversity.fromConfig(config);
      expect(d.minNewShare, 0.4);
      expect(d.maxOverlap, 0.55);
      expect(d.maxFoldPlies, 3);
      expect(d.isActive, isTrue);
      expect(LineDiversity.off.isActive, isFalse);
    });
  });
}
