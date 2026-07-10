import 'package:flutter/foundation.dart';

import 'package:chess_auto_prep/models/tactics_position.dart';
import 'package:chess_auto_prep/models/tactics_session_settings.dart';
import 'package:chess_auto_prep/services/tactics/tactics_session_controller.dart';
import 'package:chess_auto_prep/services/tactics_database.dart';
import 'package:flutter_test/flutter_test.dart';

TacticsPosition _samplePosition({
  List<String> line = const ['e4'],
  int fullmove = 1,
}) {
  return TacticsPosition(
    fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 $fullmove',
    gameWhite: 'A',
    gameBlack: 'B',
    gameResult: '1-0',
    gameDate: '2024.01.01',
    gameId: 'g$fullmove',
    positionContext: 'Move 1 — White to play',
    userMove: 'd4',
    correctLine: line,
    mistakeType: '?',
    mistakeAnalysis: 'test',
  );
}

/// Fixed old fixture dates need the recency filter off.
const _allTime = TacticsSessionSettings(maxAgeDays: null);

/// Ignore delayed UI callbacks so assertions see immediate state.
void _noopSchedule(Duration _, VoidCallback __) {}

/// Execute callbacks immediately so we can test the full multi-move flow
/// synchronously.
void _immediateSchedule(Duration _, VoidCallback action) => action();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('processMoveAttempt accepts correct single-move tactic', () {
    final db = TacticsDatabase();
    db.positions.add(_samplePosition());
    final session = TacticsSessionController(database: db)..autoAdvance = false;
    session.selectPosition(db.positions.first);

    final update = session.processMoveAttempt(
      moveUci: 'e2e4',
      boardFen: db.positions.first.fen,
      schedule: _noopSchedule,
      isMounted: () => true,
    );

    expect(update?.applyMoveUci, 'e2e4');
    expect(session.positionSolved, isTrue);
    expect(session.feedback, 'Correct!');
  });

  test('processMoveAttempt rejects wrong move', () {
    final db = TacticsDatabase();
    db.positions.add(_samplePosition());
    final session = TacticsSessionController(database: db);
    session.selectPosition(db.positions.first);

    final update = session.processMoveAttempt(
      moveUci: 'd2d4',
      boardFen: db.positions.first.fen,
      schedule: _noopSchedule,
      isMounted: () => true,
    );

    expect(update?.applyMoveUci, 'd2d4');
    expect(session.feedback, 'Incorrect');
    expect(session.positionSolved, isFalse);
  });

  test('multi-move tactic: opponent auto-plays after correct user move', () {
    // 3-ply line from the starting position: user plays e4, opponent plays e5,
    // then user plays Nf3. correctLine = ['e4', 'e5', 'Nf3'].
    final db = TacticsDatabase();
    db.positions.add(_samplePosition(line: ['e4', 'e5', 'Nf3']));
    final session = TacticsSessionController(database: db)..autoAdvance = false;
    session.selectPosition(db.positions.first);

    final boardUpdates = <TacticsBoardUpdate>[];
    session.onBoardUpdate = boardUpdates.add;

    // --- Move 1: user plays e4 ---
    final update1 = session.processMoveAttempt(
      moveUci: 'e2e4',
      boardFen: db.positions.first.fen,
      schedule: _immediateSchedule,
      isMounted: () => true,
    );

    expect(update1?.applyMoveUci, 'e2e4', reason: 'user move applied');
    expect(session.positionSolved, isFalse,
        reason: 'not solved yet — opponent + user move remain');

    // The opponent reply (e5) should have been auto-played via onBoardUpdate.
    expect(boardUpdates, hasLength(1), reason: 'opponent auto-replied');
    final oppUpdate = boardUpdates.first;
    expect(oppUpdate.setFen, isNotNull, reason: 'opponent sets FEN');
    expect(oppUpdate.san, 'e5');

    // After opponent reply, it's the user's turn again (index 2).
    expect(session.currentMoveIndex, 2);
    expect(session.waitingForOpponent, isFalse);

    // --- Move 2: user plays Nf3 from the post-opponent FEN ---
    final update2 = session.processMoveAttempt(
      moveUci: 'g1f3',
      boardFen: session.currentTacticFen!,
      schedule: _immediateSchedule,
      isMounted: () => true,
    );

    expect(update2?.applyMoveUci, 'g1f3', reason: 'final user move applied');
    expect(session.positionSolved, isTrue, reason: 'tactic complete');
    expect(session.feedback, 'Correct!');
  });

  group('handleMoveAttempted routing', () {
    test('routes to onAnalysisMove in analysis mode', () {
      final db = TacticsDatabase();
      db.positions.add(_samplePosition());
      final session =
          TacticsSessionController(database: db)..autoAdvance = false;
      session.selectPosition(db.positions.first);

      String? analysisMove;
      final boardUpdates = <TacticsBoardUpdate>[];
      session.onAnalysisMove = (uci) => analysisMove = uci;
      session.onBoardUpdate = boardUpdates.add;

      session.handleMoveAttempted(
        moveUci: 'd2d4',
        boardFen: db.positions.first.fen,
        inAnalysisMode: true,
        schedule: _noopSchedule,
        isMounted: () => true,
      );

      expect(analysisMove, 'd2d4');
      expect(boardUpdates, isEmpty, reason: 'no puzzle validation ran');
      expect(session.feedback, isEmpty);
    });

    test('routes to onAnalysisMove after puzzle is solved', () {
      final db = TacticsDatabase();
      db.positions.add(_samplePosition());
      final session =
          TacticsSessionController(database: db)..autoAdvance = false;
      session.selectPosition(db.positions.first);
      session.positionSolved = true;

      String? analysisMove;
      session.onAnalysisMove = (uci) => analysisMove = uci;

      session.handleMoveAttempted(
        moveUci: 'd2d4',
        boardFen: db.positions.first.fen,
        inAnalysisMode: false,
        schedule: _noopSchedule,
        isMounted: () => true,
      );

      expect(analysisMove, 'd2d4');
    });

    test('validates move and fires board update + move-accepted callback', () {
      final db = TacticsDatabase();
      db.positions.add(_samplePosition());
      final session =
          TacticsSessionController(database: db)..autoAdvance = false;
      session.selectPosition(db.positions.first);

      final boardUpdates = <TacticsBoardUpdate>[];
      var moveAccepted = false;
      session.onBoardUpdate = boardUpdates.add;
      session.onUserMoveAccepted = () => moveAccepted = true;

      session.handleMoveAttempted(
        moveUci: 'e2e4',
        boardFen: db.positions.first.fen,
        inAnalysisMode: false,
        schedule: _noopSchedule,
        isMounted: () => true,
      );

      expect(boardUpdates, hasLength(1));
      expect(boardUpdates.first.applyMoveUci, 'e2e4');
      expect(moveAccepted, isTrue, reason: 'correct move advanced the line');
      expect(session.positionSolved, isTrue);
    });

    test('incorrect move fires board update but not move-accepted', () {
      final db = TacticsDatabase();
      db.positions.add(_samplePosition());
      final session =
          TacticsSessionController(database: db)..autoAdvance = false;
      session.selectPosition(db.positions.first);

      final boardUpdates = <TacticsBoardUpdate>[];
      var moveAccepted = false;
      session.onBoardUpdate = boardUpdates.add;
      session.onUserMoveAccepted = () => moveAccepted = true;

      session.handleMoveAttempted(
        moveUci: 'd2d4',
        boardFen: db.positions.first.fen,
        inAnalysisMode: false,
        schedule: _noopSchedule,
        isMounted: () => true,
      );

      expect(boardUpdates.first.applyMoveUci, 'd2d4',
          reason: 'wrong move still shown before reset');
      expect(moveAccepted, isFalse);
      expect(session.feedback, 'Incorrect');
    });

    test('does nothing without an active position', () {
      final session = TacticsSessionController(database: TacticsDatabase());
      String? analysisMove;
      session.onAnalysisMove = (uci) => analysisMove = uci;

      session.handleMoveAttempted(
        moveUci: 'e2e4',
        boardFen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        inAnalysisMode: true,
        schedule: _noopSchedule,
        isMounted: () => true,
      );

      expect(analysisMove, isNull);
    });
  });

  group('session outcomes and recap', () {
    void solve(TacticsSessionController session) {
      session.processMoveAttempt(
        moveUci: 'e2e4',
        boardFen: session.currentTacticFen!,
        schedule: _noopSchedule,
        isMounted: () => true,
      );
    }

    void fail(TacticsSessionController session) {
      session.processMoveAttempt(
        moveUci: 'd2d4',
        boardFen: session.currentTacticFen!,
        schedule: _noopSchedule,
        isMounted: () => true,
      );
    }

    test('per-puzzle outcomes feed the recap and the retry list', () {
      final db = TacticsDatabase();
      db.positions.add(_samplePosition(fullmove: 1));
      db.positions.add(_samplePosition(fullmove: 2));
      final session =
          TacticsSessionController(database: db)..autoAdvance = false;

      expect(session.startSession(_allTime), isNotNull);
      solve(session);
      final solvedFen = session.currentPosition!.fen;

      expect(session.skipPosition(), isNotNull);
      fail(session);
      final failedFen = session.currentPosition!.fen;

      expect(session.skipPosition(), isNull, reason: 'queue exhausted');
      expect(session.outcomeCount(SessionPuzzleOutcome.correct), 1);
      expect(session.outcomeCount(SessionPuzzleOutcome.incorrect), 1);
      expect(session.outcomeCount(SessionPuzzleOutcome.unattempted), 0);
      expect(session.sessionOutcomes[solvedFen], SessionPuzzleOutcome.correct);
      expect(session.sessionMistakes.map((p) => p.fen), [failedFen]);
    });

    test('the first outcome wins: solving after a failure stays a failure',
        () {
      final db = TacticsDatabase();
      db.positions.add(_samplePosition());
      final session =
          TacticsSessionController(database: db)..autoAdvance = false;

      session.startSession(_allTime);
      fail(session);
      solve(session);

      expect(session.sessionOutcomes[session.currentPosition!.fen],
          SessionPuzzleOutcome.incorrect);
      expect(session.sessionMistakes, hasLength(1));
    });

    test('a puzzle navigated past without an attempt counts as unattempted',
        () {
      final db = TacticsDatabase();
      db.positions.add(_samplePosition(fullmove: 1));
      db.positions.add(_samplePosition(fullmove: 2));
      final session =
          TacticsSessionController(database: db)..autoAdvance = false;

      session.startSession(_allTime);
      expect(session.skipPosition(), isNotNull);
      expect(session.skipPosition(), isNull);

      expect(session.outcomeCount(SessionPuzzleOutcome.unattempted), 2);
      expect(session.sessionMistakes, hasLength(2));
    });

    test('startRetrySession queues the mistakes and resets outcomes', () {
      final db = TacticsDatabase();
      db.positions.add(_samplePosition(fullmove: 1));
      db.positions.add(_samplePosition(fullmove: 2));
      final session =
          TacticsSessionController(database: db)..autoAdvance = false;

      session.startSession(_allTime);
      fail(session);
      final failedFen = session.currentPosition!.fen;
      session.skipPosition();
      solve(session);
      session.skipPosition();

      final setup = session.startRetrySession(session.sessionMistakes);
      expect(setup, isNotNull);
      expect(db.sessionQueueLength, 1);
      expect(session.currentPosition!.fen, failedFen);
      expect(session.sessionOutcomes,
          {failedFen: SessionPuzzleOutcome.unattempted});
    });

    test('auto-advance past the last puzzle fires onSessionCompleted', () {
      final db = TacticsDatabase();
      db.positions.add(_samplePosition());
      final session = TacticsSessionController(database: db);
      var completed = false;
      session.onSessionCompleted = () => completed = true;

      session.startSession(_allTime);
      session.processMoveAttempt(
        moveUci: 'e2e4',
        boardFen: session.currentTacticFen!,
        schedule: _immediateSchedule,
        isMounted: () => true,
      );

      expect(completed, isTrue);
    });
  });

  test('multi-move tactic: currentTacticFen tracks board through all plies',
      () {
    // 5-ply line: e4, e5, Nf3, Nc6, Bb5.
    final db = TacticsDatabase();
    db.positions.add(_samplePosition(line: ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5']));
    final session = TacticsSessionController(database: db)..autoAdvance = false;
    session.selectPosition(db.positions.first);
    session.onBoardUpdate = (_) {};

    final startFen = db.positions.first.fen;

    // User plays e4 → opponent e5 auto-plays.
    session.processMoveAttempt(
      moveUci: 'e2e4',
      boardFen: startFen,
      schedule: _immediateSchedule,
      isMounted: () => true,
    );
    expect(session.currentMoveIndex, 2);
    final fenAfterE5 = session.currentTacticFen!;
    expect(fenAfterE5, isNot(startFen),
        reason: 'FEN advanced past initial position');

    // User plays Nf3 → opponent Nc6 auto-plays.
    session.processMoveAttempt(
      moveUci: 'g1f3',
      boardFen: fenAfterE5,
      schedule: _immediateSchedule,
      isMounted: () => true,
    );
    expect(session.currentMoveIndex, 4);
    final fenAfterNc6 = session.currentTacticFen!;
    expect(fenAfterNc6, isNot(fenAfterE5),
        reason: 'FEN advanced again after second pair');

    // User plays Bb5 → tactic complete.
    session.processMoveAttempt(
      moveUci: 'f1b5',
      boardFen: fenAfterNc6,
      schedule: _immediateSchedule,
      isMounted: () => true,
    );
    expect(session.positionSolved, isTrue);
    expect(session.currentMoveIndex, 5);
  });

  group('play source (session vs browse)', () {
    TacticsDatabase threePositions() {
      final db = TacticsDatabase();
      db.positions.addAll([
        _samplePosition(fullmove: 1),
        _samplePosition(fullmove: 2),
        _samplePosition(fullmove: 3),
      ]);
      return db;
    }

    test('startSession/selectPosition/endSession set playSource', () {
      final db = threePositions();
      final session = TacticsSessionController(database: db);

      expect(session.playSource, TacticsPlaySource.none);
      session.startSession(_allTime);
      expect(session.playSource, TacticsPlaySource.session);
      session.endSession();
      expect(session.playSource, TacticsPlaySource.none);
      session.selectPosition(db.positions.first);
      expect(session.playSource, TacticsPlaySource.browse);
    });

    test('browse: previous/next walk the given queue in order', () {
      final db = threePositions();
      final session = TacticsSessionController(database: db);
      // Queue in reversed order, starting from the middle item.
      final queue = db.positions.reversed.toList();
      session.selectPosition(queue[1], browseQueue: queue);
      expect(session.currentPosition!.fen, queue[1].fen);

      expect(session.skipPosition()!.fen, queue[2].fen);
      expect(session.skipPosition(), isNull,
          reason: 'walking past the end returns to the browse list');

      session.selectPosition(queue[1], browseQueue: queue);
      expect(session.previousPosition()!.fen, queue[0].fen);
      expect(session.previousPosition(), isNull,
          reason: 'walking past the start returns to the browse list');
    });

    test('browse play never touches session outcomes', () {
      final db = threePositions();
      final session = TacticsSessionController(database: db)
        ..autoAdvance = false;
      session.selectPosition(db.positions.first);
      session.processMoveAttempt(
        moveUci: 'e2e4',
        boardFen: db.positions.first.fen,
        schedule: _noopSchedule,
        isMounted: () => true,
      );
      expect(session.positionSolved, isTrue);
      expect(session.sessionOutcomes, isEmpty);
    });

    test('edit is locked at the unsolved session head, open elsewhere', () {
      final db = threePositions();
      final session = TacticsSessionController(database: db)
        ..autoAdvance = false;

      session.startSession(_allTime);
      expect(session.canEditCurrent, isFalse,
          reason: 'unsolved head of the session — editing reveals the answer');

      session.showSolution = true;
      expect(session.canEditCurrent, isTrue, reason: 'answer already shown');
      session.showSolution = false;

      session.skipPosition();
      expect(session.canEditCurrent, isFalse, reason: 'new unsolved head');

      session.previousPosition();
      expect(session.canEditCurrent, isTrue,
          reason: 'revisiting an already-seen puzzle');

      session.skipPosition();
      expect(session.canEditCurrent, isFalse,
          reason: 'back at the furthest, still-unsolved puzzle');

      session.endSession();
      session.selectPosition(db.positions.first);
      expect(session.canEditCurrent, isTrue,
          reason: 'browse-launched play is always editable');
    });

    test('hasPrevious/hasNext gray the ends of the queue', () {
      final db = threePositions();
      final session = TacticsSessionController(database: db)
        ..autoAdvance = false;

      expect(session.hasPrevious, isFalse, reason: 'nothing loaded');
      expect(session.hasNext, isFalse, reason: 'nothing loaded');

      session.startSession(_allTime);
      expect(session.hasPrevious, isFalse, reason: 'first session puzzle');
      expect(session.hasNext, isTrue);
      expect(session.isAtLastSessionPuzzle, isFalse);

      session.skipPosition();
      session.skipPosition();
      expect(session.hasPrevious, isTrue);
      expect(session.hasNext, isTrue,
          reason: 'Next on the last session puzzle finishes the session');
      expect(session.isAtLastSessionPuzzle, isTrue);

      session.endSession();
      final queue = db.positions.toList();
      session.selectPosition(queue.first, browseQueue: queue);
      expect(session.hasPrevious, isFalse, reason: 'first browse item');
      expect(session.hasNext, isTrue);
      expect(session.isAtLastSessionPuzzle, isFalse,
          reason: 'browse walks are not sessions');

      session.skipPosition();
      session.skipPosition();
      expect(session.hasPrevious, isTrue);
      expect(session.hasNext, isFalse, reason: 'last browse item');
    });

    test('reloadCurrentPosition preserves the play source', () {
      final db = threePositions();
      final session = TacticsSessionController(database: db);

      session.startSession(_allTime);
      session.reloadCurrentPosition(session.currentPosition!);
      expect(session.playSource, TacticsPlaySource.session);

      session.endSession();
      final queue = db.positions.toList();
      session.selectPosition(queue[0], browseQueue: queue);
      final edited = queue[0];
      session.reloadCurrentPosition(edited);
      expect(session.playSource, TacticsPlaySource.browse);
      expect(session.skipPosition()!.fen, queue[1].fen,
          reason: 'browse queue still walkable after an in-place edit');
    });
  });
}
