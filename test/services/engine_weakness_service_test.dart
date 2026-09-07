/// Tests for [EngineWeaknessService], which evaluates the positions a player
/// reaches often enough to matter and hands back White-normalised evals.
///
/// The decisions being pinned: which positions qualify (an occurrence floor
/// applied to transposition-summed counts, not per path), how a side-to-move
/// engine score becomes a White-relative one, how a forced mate is packed,
/// and what happens when searches fail or the caller cancels.
library;

import 'package:chess_auto_prep/models/engine_settings.dart';
import 'package:chess_auto_prep/models/engine_weakness_result.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import 'package:chess_auto_prep/services/engine_weakness_service.dart';
import 'package:chess_auto_prep/services/opening_tree_builder.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/hunt_harness.dart';
import '../support/scripted_engine.dart';

/// Four White games: 1.e4 e5 then 2.Nf3 Nc6 three times, 2.Bc4 Nf6 once.
const _whiteGames = [
  '[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 1-0',
  '[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 1-0',
  '[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 1-0',
  '[Result "0-1"]\n\n1. e4 e5 2. Bc4 Nf6 0-1',
];

/// Three Black games down one line.
const _blackGames = [
  '[Result "0-1"]\n\n1. d4 d5 2. c4 e6 0-1',
  '[Result "0-1"]\n\n1. d4 d5 2. c4 e6 0-1',
  '[Result "1-0"]\n\n1. d4 d5 2. c4 e6 1-0',
];

/// The same position by two move orders, two games one way and one the other.
/// Knight moves only, so the two FENs agree in every field.
const _transposedGames = [
  '[Result "1-0"]\n\n1. Nf3 Nf6 2. Nc3 Nc6 1-0',
  '[Result "1-0"]\n\n1. Nf3 Nf6 2. Nc3 Nc6 1-0',
  '[Result "1-0"]\n\n1. Nc3 Nc6 2. Nf3 Nf6 1-0',
];

Future<OpeningTree> _build(List<String> games, {bool asWhite = true}) =>
    OpeningTreeBuilder.buildTree(
      pgnList: games,
      username: '',
      userIsWhite: asWhite,
      strictPlayerMatching: false,
      maxDepth: 12,
    );

void main() {
  late ScriptedEngine engine;
  late EvalWorker worker;
  late EngineWeaknessService service;
  late OpeningTree whiteTree;

  OpeningTreeNode at(OpeningTree tree, List<String> path) {
    var node = tree.root;
    for (final san in path) {
      node = node.children[san]!;
    }
    return node;
  }

  void scriptEval(String fen, ScriptLine line) =>
      engine.evals[normalizeFen(fen)] = line;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    // One worker asked for, one worker injected: `ensureWorkers()` then has
    // nothing to spawn, so no real Stockfish is started.
    EngineSettings.instance.cores = 1;
    engine = ScriptedEngine();
    worker = await installScriptedWorker(engine);
    service = EngineWeaknessService();
    whiteTree = await _build(_whiteGames);
  });

  tearDown(() {
    service.dispose();
    resetPool();
  });

  group('which positions qualify', () {
    test('the occurrence floor is inclusive', () async {
      // Games at each position: root 4, 1.e4 4, 1...e5 4, 2.Nf3 3,
      // 2...Nc6 3, 2.Bc4 1, 2...Nf6 1.
      final three = await service.analyze(
        whiteTree: whiteTree,
        minOccurrences: 3,
      );
      expect(three.map((r) => r.gamesPlayed).toList()..sort(), [3, 3, 4, 4, 4]);

      final four = await service.analyze(
        whiteTree: whiteTree,
        minOccurrences: 4,
      );
      expect(four.map((r) => r.movePath).toSet(), {
        'Starting position',
        '1.e4',
        '1.e4 e5',
      });
    });

    test('nothing qualifying means no work and no progress ticks', () async {
      final progress = <String>[];

      final results = await service.analyze(
        whiteTree: whiteTree,
        minOccurrences: 99,
        onProgress: (c, t) => progress.add('$c/$t'),
      );

      expect(results, isEmpty);
      expect(progress, isEmpty);
      expect(engine.evalSearches, isEmpty);
    });

    test('no trees at all is not an error', () async {
      expect(await service.analyze(minOccurrences: 1), isEmpty);
    });

    test(
      'transpositions are summed, so a split path still qualifies',
      () async {
        final tree = await _build(_transposedGames);
        final byOrderOne = at(tree, ['Nf3', 'Nf6', 'Nc3', 'Nc6']);
        final byOrderTwo = at(tree, ['Nc3', 'Nc6', 'Nf3', 'Nf6']);

        // Two ways in, and neither reaches three games on its own.
        expect(normalizeFen(byOrderOne.fen), normalizeFen(byOrderTwo.fen));
        expect(byOrderOne.gamesPlayed, 2);
        expect(byOrderTwo.gamesPlayed, 1);

        final results = await service.analyze(
          whiteTree: tree,
          minOccurrences: 3,
        );

        final merged = results.singleWhere(
          (r) => normalizeFen(r.fen) == normalizeFen(byOrderOne.fen),
        );
        expect(merged.gamesPlayed, 3);
        // The representative path is the busier one.
        expect(merged.movePath, '1.Nf3 Nf6 2.Nc3 Nc6');
        // And the position is searched once, not once per path.
        expect(
          engine.evalSearches
              .map(normalizeFen)
              .where((f) => f == normalizeFen(byOrderOne.fen)),
          hasLength(1),
        );
      },
    );

    test('win/draw/loss stats come from the summed group', () async {
      final results = await service.analyze(
        whiteTree: whiteTree,
        minOccurrences: 4,
      );

      final root = results.singleWhere(
        (r) => r.movePath == 'Starting position',
      );
      expect(root.gamesPlayed, 4);
      expect(root.wins, 3);
      expect(root.losses, 1);
      expect(root.draws, 0);
      expect(root.winRate, closeTo(0.75, 1e-9));
    });
  });

  group('score normalisation', () {
    test(
      'a Black-to-move score is flipped to White\'s point of view',
      () async {
        final afterE4 = at(whiteTree, ['e4']);
        scriptEval(whiteTree.root.fen, const ScriptLine.cp(30, pv: ['e2e4']));
        // Black to move here: +50 for Black is -50 for White.
        scriptEval(afterE4.fen, const ScriptLine.cp(50, pv: ['e7e5']));

        final results = await service.analyze(
          whiteTree: whiteTree,
          minOccurrences: 4,
        );

        expect(_evalAt(results, 'Starting position'), 30);
        expect(_evalAt(results, '1.e4'), -50);
      },
    );

    test('a forced mate is packed as a mate, both ways round', () async {
      scriptEval(whiteTree.root.fen, const ScriptLine.mate(2, pv: ['e2e4']));
      // Black to move and mating: from White's side that is -#4.
      scriptEval(
        at(whiteTree, ['e4']).fen,
        const ScriptLine.mate(4, pv: ['e7e5']),
      );

      final results = await service.analyze(
        whiteTree: whiteTree,
        minOccurrences: 4,
      );

      final root = results.singleWhere(
        (r) => r.movePath == 'Starting position',
      );
      expect(root.evalMate, 2);
      expect(root.evalCp, 10000);
      expect(root.evalDisplay, '#2');

      final afterE4 = results.singleWhere((r) => r.movePath == '1.e4');
      expect(afterE4.evalMate, -4);
      expect(afterE4.evalCp, -10000);
      expect(afterE4.evalDisplay, '-#4');
    });

    test(
      'the reported depth is the engine\'s, not the requested one',
      () async {
        scriptEval(
          whiteTree.root.fen,
          const ScriptLine.cp(12, pv: ['e2e4'], depth: 17),
        );

        final results = await service.analyze(
          whiteTree: whiteTree,
          minOccurrences: 4,
          depth: 30,
        );

        expect(
          results.singleWhere((r) => r.movePath == 'Starting position').depth,
          17,
        );
      },
    );
  });

  test('White and Black trees are both analysed and tagged', () async {
    final blackTree = await _build(_blackGames, asWhite: false);

    final results = await service.analyze(
      whiteTree: whiteTree,
      blackTree: blackTree,
      minOccurrences: 3,
    );

    expect(results.where((r) => r.playerIsWhite), hasLength(5));
    expect(results.where((r) => !r.playerIsWhite), hasLength(5));

    // The start position belongs to both trees and is reported for each.
    final roots = results.where((r) => r.movePath == 'Starting position');
    expect(roots, hasLength(2));
    expect(roots.map((r) => r.playerIsWhite).toSet(), {true, false});
  });

  group('streaming', () {
    test('each result is delivered before its progress tick', () async {
      final events = <String>[];

      final results = await service.analyze(
        whiteTree: whiteTree,
        minOccurrences: 4,
        onResult: (r) => events.add('result'),
        onProgress: (c, t) => events.add('progress $c/$t'),
      );

      expect(results, hasLength(3));
      expect(events, [
        'progress 0/3',
        'result',
        'progress 1/3',
        'result',
        'progress 2/3',
        'result',
        'progress 3/3',
      ]);
    });

    test('the worker count is reported once, before any search', () async {
      final ready = <String>[];

      await service.analyze(
        whiteTree: whiteTree,
        minOccurrences: 4,
        onWorkersReady: (workers, hashMb) => ready.add('$workers/$hashMb'),
      );

      expect(ready, ['1/${EngineSettings.instance.hashMb}']);
      expect(service.workerCount, 1);
    });
  });

  group('failures and cancellation', () {
    test('one failed search does not lose the others', () async {
      final doomed = normalizeFen(at(whiteTree, ['e4']).fen);
      engine.onGo = (fen) {
        if (normalizeFen(fen) == doomed) worker.stop();
      };
      final progress = <int>[];

      final results = await service.analyze(
        whiteTree: whiteTree,
        minOccurrences: 4,
        onProgress: (c, _) => progress.add(c),
      );

      expect(results, hasLength(2));
      expect(results.map((r) => r.movePath), isNot(contains('1.e4')));
      // The failed position still advances the bar to the end.
      expect(progress.last, 3);
    });

    test('every search failing is an error, not an empty report', () async {
      engine.onGo = (_) => worker.stop();

      await expectLater(
        service.analyze(whiteTree: whiteTree, minOccurrences: 4),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('failed for all 3 positions'),
          ),
        ),
      );
    });

    test('cancelling keeps what finished and raises nothing', () async {
      final results = await service.analyze(
        whiteTree: whiteTree,
        minOccurrences: 4,
        onResult: (_) => service.cancel(),
      );

      expect(results, hasLength(1));
      expect(engine.evalSearches, hasLength(1));
    });
  });
}

int _evalAt(List<EngineWeaknessResult> results, String movePath) =>
    results.singleWhere((r) => r.movePath == movePath).evalCp;
