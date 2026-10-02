import 'package:chess_auto_prep/chess/generation/draft_lines.dart'
    show continuationPlies;
import 'package:chess_auto_prep/chess/generation/eval.dart';
import 'package:chess_auto_prep/chess/generation/evaluation_source.dart';
import 'package:chess_auto_prep/chess/generation/legal_moves.dart';
import 'package:chess_auto_prep/chess/generation/sources.dart';
import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pv_text.dart';
import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/net/chessdb_moves.dart';
import 'package:chess_auto_prep/net/remote_queue.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/engine_jobs.dart';
import 'package:chess_auto_prep/workspace/fill_gaps.dart';
import 'package:chess_auto_prep/workspace/fill_states.dart';
import 'package:chess_auto_prep/workspace/opening_names.dart';
import 'package:dartchess/dartchess.dart' show Position;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

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

void main() {
  late SessionFixture fixture;
  late EngineAnalysis analysis;

  setUp(() async {
    fixture = await openSession(chapter);
    final engine = ScriptedEngine();
    analysis = EngineAnalysis(fixture.session, () async => Started(engine));
    await analysis.enable();
  });

  tearDown(() {
    analysis.dispose();
    fixture.dispose();
  });

  test('each drafted line goes on with the engine\'s best line from where '
      'the search left it, asked for when the run had none', () async {
    final scores = {afterUci(positionOf(kingAndPawn), 'e2e4').fen: -100};
    final continuations = _FirstLegalLine();
    var releases = 0;
    final fill = FillGaps(
      session: fixture.session,
      jobs: EngineJobs(analysis),
      documents: fixture.store,
      tools: (_) async => FillReady(
        evaluator: ScriptedEvaluator(scores: scores),
        policy: const ScriptedPolicy({'e8d8': 1}),
        continuations: continuations,
        release: () async => releases++,
      ),
      clock: () => DateTime(2026, 9, 22, 12),
    );
    addTearDown(fill.dispose);
    await fill.start(const FillRequest(elo: 2200, depthPlies: 3));
    await fill.makeLines();
    final written = fill.lines as LinesWritten;
    expect(continuations.asked, isNotEmpty);
    expect(releases, 2, reason: 'the engine is let go again after the ends');
    final text = switch (fixture.store.documents[written.draft]) {
      Opened(:final text) => text,
      _ => fail('the draft was not written'),
    };
    final draft = await readChapter(name: 'draft', text: text);
    final game = draft.treeInChapter(draft.lines.first)!;
    var node = game.children.first;
    final comments = <String?>[node.comment];
    while (node.children.isNotEmpty) {
      node = node.children.first;
      comments.add(node.comment);
    }
    expect(comments.first, contains('[%expectimax'));
    expect(
      comments.reversed.takeWhile((comment) => comment == null).length,
      continuationPlies,
    );
  });

  for (final (label, next, reusable) in const [
    (
      'same evaluation settings',
      FillRequest(elo: 2200, depthPlies: 3, evalDepth: 14),
      true,
    ),
    (
      'changed depth',
      FillRequest(elo: 2200, depthPlies: 3, evalDepth: 20),
      false,
    ),
    (
      'changed source',
      FillRequest(
        elo: 2200,
        depthPlies: 3,
        evalDepth: 14,
        source: EvaluationSource.lichess,
      ),
      false,
    ),
  ]) {
    test('draft continuations respect $label', () async {
      final first = _FirstLegalLine();
      final continuations = _FirstLegalLine();
      var useFirst = true;
      final fill = FillGaps(
        session: fixture.session,
        jobs: EngineJobs(analysis),
        documents: fixture.store,
        tools: (_) async => FillReady(
          evaluator: useFirst ? first : ScriptedEvaluator(),
          policy: const ScriptedPolicy({'e8d8': 1}),
          continuations: continuations,
          release: () async {},
        ),
      );
      addTearDown(fill.dispose);
      await fill.start(
        const FillRequest(elo: 2200, depthPlies: 3, evalDepth: 14),
      );
      expect(first.asked, isNotEmpty);
      useFirst = false;
      await fill.start(next);
      await fill.makeLines();
      expect(fill.lines, isA<LinesWritten>());
      expect(continuations.asked, reusable ? isEmpty : isNotEmpty);
    });
  }

  group('lines are not written for a chapter that has moved since the '
      'search', () {
    Future<FillGaps> searched({OpeningNames? openings}) async {
      final fill = FillGaps(
        session: fixture.session,
        jobs: EngineJobs(analysis),
        documents: fixture.store,
        openings: openings,
        tools: (_) async => FillReady(
          evaluator: ScriptedEvaluator(
            scores: {afterUci(positionOf(kingAndPawn), 'e2e4').fen: -100},
          ),
          policy: const ScriptedPolicy({'e8d8': 1}),
          release: () async {},
        ),
        clock: () => DateTime(2026, 9, 22, 12),
      );
      addTearDown(fill.dispose);
      await fill.start(const FillRequest(elo: 2200, depthPlies: 3));
      expect(fill.canMakeLines, isTrue);
      return fill;
    }

    void expectNoDraft() {
      expect(
        fixture.store.documents.keys.where(
          (ref) => ref.path.endsWith('(draft).pgn'),
        ),
        isEmpty,
      );
    }

    Future<void> renameFolder() async {
      final from = p.dirname(fixture.ref.path);
      final to = p.join(p.dirname(from), 'KID 1.e4');
      expect(await fixture.store.moveFolder(from, to), isA<FolderMoved>());
      fixture.session.relocated(
        ChapterRef.at(p.join(to, p.basename(fixture.ref.path))),
      );
    }

    test('its folder renamed while the lines were prepared', () async {
      final from = p.dirname(fixture.ref.path);
      final names = OpeningNames(() async {
        await renameFolder();
        return const [];
      });
      addTearDown(names.dispose);
      final fill = await searched(openings: names);
      await fill.makeLines();
      expect(fill.lines, isA<LinesFailed>());
      expect(
        fixture.store.documents.keys.where((ref) => p.isWithin(from, ref.path)),
        isEmpty,
        reason: 'the old folder is not made again',
      );
      expectNoDraft();
    });

    test('its folder renamed', () async {
      final fill = await searched();
      final from = p.dirname(fixture.ref.path);
      await renameFolder();
      await fill.makeLines();
      expect(fill.lines, isA<LinesFailed>());
      expect(
        fixture.store.documents.keys.where((ref) => p.isWithin(from, ref.path)),
        isEmpty,
        reason: 'the old folder is not made again',
      );
      expectNoDraft();
    });

    test('it moved to another folder', () async {
      final fill = await searched();
      final to = ChapterRef.at('/repertoires/Other/Main.pgn');
      expect(
        await fixture.store.move(
          fixture.ref,
          to,
          expected: scriptedRevision(chapter),
        ),
        isA<Moved>(),
      );
      fixture.session.relocated(to);
      await fill.makeLines();
      expect(fill.lines, isA<LinesFailed>());
      expectNoDraft();
    });
  });

  test('the ChessDB mainline book is built from ChessDB and the masters, '
      'with no engine, and becomes lines the same way', () async {
    String at(List<String> ucis) {
      var fen = const Fen(kingAndPawn);
      for (final uci in ucis) {
        fen = pvMoves(fen, [uci]).single.after;
      }
      return fen.position;
    }

    final book = {
      at([]): [(uci: 'e2e3', cp: 100)],
      at(['e2e3']): [(uci: 'e8d7', cp: -100), (uci: 'e8f7', cp: -120)],
      at(['e2e3', 'e8d7']): [(uci: 'e1d2', cp: 90)],
    };
    var built = 0;
    final fill = FillGaps(
      session: fixture.session,
      jobs: EngineJobs(analysis),
      documents: fixture.store,
      tools: (request) async {
        expect(request.method, SearchMethod.mainline);
        built++;
        return _bookOver((fen) => book[fen.position] ?? const []);
      },
      clock: () => DateTime(2026, 9, 22, 12),
    );
    addTearDown(fill.dispose);
    expect(
      await fill.start(
        const FillRequest(elo: 2200, method: SearchMethod.mainline),
      ),
      isNull,
    );
    expect(fill.state, isA<FillDone>());
    expect((fill.state as FillDone).complete, isTrue);
    await fill.makeLines();
    final written = fill.lines as LinesWritten;
    final text = switch (fixture.store.documents[written.draft]) {
      Opened(:final text) => text,
      _ => fail('the draft was not written'),
    };
    expect(text, contains('1. e3 '));
    expect(text, contains(' Kd7 '));
    expect(text, contains('2. Kd2 '));
    expect(built, 1, reason: 'no engine is asked to continue the book');
  });

  test('a mainline book ChessDB stops answering is kept and says so, not '
      'finished', () async {
    var asked = 0;
    final fill = FillGaps(
      session: fixture.session,
      jobs: EngineJobs(analysis),
      documents: fixture.store,
      tools: (_) async => _bookOver(
        (fen) => ++asked == 1 ? const [(uci: 'e2e3', cp: 100)] : null,
      ),
    );
    addTearDown(fill.dispose);
    await fill.start(
      const FillRequest(elo: 2200, method: SearchMethod.mainline),
    );
    final done = fill.state as FillDone;
    expect(done.sourceLost, isTrue);
    expect(done.budgetReached, isFalse);
    expect(done.complete, isFalse);
    expect(fill.found!.tree, isA<OurNode>(), reason: 'what it had is kept');
  });

  test('one position ChessDB does not answer leaves the book to resume, '
      'not stopped as an outage', () async {
    final fill = FillGaps(
      session: fixture.session,
      jobs: EngineJobs(analysis),
      documents: fixture.store,
      tools: (_) async => _bookOver(
        (fen) => const [(uci: 'e2e3', cp: 100)],
        missed: {
          pvMoves(const Fen(kingAndPawn), ['e2e3']).single.after.position,
        },
      ),
    );
    addTearDown(fill.dispose);
    await fill.start(
      const FillRequest(elo: 2200, method: SearchMethod.mainline),
    );
    final done = fill.state as FillDone;
    expect(done.complete, isFalse, reason: 'the missed position is to do');
    expect(done.sourceLost, isFalse, reason: 'one miss is not an outage');
    expect(done.budgetReached, isFalse);
    final after = (fill.found!.tree as OurNode).chosen.child;
    expect(after, isA<FrontierNode>());
  });

  test('a book run out of requests ends as the position budget, not as '
      'ChessDB going quiet', () async {
    final fill = FillGaps(
      session: fixture.session,
      jobs: EngineJobs(analysis),
      documents: fixture.store,
      tools: (_) async =>
          _bookOver((fen) => const [(uci: 'e2e3', cp: 100)], limit: 1),
    );
    addTearDown(fill.dispose);
    await fill.start(
      const FillRequest(elo: 2200, method: SearchMethod.mainline),
    );
    final done = fill.state as FillDone;
    expect(done.budgetReached, isTrue);
    expect(done.sourceLost, isFalse);
    expect(done.complete, isFalse);
  });
}

/// The mainline book's tools over a ChessDB that answers [movesAt] — null
/// for a server error, which drops the run — and no master games. A
/// position in [missed] is answered 404: one position not answered. The run
/// may ask [limit] questions.
BookReady _bookOver(
  List<({String uci, int cp})>? Function(Fen fen) movesAt, {
  Set<String> missed = const {},
  int limit = 1000,
}) => BookReady(
  chessDb: ChessDbMoves(
    RemoteQueue(
      MockClient((request) async {
        final board = Fen(request.url.queryParameters['board']!);
        if (missed.contains(board.position)) return http.Response('', 404);
        final moves = movesAt(board);
        if (moves == null) return http.Response('', 503);
        return http.Response(
          [for (final m in moves) 'move:${m.uci},score:${m.cp}'].join('|'),
          200,
        );
      }),
    ).run(limit: limit),
  ),
  practiceAt: (_) async => const [],
);

/// An engine whose best line is always the first legal move, again and
/// again: a real, legal line from any position.
final class _FirstLegalLine implements PositionEvaluator {
  final asked = <String>[];

  @override
  Future<EvaluationResult> evaluate(Position position) async {
    asked.add(position.fen);
    final pv = <String>[];
    var at = position;
    for (var i = 0; i < 8; i++) {
      final moves = legalMovesOf(at);
      if (moves.isEmpty) break;
      pv.add(moves.first.uci);
      at = at.play(moves.first.move);
    }
    return Evaluated(const Eval(0), depth: 14, pv: pv);
  }
}
