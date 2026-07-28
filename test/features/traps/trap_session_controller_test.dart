import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/traps/controllers/trap_session_controller.dart';
import 'package:chess_auto_prep/features/traps/services/trap_index_service.dart';
import 'package:chess_auto_prep/models/trap_line_info.dart';

TrapLineInfo _trap(
  List<String> moves, {
  double surplus = 0.1,
  String? fen,
  String? opening,
}) {
  return TrapLineInfo(
    movesSan: moves,
    trapScore: 0.5,
    popularProb: 0.4,
    popularMove: 'Nd7',
    bestMove: 'b4',
    popularEvalCp: 252,
    bestEvalCp: 10,
    evalDiffCp: 200,
    cumulativeProb: 0.01,
    trickSurplus: surplus,
    expectimaxValue: 0.59,
    wpEval: 0.51,
    fen: fen,
    openingName: opening,
  );
}

/// A four-field FEN the index can key on.
const _fenA = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -';
const _fenB = 'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq -';

TrapSessionController _controller(
  Map<String, List<TrapLineInfo>?> files, {
  List<String>? reads,
}) {
  return TrapSessionController(
    loadFile: (path) async {
      reads?.add(path);
      return files[path];
    },
  );
}

void main() {
  group('loading', () {
    test('builds an index from the sidecar file', () async {
      final session = _controller({
        'rep.pgn': [
          _trap(['e4'], fen: _fenA),
        ],
      });
      addTearDown(session.dispose);

      await session.loadFromFile('rep.pgn');

      expect(session.hasTraps, isTrue);
      expect(session.traps, hasLength(1));
      expect(session.index, isNotNull);
      expect(session.trapAtFen(_fenA), isNotNull);
    });

    test('a missing or empty sidecar leaves no index to query', () async {
      final session = _controller({'rep.pgn': null});
      addTearDown(session.dispose);

      await session.loadFromFile('rep.pgn');

      expect(session.hasTraps, isFalse);
      expect(session.traps, isEmpty);
      // Null rather than an empty index: callers gate whole panels on this.
      expect(session.index, isNull);
      expect(session.trapAtFen(_fenA), isNull);
    });

    test('notifies once per load so the screen repaints', () async {
      final session = _controller({
        'rep.pgn': [
          _trap(['e4'], fen: _fenA),
        ],
      });
      addTearDown(session.dispose);
      var notifications = 0;
      session.addListener(() => notifications++);

      await session.loadFromFile('rep.pgn');

      expect(notifications, 1);
    });
  });

  group('adoptFromBuild', () {
    test(
      'takes the finished build\'s index without touching the file',
      () async {
        final reads = <String>[];
        final session = _controller({
          'rep.pgn': [
            _trap(['e4'], fen: _fenA),
          ],
        }, reads: reads);
        addTearDown(session.dispose);

        await session.adoptFromBuild(
          TrapIndexService([
            _trap(['d4'], fen: _fenB),
          ]),
          fallbackFilePath: 'rep.pgn',
        );

        expect(session.traps.single.movesSan, ['d4']);
        expect(reads, isEmpty);
      },
    );

    test('re-reads the sidecar when the build kept no bundle', () async {
      final reads = <String>[];
      final session = _controller({
        'rep.pgn': [
          _trap(['e4'], fen: _fenA),
        ],
      }, reads: reads);
      addTearDown(session.dispose);

      await session.adoptFromBuild(null, fallbackFilePath: 'rep.pgn');

      expect(session.traps.single.movesSan, ['e4']);
      expect(reads, ['rep.pgn']);
    });

    test('a build that found nothing clears the index', () async {
      final session = _controller({});
      addTearDown(session.dispose);

      await session.adoptFromBuild(TrapIndexService(const []));

      expect(session.hasTraps, isFalse);
      expect(session.index, isNull);
    });
  });

  group('tour', () {
    test('will not open over an empty trap list', () async {
      final session = _controller({'rep.pgn': null});
      addTearDown(session.dispose);
      await session.loadFromFile('rep.pgn');

      expect(session.openTour(), isFalse);
      expect(session.tourVisible, isFalse);
    });

    test('opens on the requested trap and closes once', () async {
      final start = _trap(['e4'], fen: _fenA);
      final session = _controller({
        'rep.pgn': [start],
      });
      addTearDown(session.dispose);
      await session.loadFromFile('rep.pgn');

      expect(session.openTour(startTrap: start), isTrue);
      expect(session.tourVisible, isTrue);
      expect(session.tourInitialTrap, same(start));

      // Returning whether it was open is what lets Esc fall through to the
      // bottom pane when no tour is running.
      expect(session.closeTour(), isTrue);
      expect(session.tourVisible, isFalse);
      expect(session.tourInitialTrap, isNull);
      expect(session.closeTour(), isFalse);
    });

    test('a repertoire switch drops the previous tour', () async {
      final session = _controller({
        'rep.pgn': [
          _trap(['e4'], fen: _fenA),
        ],
        'other.pgn': [
          _trap(['d4'], fen: _fenB),
        ],
      });
      addTearDown(session.dispose);
      await session.loadFromFile('rep.pgn');
      session.openTour();

      session.endTourForRepertoireSwitch();
      await session.loadFromFile('other.pgn');

      expect(session.tourVisible, isFalse);
      expect(session.traps.single.movesSan, ['d4']);
    });
  });

  test('titleFor numbers traps in tour order', () async {
    final weak = _trap(['e4'], surplus: 0.05, fen: _fenA, opening: 'Open Game');
    final strong = _trap(['d4'], surplus: 0.5, fen: _fenB);
    final session = _controller({
      'rep.pgn': [weak, strong],
    });
    addTearDown(session.dispose);
    await session.loadFromFile('rep.pgn');

    expect(session.titleFor(strong), 'Trap #1');
    expect(session.titleFor(weak), 'Trap #2 · Open Game');
  });

  test('a load that lands after dispose does not throw', () async {
    final session = _controller({
      'rep.pgn': [
        _trap(['e4'], fen: _fenA),
      ],
    });
    final pending = session.loadFromFile('rep.pgn');
    session.dispose();
    await expectLater(pending, completes);
  });
}
