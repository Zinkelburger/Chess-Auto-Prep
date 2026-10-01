import 'dart:async';
import 'dart:convert';

import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:chess_auto_prep/chess/generation/sources.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/storage/finds_store.dart';
import 'package:chess_auto_prep/storage/generation_trees.dart';
import 'package:chess_auto_prep/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/engine_jobs.dart';
import 'package:chess_auto_prep/workspace/fill_gaps.dart';
import 'package:chess_auto_prep/workspace/fill_states.dart';
import 'package:chess_auto_prep/workspace/finds.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chess/generation/scripted_sources.dart';
import '../support/scripted_engine.dart';
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

/// Resume goes on from a search kept in memory or saved beside the chapter,
/// and only from one this board and these settings can use.
void main() {
  late SessionFixture fixture;
  late EngineAnalysis analysis;
  late EngineJobs jobs;

  const request = FillRequest(elo: 2200, depthPlies: 3);

  setUp(() async {
    fixture = await openSession(chapter);
    analysis = EngineAnalysis(
      fixture.session,
      () async => Started(ScriptedEngine()),
    );
    jobs = EngineJobs(analysis);
    await analysis.enable();
  });

  tearDown(() {
    analysis.dispose();
    fixture.dispose();
  });

  FillGaps fillWith(
    PositionEvaluator evaluator, {
    TreeKeeper? keepTree,
    TreeLoader? loadTree,
    Finds? finds,
    FillToolsFactory? tools,
  }) {
    final fill = FillGaps(
      session: fixture.session,
      jobs: jobs,
      documents: fixture.store,
      tools:
          tools ??
          (_) async => FillReady(
            evaluator: evaluator,
            policy: const ScriptedPolicy({'e8d8': 1}),
            release: () async {},
          ),
      keepTree: keepTree,
      loadTree: loadTree,
      finds: finds,
      clock: () => DateTime(2026, 9, 22, 12),
    );
    addTearDown(fill.dispose);
    return fill;
  }

  test(
    'a new owner resumes saved work at a greater depth without rescoring it',
    () async {
      String? saved;
      final first = fillWith(
        ScriptedEvaluator(),
        keepTree: (_, text, {required runId}) async {
          saved = text;
        },
      );
      await first.start(const FillRequest(elo: 2200, depthPlies: 1));
      final prior = first.found!.tree as OurNode;
      final evaluator = ScriptedEvaluator();
      final restarted = fillWith(
        evaluator,
        loadTree: (_, _) => Stream.value(saved!),
      );
      expect(
        await restarted.resume(const FillRequest(elo: 2200, depthPlies: 2)),
        isNull,
      );
      expect(restarted.state, isA<FillDone>());
      expect(evaluator.asked, isNot(contains(prior.fen.value)));
      for (final move in prior.candidates) {
        expect(evaluator.asked, isNot(contains(move.child.fen.value)));
      }
      expect(
        (restarted.found!.tree as OurNode).candidates.first.child,
        isA<OpponentNode>(),
      );
    },
  );

  test(
    'candidate count and reply coverage govern and survive the saved search',
    () async {
      String? saved;
      final fill = fillWith(
        ScriptedEvaluator(),
        keepTree: (_, text, {required runId}) async {
          saved = text;
        },
      );
      const custom = FillRequest(
        elo: 1800,
        depthPlies: 3,
        rootMoves: 2,
        candidateMoves: 1,
        replyFloor: 0.02,
      );
      await fill.start(custom);
      final root = fill.found!.tree as OurNode;
      expect(root.candidates, hasLength(2), reason: 'root moves');
      for (final candidate in root.candidates) {
        for (final reply in (candidate.child as OpponentNode).replies) {
          expect((reply.child as OurNode).candidates, hasLength(1));
        }
      }
      final config = (jsonDecode(saved!) as Map)['config'] as Map;
      expect(config['v2_max_our_moves'], 1);
      expect(config['v2_root_moves'], 2);
      expect(config['v2_reply_floor'], 0.02);
      final restarted = fillWith(
        ScriptedEvaluator(),
        loadTree: (_, _) => Stream.value(saved!),
      );
      expect(await restarted.resume(custom), isNull);
      expect(restarted.state, isA<FillDone>());
    },
  );

  test(
    'saved searches with every legal move at the root are refused',
    () async {
      String? saved;
      final first = fillWith(
        ScriptedEvaluator(),
        keepTree: (_, text, {required runId}) async {
          saved = text;
        },
      );
      await first.start(request);
      final json = jsonDecode(saved!) as Map<String, Object?>;
      (json['config'] as Map).remove('v2_root_moves');
      final restarted = fillWith(
        ScriptedEvaluator(),
        loadTree: (_, _) => Stream.value(jsonEncode(json)),
      );
      expect(
        await restarted.resume(request),
        'The saved search uses different search settings or side.',
      );
    },
  );

  test('saved searches refuse a changed opponent rating', () async {
    String? saved;
    final first = fillWith(
      ScriptedEvaluator(),
      keepTree: (_, text, {required runId}) async {
        saved = text;
      },
    );
    await first.start(const FillRequest(elo: 2200, depthPlies: 1));
    final restarted = fillWith(
      ScriptedEvaluator(),
      loadTree: (_, _) => Stream.value(saved!),
    );
    expect(
      await restarted.resume(const FillRequest(elo: 1800, depthPlies: 2)),
      contains('original opponent rating'),
    );
    expect(restarted.state, isA<FillIdle>());
  });

  test('saved searches refuse a changed reply source', () async {
    String? saved;
    final first = fillWith(
      ScriptedEvaluator(),
      keepTree: (_, text, {required runId}) async {
        saved = text;
      },
    );
    const masters = FillRequest(
      elo: 2200,
      depthPlies: 1,
      replies: ReplySource.masters,
      fallbackUnder: 10,
    );
    await first.start(masters);
    expect(saved, contains('"v2_reply_source": "masters+maia<10"'));
    expect(saved, contains('"maia_only": false'));
    for (final other in const [
      FillRequest(elo: 2200, depthPlies: 2),
      FillRequest(elo: 2200, depthPlies: 2, replies: ReplySource.masters),
    ]) {
      final restarted = fillWith(
        ScriptedEvaluator(),
        loadTree: (_, _) => Stream.value(saved!),
      );
      expect(
        await restarted.resume(other),
        'Choose the reply source used by this saved search.',
      );
    }
    final same = fillWith(
      ScriptedEvaluator(),
      loadTree: (_, _) => Stream.value(saved!),
    );
    expect(
      await same.resume(
        const FillRequest(
          elo: 2200,
          depthPlies: 2,
          replies: ReplySource.masters,
          fallbackUnder: 10,
        ),
      ),
      isNull,
    );
  });

  group('resume passes over newer saved searches it cannot use', () {
    Future<String> savedAt(int elo) async {
      String? saved;
      final fill = fillWith(
        ScriptedEvaluator(),
        keepTree: (_, text, {required runId}) async {
          saved = text;
        },
      );
      await fill.start(FillRequest(elo: elo, depthPlies: 1));
      return saved!;
    }

    test('an older tree at this rating is used', () async {
      final newer = await savedAt(2000);
      final older = await savedAt(1800);
      final prior = (jsonDecode(older) as Map)['tree'] as Map;
      final evaluator = ScriptedEvaluator();
      final restarted = fillWith(
        evaluator,
        loadTree: (_, _) => Stream.fromIterable([newer, older]),
      );
      expect(
        await restarted.resume(const FillRequest(elo: 1800, depthPlies: 2)),
        isNull,
      );
      expect(restarted.state, isA<FillDone>());
      expect(evaluator.asked, isNot(contains(prior['fen'])));
    });

    test('with none usable the newest refusal is said', () async {
      final newer = jsonDecode(await savedAt(1800)) as Map<String, Object?>;
      newer['v2_evaluation_source'] = 'elsewhere';
      final older = await savedAt(2000);
      final restarted = fillWith(
        ScriptedEvaluator(),
        loadTree: (_, _) => Stream.fromIterable([jsonEncode(newer), older]),
      );
      expect(
        await restarted.resume(const FillRequest(elo: 1800, depthPlies: 2)),
        'Choose the evaluation source used by this saved search.',
      );
      expect(restarted.state, isA<FillIdle>());
    });

    test('a malformed newest tree falls through to an older one', () async {
      final older = await savedAt(1800);
      final restarted = fillWith(
        ScriptedEvaluator(),
        loadTree: (_, _) => Stream.fromIterable(['{"tree": ', older]),
      );
      expect(
        await restarted.resume(const FillRequest(elo: 1800, depthPlies: 2)),
        isNull,
      );
      expect(restarted.state, isA<FillDone>());
    });

    test('no saved tree at the board says so', () async {
      final restarted = fillWith(
        ScriptedEvaluator(),
        loadTree: (_, _) => const Stream.empty(),
      );
      expect(
        await restarted.resume(request),
        'No saved search starts at this board position.',
      );
    });

    test('the Expectimax button searches afresh when there is nothing to '
        'continue, or only a search of other settings', () async {
      final other = await savedAt(2000);
      final restarted = fillWith(
        ScriptedEvaluator(),
        loadTree: (_, _) => Stream.value(other),
      );
      expect(
        await restarted.resume(
          const FillRequest(elo: 1800, depthPlies: 1),
          orAfresh: true,
        ),
        isNull,
      );
      expect(restarted.state, isA<FillDone>());
      expect(restarted.found!.request.elo, 1800);
    });
  });

  test('a board flipped while a saved search decodes starts no search for '
      'the other side', () async {
    String? saved;
    final first = fillWith(
      ScriptedEvaluator(),
      keepTree: (_, text, {required runId}) async {
        saved = text;
      },
    );
    await first.start(const FillRequest(elo: 2200, depthPlies: 1));
    final store = FindsStore.inMemory();
    addTearDown(store.close);
    final finds = Finds(store: () => store);
    addTearDown(finds.dispose);
    var toolsTaken = 0;
    final restarted = fillWith(
      ScriptedEvaluator(),
      finds: finds,
      // The flip lands after the tree is delivered, while it decodes.
      loadTree: (_, _) async* {
        Timer.run(fixture.session.flip);
        yield saved!;
      },
      tools: (_) async {
        toolsTaken++;
        return FillReady(
          evaluator: ScriptedEvaluator(),
          policy: const ScriptedPolicy({'e8d8': 1}),
          release: () async {},
        );
      },
    );
    expect(
      await restarted.resume(const FillRequest(elo: 2200, depthPlies: 2)),
      'The board changed while loading the search.',
    );
    expect(restarted.state, isA<FillIdle>());
    expect(toolsTaken, 0);
    expect(store.all(), isEmpty);
  });
}
