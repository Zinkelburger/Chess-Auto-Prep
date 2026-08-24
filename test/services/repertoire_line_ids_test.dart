/// Tests for [RepertoireLineIds], extracted from `RepertoireService`.
///
/// These ids are **persisted**: training progress and review history are
/// keyed by them. Changing how any of them computes is a data migration that
/// silently orphans every user's history, so the values are pinned here
/// rather than only their properties.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/services/repertoire_line_ids.dart';

const _ids = RepertoireLineIds();

/// Two lines sharing a long opening prefix — the normal case in a
/// repertoire, and the one that makes the truncated id collide.
const _sharedPrefix = [
  'e4',
  'e5',
  'Nf3',
  'Nc6',
  'Bb5',
  'a6',
  'Ba4',
  'Nf6',
  'O-O',
  'Be7',
  'Re1',
  'b5',
  'Bb3',
  'd6',
  'c3',
  'O-O',
  'h3',
  'Na5',
  'Bc2',
  'c5',
];

void main() {
  group('stable ids', () {
    test('are deterministic across calls', () {
      expect(
        _ids.stable(const ['e4', 'e5'], 0),
        _ids.stable(const ['e4', 'e5'], 0),
      );
    });

    test('depend on the file position as well as the moves', () {
      expect(
        _ids.stable(const ['e4', 'e5'], 0),
        isNot(_ids.stable(const ['e4', 'e5'], 1)),
      );
    });

    test('are prefixed and length-capped', () {
      final id = _ids.stable(_sharedPrefix, 0);
      expect(id, startsWith('line_'));
      expect(id.length, lessThanOrEqualTo('line_'.length + 22));
    });

    test('a short move list is not padded or truncated', () {
      // The substring guard only applies above 22 characters; a two-move line
      // encodes shorter than that and must survive whole.
      final id = _ids.stable(const ['e4'], 0);
      expect(id, startsWith('line_'));
      expect(id.length, greaterThan('line_'.length));
    });

    test('collide on a long shared prefix — the reason the rest exists', () {
      // Not a bug being pinned as correct: this is the documented weakness
      // that resolveCollisions is there to absorb. If this ever stops being
      // true the collision machinery is dead code worth deleting.
      final a = _ids.stable(_sharedPrefix, 0);
      final b = _ids.stable([..._sharedPrefix, 'd4'], 0);
      expect(a, b);
    });
  });

  group('full ids', () {
    test('do not collide on a long shared prefix', () {
      expect(
        _ids.full(_sharedPrefix, 0),
        isNot(_ids.full([..._sharedPrefix, 'd4'], 0)),
      );
    });

    test('depend on the file position', () {
      expect(_ids.full(_sharedPrefix, 0), isNot(_ids.full(_sharedPrefix, 1)));
    });
  });

  group('ids from headers', () {
    test('a LineID header wins over the move-based fallback', () {
      expect(_ids.fromHeaders(const {'LineID': 'abc'}, const ['e4'], 0), 'abc');
    });

    test('every accepted spelling is honoured, in priority order', () {
      for (final key in RepertoireLineIds.headerKeys) {
        expect(
          _ids.fromHeaders({key: 'from-$key'}, const ['e4'], 0),
          'from-$key',
          reason: '$key is listed as an accepted id header',
        );
      }
      // LineID outranks the rest when a file carries more than one.
      expect(
        _ids.fromHeaders(
          const {'Guid': 'low', 'LineID': 'high'},
          const ['e4'],
          0,
        ),
        'high',
      );
    });

    test('a blank header falls through to the move-based id', () {
      expect(
        _ids.fromHeaders(const {'LineID': '   '}, const ['e4'], 0),
        _ids.stable(const ['e4'], 0),
      );
    });

    test('a header id is trimmed', () {
      expect(
        _ids.fromHeaders(const {'LineID': '  abc  '}, const ['e4'], 0),
        'abc',
      );
    });

    test('no header at all gives the move-based id', () {
      expect(
        _ids.fromHeaders(const {}, const ['e4', 'e5'], 3),
        _ids.stable(const ['e4', 'e5'], 3),
      );
    });
  });

  group('resolveCollisions', () {
    test('leaves an already-distinct list untouched', () {
      final ids = <String?>['a', 'b', 'c'];
      expect(
        _ids.resolveCollisions(
          ids,
          [
            const ['e4'],
            const ['d4'],
            const ['c4'],
          ],
          const [0, 1, 2],
        ),
        ['a', 'b', 'c'],
      );
    });

    test('the first claimant keeps the id, so saved progress stays valid', () {
      final out = _ids.resolveCollisions(
        <String?>['dup', 'dup'],
        [_sharedPrefix, _sharedPrefix],
        const [0, 1],
      );

      expect(out[0], 'dup', reason: 'the first line must not be renumbered');
      expect(out[1], isNot('dup'));
    });

    test('a collision escalates to the hash id, not the stable one', () {
      // The colliding id may be a *header* id, in which case the stable id
      // was never tried and could be free. Returning it would hand the line
      // an id different from the one already saved against it.
      final out = _ids.resolveCollisions(
        <String?>['shared-header', 'shared-header'],
        [
          const ['e4'],
          const ['d4'],
        ],
        const [0, 1],
      );

      expect(out[1], _ids.full(const ['d4'], 1));
      expect(out[1], isNot(_ids.stable(const ['d4'], 1)));
    });

    test('nulls are preserved and do not consume an id', () {
      final out = _ids.resolveCollisions(
        <String?>['a', null, 'a'],
        [
          const ['e4'],
          const [],
          const ['d4'],
        ],
        const [0, 1, 2],
      );

      expect(out[0], 'a');
      expect(out[1], isNull);
      expect(out[2], isNot('a'));
    });

    test('three-way collisions all end up distinct', () {
      final out = _ids.resolveCollisions(
        <String?>['x', 'x', 'x'],
        [
          const ['e4'],
          const ['d4'],
          const ['c4'],
        ],
        const [0, 1, 2],
      );

      expect(out.toSet().length, 3);
    });

    test('a whole repertoire of long shared-prefix lines stays distinct', () {
      // The real shape of the bug: twenty Ruy Lopez lines whose stable ids
      // are all the same string.
      const n = 20;
      final moves = [
        for (var i = 0; i < n; i++) [..._sharedPrefix, 'move$i'],
      ];
      final indices = [for (var i = 0; i < n; i++) i];
      final raw = <String?>[
        for (var i = 0; i < n; i++) _ids.stable(moves[i], i),
      ];

      final out = _ids.resolveCollisions(raw, moves, indices);

      expect(out.whereType<String>().toSet().length, n);
    });
  });

  group('forNewLine', () {
    test('predicts the stable id a reload will assign', () {
      // The prediction has to match what parseRepertoirePgn produces, or an
      // edit made before the reload targets a different game.
      expect(
        _ids.forNewLine(const ['e4', 'e5'], 4, existingIds: const []),
        _ids.stable(const ['e4', 'e5'], 4),
      );
    });

    test('escalates when the predicted id is already taken', () {
      final taken = _ids.stable(const ['e4', 'e5'], 4);
      final id = _ids.forNewLine(const ['e4', 'e5'], 4, existingIds: [taken]);

      expect(id, isNot(taken));
      expect(id, _ids.full(const ['e4', 'e5'], 4));
    });

    test('escalates past a taken hash id too', () {
      final stable = _ids.stable(const ['e4', 'e5'], 4);
      final full = _ids.full(const ['e4', 'e5'], 4);
      final id = _ids.forNewLine(
        const ['e4', 'e5'],
        4,
        existingIds: [stable, full],
      );

      expect(id, isNot(stable));
      expect(id, isNot(full));
      expect(id, startsWith('line_'));
    });

    test('an unrelated existing id does not push it off the prediction', () {
      expect(
        _ids.forNewLine(const ['e4'], 0, existingIds: const ['something-else']),
        _ids.stable(const ['e4'], 0),
      );
    });
  });

  test('the shared const instance behaves as the class does', () {
    expect(
      repertoireLineIds.stable(const ['e4'], 0),
      _ids.stable(const ['e4'], 0),
    );
  });
}
