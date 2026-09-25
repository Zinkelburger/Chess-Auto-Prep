import 'dart:async';

import 'package:chess_auto_prep/v2/chess/pgn/analysis_board.dart';
import 'package:chess_auto_prep/v2/chess/generation/eval.dart';
import 'package:chess_auto_prep/v2/chess/generation/search_node.dart';
import 'package:chess_auto_prep/v2/chess/generation/sources.dart';
import 'package:chess_auto_prep/v2/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/pending_writes.dart';
import 'package:chess_auto_prep/v2/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/v2/storage/finds_store.dart';
import 'package:chess_auto_prep/v2/storage/generation_trees.dart';
import 'package:chess_auto_prep/v2/workspace/fill_gaps.dart';
import 'package:chess_auto_prep/v2/workspace/finds.dart';
import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:dartchess/dartchess.dart' show Position, Side;
import 'package:flutter_test/flutter_test.dart';

import '../chess/generation/scripted_sources.dart';
import '../support/scripted_engine.dart';
import '../support/scripted_store.dart';
import '../support/session_fixture.dart';

/// White king and pawn against a bare king: few moves, so a run is small.
const kingAndPawn = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';

const chapter =
    '''
// Color: White

[Event "Main"]
[Result "*"]
[FEN "$kingAndPawn"]
[SetUp "1"]

1. e4 Kd8 *
''';

/// An engine the test can hold: every question waits until [release].
final class GatedEvaluator implements PositionEvaluator {
  final asked = <String>[];
  final _gate = Completer<void>();

  void release() => _gate.complete();

  @override
  Future<EvaluationResult> evaluate(Position position) async {
    asked.add(position.fen);
    await _gate.future;
    return const Evaluated(Eval(0));
  }
}

void main() {
  late SessionFixture fixture;
  late ScriptedEngine engine;
  late EngineAnalysis analysis;
  late int releases;

  const request = FillRequest(elo: 2200, depthPlies: 3);

  setUp(() async {
    fixture = await openSession(chapter);
    engine = ScriptedEngine();
    analysis = EngineAnalysis(fixture.session, () async => Started(engine));
    await analysis.enable();
    releases = 0;
  });

  tearDown(() {
    analysis.dispose();
    fixture.dispose();
  });

  FillGaps fillWith(
    PositionEvaluator evaluator, {
    OpponentPolicy policy = const ScriptedPolicy({'e8d8': 1}),
    TreeKeeper? keepTree,
    Finds? finds,
    PgnDocumentStore? documents,
    PendingWrites? pending,
    bool dispose = true,
    FillToolsFactory? tools,
    Future<void> Function()? release,
  }) {
    final fill = FillGaps(
      session: fixture.session,
      analysis: analysis,
      documents: documents ?? fixture.store,
      tools:
          tools ??
          (_) async => FillReady(
            evaluator: evaluator,
            policy: policy,
            release: release ?? () async => releases++,
          ),
      keepTree: keepTree,
      pendingWrites: pending,
      finds: finds,
      clock: () => DateTime(2026, 9, 22, 12),
    );
    if (dispose) addTearDown(fill.dispose);
    return fill;
  }

  ChapterRef draft([String name = 'Main (draft)']) => chapterRef('KID', name);

  String textOf(ChapterRef ref) => switch (fixture.store.documents[ref]) {
    Opened(:final text) => text,
    _ => fail('$ref was not written'),
  };

  /// The search on White's e4 scored a pawn better than anything else, so
  /// the best line starts with the chapter's own move.
  Map<String, int> e4Best() => {
    afterUci(positionOf(kingAndPawn), 'e2e4').fen: -100,
  };

  test('throwing tool startup reports failure and resumes analysis', () async {
    final fill = fillWith(
      ScriptedEvaluator(),
      tools: (_) async => throw StateError('startup failed'),
    );
    expect(await fill.start(request), isNull);
    expect(fill.state, isA<FillFailed>());
    expect(fill.canStart, isTrue);
    expect(analysis.paused, isFalse);
  });

  test(
    'unexpected search decoding failure releases once and resumes analysis',
    () async {
      final fill = fillWith(
        ScriptedEvaluator(),
        policy: ScriptedPolicy(_BrokenWeights()),
      );
      expect(await fill.start(request), isNull);
      expect(fill.state, isA<FillFailed>());
      expect(releases, 1);
      expect(analysis.paused, isFalse);
    },
  );

  test(
    'throwing release cannot report completion or strand running state',
    () async {
      final fill = fillWith(
        ScriptedEvaluator(),
        release: () async {
          releases++;
          throw StateError('release failed');
        },
      );
      expect(await fill.start(request), isNull);
      expect(fill.state, isA<FillFailed>());
      expect(releases, 1);
      expect(analysis.paused, isFalse);
      expect(fill.canStart, isTrue);
    },
  );

  test(
    'cancel waits for already-started release and consumes its failure',
    () async {
      final evaluator = GatedEvaluator();
      final entered = Completer<void>();
      final release = Completer<void>();
      final fill = fillWith(
        evaluator,
        release: () async {
          releases++;
          evaluator.release();
          entered.complete();
          await release.future;
          throw StateError('release failed');
        },
      );
      final running = fill.start(request);
      while (evaluator.asked.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      fill.cancel();
      await entered.future;
      await pumpEventQueue();
      expect(analysis.paused, isTrue);
      expect(fill.canStart, isFalse);
      release.complete();
      await running;
      expect(fill.state, isA<FillFailed>());
      expect(releases, 1);
      expect(analysis.paused, isFalse);
    },
  );

  test(
    'disposal consumes a late throwing release without abandoning it',
    () async {
      final evaluator = GatedEvaluator();
      final entered = Completer<void>();
      final release = Completer<void>();
      final fill = fillWith(
        evaluator,
        dispose: false,
        release: () async {
          releases++;
          evaluator.release();
          entered.complete();
          await release.future;
          throw StateError('release failed');
        },
      );
      final running = fill.start(request);
      while (evaluator.asked.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      fill.dispose();
      await entered.future;
      await pumpEventQueue();
      expect(analysis.paused, isTrue);
      release.complete();
      await running;
      expect(releases, 1);
      expect(analysis.paused, isFalse);
    },
  );

  test('a run keeps its tree for the Search tab and writes nothing', () async {
    final trees = <String>[];
    final fill = fillWith(
      ScriptedEvaluator(scores: e4Best()),
      keepTree: (ref, tree, {required runId}) async => trees.add(tree),
    );
    expect(fill.canStart, isTrue);
    expect(await fill.start(request), isNull);
    final done = fill.state as FillDone;
    expect(done.complete, isTrue);
    expect(done.depth, 3);
    expect(done.nodes, greaterThan(1));
    final found = fill.found!;
    expect(found.side, Side.white);
    final root = found.tree as OurNode;
    expect(root.chosen.move.san, 'e4');
    expect(fixture.store.documents.keys, [fixture.ref], reason: 'no draft');
    expect(fixture.onDisk, chapter, reason: 'the chapter is not written');
    expect(releases, 1);
    expect(trees.single, contains('"format": "opening_tree"'));
    expect(trees.single, contains('"eval_depth": 14'));
    expect(fill.canMakeLines, isTrue);
  });

  test('a tree that cannot be kept is logged; the search is done and the '
      'next one starts', () async {
    final pending = PendingWrites();
    var attempts = 0;
    final fill = fillWith(
      ScriptedEvaluator(scores: e4Best()),
      pending: pending,
      keepTree: (_, _, {required runId}) async {
        attempts++;
        throw StateError('disk full');
      },
    );
    await fill.start(request);
    expect(fill.state, isA<FillDone>());
    expect(fill.canMakeLines, isTrue);
    expect(await pending.settle(), isNull, reason: 'nothing to ask on exit');
    expect(fill.canStart, isTrue);
    expect(await fill.start(request), isNull);
    expect(fill.state, isA<FillDone>());
    expect(attempts, 2);
  });

  test('accepted draft finishes after owner disposal', () async {
    final pending = PendingWrites();
    final fill = fillWith(
      ScriptedEvaluator(scores: e4Best()),
      pending: pending,
      dispose: false,
    );
    await fill.start(request);
    fixture.store.hold = true;
    final writing = fill.makeLines();
    while (fixture.store.waiting == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    fill.dispose();
    fixture.store.hold = false;
    fixture.store.releaseAll();
    await writing;
    expect(textOf(draft()), contains('[Event "Main (draft)"]'));
    expect(await pending.settle(), isNull);
  });

  test('the tree is read at the position on the board: by the moves from '
      'the document root, and nowhere off the search', () async {
    final fill = fillWith(ScriptedEvaluator(scores: e4Best()));
    await fill.start(request);
    final found = fill.found!;
    const root = Fen(kingAndPawn);
    expect(found.at(root, const []), isA<OurNode>());
    expect(found.at(root, const ['e4']), isA<OpponentNode>());
    expect(found.at(root, const ['e4', 'Kd8']), isA<OurNode>());
    expect(found.at(root, const ['e4', 'Kf8']), isNull, reason: 'not played');
    expect(found.at(Fen.initial, const []), isNull, reason: 'another root');
  });

  test('the tree so far is shown while the search runs', () async {
    final fill = fillWith(ScriptedEvaluator(scores: e4Best()));
    final shown = <SearchNode>[];
    fill.addListener(() {
      if (fill.running && fill.found != null) shown.add(fill.found!.tree);
    });
    await fill.start(request);
    expect(shown, isNotEmpty);
    expect(shown.first, isA<OurNode>(), reason: 'the root was answered first');
  });

  test('the way out waits for a tree still being written', () async {
    final pending = PendingWrites();
    final release = Completer<void>();
    final fill = fillWith(
      ScriptedEvaluator(scores: e4Best()),
      pending: pending,
      keepTree: (_, _, {required runId}) => release.future,
    );
    final running = fill.start(request);
    while (fill.state is! FillDone) {
      await Future<void>.delayed(Duration.zero);
    }
    var settled = false;
    final settling = pending.settle().then((_) => settled = true);
    await pumpEventQueue();
    expect(settled, isFalse);
    release.complete();
    await settling;
    await running;
  });

  test(
    'a draft whose write failed is made again under the next name',
    () async {
      final documents = _LostCreate(fixture.store);
      final fill = fillWith(
        ScriptedEvaluator(scores: e4Best()),
        documents: documents,
      );
      await fill.start(request);
      await fill.makeLines();
      expect(fill.lines, isA<LinesFailed>());
      expect(fill.canMakeLines, isTrue);
      await fill.makeLines();
      expect((fill.lines as LinesWritten).draft, draft('Main (draft 2)'));
    },
  );

  test('lines are written only when asked: a draft chapter beside the one '
      'the search started on, its moves carrying their values', () async {
    final fill = fillWith(ScriptedEvaluator(scores: e4Best()));
    await fill.start(request);
    expect(fill.lines, isNull);
    await fill.makeLines();
    final written = fill.lines as LinesWritten;
    expect(written.draft, draft());
    expect(written.lines, greaterThan(0));
    final text = textOf(draft());
    expect(text, startsWith('// Main (draft)\n// Draft\n// Color: White\n'));
    expect(text, contains('[FEN "$kingAndPawn"]'));
    expect(text, contains('[%expectimax'));
    expect(fixture.onDisk, chapter, reason: 'the chapter is not written');
    expect(fill.canMakeLines, isFalse, reason: 'once per run');
  });

  test('on the analysis board a run writes nothing and cannot become lines, '
      'for the side at the bottom of the board', () async {
    await fixture.session.showAnalysisBoard(
      analysisBoard(side: Side.black, root: const Fen(kingAndPawn)),
    );
    final fill = fillWith(
      ScriptedEvaluator(),
      policy: const ScriptedPolicy({'e2e4': 1}),
    );
    expect(fill.canStart, isTrue);
    final writes = fixture.store.creates.length;
    const shallow = FillRequest(elo: 2200, depthPlies: 2);
    expect(await fill.start(shallow), isNull);
    expect(fill.state, isA<FillDone>());
    expect(fixture.store.creates, hasLength(writes), reason: 'nothing saved');
    expect(fill.found!.side, Side.black);
    expect(fill.canMakeLines, isFalse);
  });

  test('Finish now stops after the expansion under way and keeps what the '
      'search has so far', () async {
    final fill = fillWith(ScriptedEvaluator());
    // Finish as soon as the first position is answered.
    void finishEarly() {
      if (fill.state case FillRunning(:final nodes) when nodes > 1) {
        fill.finish();
      }
    }

    fill.addListener(finishEarly);
    await fill.start(const FillRequest(elo: 2200, depthPlies: 8));
    fill.removeListener(finishEarly);
    final done = fill.state as FillDone;
    expect(done.complete, isFalse);
    expect(done.depth, lessThan(8));
    expect(fill.found!.tree, isA<OurNode>(), reason: 'the root was answered');
    expect(releases, 1);
  });

  test('every move of ours is searched, the chapter\'s or not', () async {
    final evaluator = ScriptedEvaluator();
    final fill = fillWith(evaluator);
    await fill.start(request);
    final root = positionOf(kingAndPawn);
    expect(evaluator.asked, contains(afterUci(root, 'e2e4').fen));
    expect(evaluator.asked, contains(afterUci(root, 'e2e3').fen));
  });

  test('the engine pane is paused for the run and follows the board again '
      'after it', () async {
    final gate = GatedEvaluator();
    final fill = fillWith(gate);
    final run = fill.start(request);
    await pumpEventQueue();
    expect(analysis.state, isA<EnginePaused>());
    expect(analysis.paused, isTrue);
    expect(engine.current.stopped, isTrue, reason: 'the pane stopped looking');
    expect(fill.state, isA<FillRunning>());
    gate.release();
    await run;
    expect(analysis.paused, isFalse);
    expect(engine.searches.last.stopped, isFalse, reason: 'looking again');
  });

  test('the run holds its own pause: a training sitting that outlives it '
      'keeps the engine hidden, and one that ends during it does not wake '
      'the engine early', () async {
    final sitting = Object();
    analysis.pause(sitting, 'Hidden while training');
    await fillWith(ScriptedEvaluator(scores: e4Best())).start(request);
    expect(analysis.pausedFor, 'Hidden while training');
    analysis.resume(sitting);
    expect(analysis.paused, isFalse);

    final gate = GatedEvaluator();
    final run = fillWith(gate).start(request);
    await pumpEventQueue();
    analysis
      ..pause(sitting, 'Hidden while training')
      ..resume(sitting);
    expect(analysis.pausedFor, 'Paused while searching');
    gate.release();
    await run;
    expect(analysis.paused, isFalse);
  });

  test('a second run is refused while one is running', () async {
    final gate = GatedEvaluator();
    final fill = fillWith(gate);
    final run = fill.start(request);
    await pumpEventQueue();
    expect(fill.canStart, isFalse);
    expect(await fill.start(request), 'A search is already running.');
    gate.release();
    await run;
  });

  test(
    'cancel stops the run, hands the engine back and writes nothing',
    () async {
      final gate = GatedEvaluator();
      final fill = fillWith(gate);
      final run = fill.start(request);
      await pumpEventQueue();
      fill.cancel();
      expect((fill.state as FillRunning).cancelling, isTrue);
      expect(releases, 1, reason: 'the engine is let go at once');
      gate.release();
      await run;
      expect(fill.state, isA<FillIdle>());
      expect(fixture.store.documents.keys.map((r) => r.path), [
        fixture.ref.path,
      ]);
      expect(analysis.paused, isFalse);
    },
  );

  test(
    'no engine is a failure named on the card, and the pane resumes',
    () async {
      final fill = FillGaps(
        session: fixture.session,
        analysis: analysis,
        documents: fixture.store,
        tools: (_) async => const FillUnavailable('Stockfish is not installed'),
      );
      addTearDown(fill.dispose);
      await fill.start(request);
      expect(
        fill.state,
        isA<FillFailed>().having(
          (f) => f.reason,
          'reason',
          'Stockfish is not installed',
        ),
      );
      expect(analysis.paused, isFalse);
    },
  );

  test('an engine that finishes starting after dispose is still handed '
      'back', () async {
    final starting = Completer<FillToolsResult>();
    final fill = FillGaps(
      session: fixture.session,
      analysis: analysis,
      documents: fixture.store,
      tools: (_) => starting.future,
    );
    final run = fill.start(request);
    await pumpEventQueue();
    fill.dispose();
    starting.complete(
      FillReady(
        evaluator: ScriptedEvaluator(),
        policy: const ScriptedPolicy({'e8d8': 1}),
        release: () async => releases++,
      ),
    );
    await run;
    expect(releases, 1);
  });

  test('a model that cannot answer stops the run with the reason', () async {
    final fill = fillWith(ScriptedEvaluator(), policy: const AbsentPolicy());
    await fill.start(request);
    expect(
      fill.state,
      isA<FillFailed>().having(
        (f) => f.reason,
        'reason',
        contains('opponent model'),
      ),
    );
    expect(releases, 1);
  });

  test('an engine that gives up mid-run stops it with the reason', () async {
    final root = positionOf(kingAndPawn);
    final fill = fillWith(
      ScriptedEvaluator(failAt: afterUci(root, 'e2e4').fen),
    );
    await fill.start(request);
    expect(
      fill.state,
      isA<FillFailed>().having(
        (f) => f.reason,
        'reason',
        contains('could not score'),
      ),
    );
  });

  test('a draft name already taken gets the next number', () async {
    fixture.store.documents[draft()] = Opened('old', scriptedRevision('old'));
    final fill = fillWith(ScriptedEvaluator(scores: e4Best()));
    await fill.start(request);
    await fill.makeLines();
    expect((fill.lines as LinesWritten).draft, draft('Main (draft 2)'));
    expect(textOf(draft('Main (draft 2)')), contains('// Draft'));
    expect(textOf(draft()), 'old');
  });

  test(
    'lines that propose nothing new are a failure, not an empty draft',
    () async {
      // Horizon one: the best move is e4, which the chapter already plays.
      final fill = fillWith(ScriptedEvaluator(scores: e4Best()));
      await fill.start(const FillRequest(elo: 2200, depthPlies: 1));
      await fill.makeLines();
      expect(
        fill.lines,
        isA<LinesFailed>().having(
          (f) => f.reason,
          'reason',
          contains('already'),
        ),
      );
      expect(fixture.store.documents.keys, hasLength(1));
    },
  );

  test('a new search started while lines are written still leaves the '
      'draft on disk', () async {
    final fill = fillWith(ScriptedEvaluator(scores: e4Best()));
    await fill.start(request);
    final making = fill.makeLines();
    expect(await fill.start(request), isNull);
    await making;
    expect(fill.state, isA<FillDone>());
    expect(textOf(draft()), contains('// Draft'));
    expect(fill.canStart, isTrue);
  });

  test(
    'a store that refuses the draft is a failure named in the tab',
    () async {
      fixture.store.creates.add(const IoFailure('disk full'));
      final fill = fillWith(ScriptedEvaluator(scores: e4Best()));
      await fill.start(request);
      await fill.makeLines();
      expect(
        fill.lines,
        isA<LinesFailed>().having(
          (f) => f.reason,
          'reason',
          contains('disk full'),
        ),
      );
    },
  );

  test('a document this app may not write is searched but cannot become '
      'lines', () async {
    final readOnly = await openSession(chapter, readOnly: 'outside Documents');
    addTearDown(readOnly.dispose);
    final fill = FillGaps(
      session: readOnly.session,
      analysis: analysis,
      documents: readOnly.store,
      tools: (_) async => FillReady(
        evaluator: ScriptedEvaluator(),
        policy: const ScriptedPolicy({'e8d8': 1}),
        release: () async {},
      ),
    );
    addTearDown(fill.dispose);
    expect(fill.canStart, isTrue);
    expect(await fill.start(request), isNull);
    expect(fill.state, isA<FillDone>());
    expect(fill.canMakeLines, isFalse);
  });

  test('progress is the nodes and the depth of the run so far', () async {
    final fill = fillWith(ScriptedEvaluator());
    final seen = <FillRunning>[];
    fill.addListener(() {
      if (fill.state case final FillRunning running) seen.add(running);
    });
    await fill.start(request);
    expect(seen.first.of, 3);
    expect(seen.last.depth, 3);
    expect(seen.last.nodes, greaterThan(1));
  });

  test('the search starts from the board, not the chapter root', () async {
    fixture.session.forward();
    fixture.session.forward();
    final evaluator = ScriptedEvaluator();
    final fill = fillWith(evaluator);
    await fill.start(const FillRequest(elo: 2200, depthPlies: 1));
    final board = positionOf(fixture.session.fen.value);
    expect(evaluator.asked.first, board.fen);
    expect(
      fill.found!.at(const Fen(kingAndPawn), const ['e4', 'Kd8']),
      isA<OurNode>(),
    );
    // The lines are written from the chapter's root through the moves to
    // the board, so they can be dropped into the chapter.
    await fill.makeLines();
    expect(textOf(draft()), contains('1. e4 Kd8 2. '));
  });

  test('with no depth it goes on until asked to stop after a level, then '
      'keeps what it points out', () async {
    final store = FindsStore.inMemory();
    addTearDown(store.close);
    final finds = Finds(store: () => store);
    addTearDown(finds.dispose);
    final fill = fillWith(ScriptedEvaluator(scores: e4Best()), finds: finds);
    fill.addListener(() {
      if (fill.state case FillRunning(:final depth) when depth >= 2) {
        fill.finishLevel();
      }
    });

    await fill.start(const FillRequest(elo: 2200));

    final done = fill.state as FillDone;
    expect(done.complete, isFalse);
    expect(done.depth, 2, reason: 'the level under way was finished');
    expect(finds.recorded, isA<FindsKept>());
    finds.load();
    // Every find's line runs from the chapter's root through the board.
    for (final kept in finds.all) {
      expect(kept.rootFen, const Fen(kingAndPawn));
      expect(kept.side, Side.white);
    }
  });
}

/// Reports a failed acknowledgement after actually publishing the draft.
final class _LostCreate implements PgnDocumentStore {
  _LostCreate(this.inner);
  final ScriptedDocumentStore inner;
  final paths = <String>[];
  bool fail = true;
  @override
  Future<CreateResult> create(DocumentRef ref, String text) async {
    paths.add(ref.path);
    final result = await inner.create(ref, text);
    if (fail) {
      fail = false;
      return const IoFailure('lost creation acknowledgement');
    }
    return result;
  }

  @override
  Future<DocumentRead> open(DocumentRef ref) => inner.open(ref);
  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Decoder-shaped failure after the model port has successfully returned.
final class _BrokenWeights implements Map<String, double> {
  @override
  double? operator [](Object? key) => throw StateError('malformed weights');
  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
