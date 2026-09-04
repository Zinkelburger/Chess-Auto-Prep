import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/core/pgn/pgn_viewer_handle.dart';
import 'package:chess_auto_prep/core/pgn/solitaire_controller.dart';
import 'package:chess_auto_prep/core/pgn/solitaire_script.dart' as scripts;
import 'package:chess_auto_prep/core/pgn/viewer_game_model.dart';
import 'package:chess_auto_prep/core/pgn/viewer_solitaire_session.dart';
import 'package:chess_auto_prep/models/move_tree.dart';

/// A handle over a real [ViewerGameModel], recording what the session asks of
/// the board so each test can assert on the commands rather than on a live
/// widget.
class _FakeHandle implements PgnViewerHandle {
  _FakeHandle(String movetext) {
    model.load(PgnGame.parsePgn('[Event "?"]\n\n$movetext'));
  }

  final model = ViewerGameModel();

  final List<String> ephemeralMoves = [];
  final List<String> variationMoves = [];
  final List<int> jumpedToIndices = [];
  final List<String> jumpedToNodes = [];
  Map<int, String>? guessAnnotations;
  Map<int, List<String>>? guessVariations;
  Map<int, String>? nodeAnnotations;
  Map<int, List<String>>? nodeVariations;
  int clearEphemeralCount = 0;
  SolitaireReveal? reveal;

  /// Pretend the reader wandered off the mainline.
  bool forceInVariation = false;

  @override
  List<String> get mainLineMoves =>
      model.moveHistory.map((m) => m.san).toList();

  @override
  int get mainLineIndex => model.mainLineIndex;

  @override
  int get mainLineLength => model.moveHistory.length;

  @override
  bool get inVariation => forceInVariation || model.analysisPath.isNotEmpty;

  @override
  int? get currentVariationNodeId =>
      model.analysisPath.isEmpty ? null : model.analysisPath.last.id;

  @override
  bool get hasSavedSidelines => model.variationsByPly.values.any(
    (roots) => roots.any((r) => !r.isEphemeral),
  );

  @override
  String? get currentFen => model.currentPosition.fen;

  @override
  void addEphemeralMove(String san) => ephemeralMoves.add(san);

  @override
  void recordVariationMove(String san) {
    variationMoves.add(san);
    model.recordVariationMove(san);
  }

  @override
  void clearEphemeralMoves() => clearEphemeralCount++;

  @override
  void goToMainLineIndex(int moveIndex) {
    jumpedToIndices.add(moveIndex);
    model.goToMainLineMove(moveIndex);
  }

  @override
  void goToVariationNode(MoveNode node, int branchPly) {
    jumpedToNodes.add(node.san);
    model.goToAnalysisNode(node, branchPly);
  }

  @override
  scripts.SolitaireScript? buildSolitaireScript({
    required int fromMainlinePly,
    required bool includeVariations,
  }) => scripts.buildSolitaireScript(
    model,
    fromMainlinePly: fromMainlinePly,
    includeVariations: includeVariations,
  );

  @override
  void setSolitaireReveal(SolitaireReveal? r) {
    reveal = r;
    model.reveal = r;
  }

  @override
  void addGuessAnnotations(Map<int, String> notes) => guessAnnotations = notes;

  @override
  void addGuessNodeAnnotations(Map<int, String> notes) =>
      nodeAnnotations = notes;

  @override
  void addGuessVariations(Map<int, List<String>> wrongByPly) =>
      guessVariations = wrongByPly;

  @override
  void addGuessNodeVariations(Map<int, List<String>> wrongByParentId) =>
      nodeVariations = wrongByParentId;

  @override
  void goBack() {}
  @override
  void goForward() {}
  @override
  void jumpToMove(int moveNumber, bool isWhiteToPlay) {}
}

/// Builds a session over [movetext] with adjustable surroundings.
({
  ViewerSolitaireSession session,
  _FakeHandle handle,
  void Function(bool) setHasGames,
  void Function(bool) setBottomIsWhite,
  int Function() changeCount,
})
_build({
  String movetext = '1. e4 e5 2. Nf3 *',
  bool hasGames = true,
  int revealDelaySec = 0,
}) {
  final handle = _FakeHandle(movetext);
  var games = hasGames;
  var bottomIsWhite = true;
  var changes = 0;
  final session = ViewerSolitaireSession(
    handle: handle,
    hasGames: () => games,
    userPlaysWhite: () => bottomIsWhite,
    stopAutoPlay: () {},
    onChanged: () => changes++,
  );
  session.controller.revealDelaySec = revealDelaySec;
  return (
    session: session,
    handle: handle,
    setHasGames: (v) => games = v,
    setBottomIsWhite: (v) => bottomIsWhite = v,
    changeCount: () => changes,
  );
}

/// Open setup and start with its defaults.
void _startDefault(ViewerSolitaireSession s) {
  s.beginSetup();
  s.begin();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('setup', () {
    test('the toolbar toggle opens setup rather than starting at once', () {
      final f = _build();
      f.session.toggle();
      expect(f.session.isConfiguring, isTrue);
      expect(f.session.isActive, isFalse);
      expect(f.handle.reveal, isNull, reason: 'nothing is hidden yet');
    });

    test('defaults: the side at the bottom of the board, from the start', () {
      final f = _build();
      f.setBottomIsWhite(false);
      f.session.beginSetup();
      final setup = f.session.setup!;
      expect(setup.userIsWhite, isFalse);
      expect(setup.fromCurrentMove, isFalse);
      expect(setup.canStartHere, isFalse, reason: 'cursor is at the start');
      expect(setup.hasSidelines, isFalse);
    });

    test(
      '"from here" is offered mid-game, labelled with the move already played',
      () {
        final f = _build(movetext: '1. e4 e5 2. Nf3 Nc6 *');
        f.handle.goToMainLineIndex(3);
        f.session.beginSetup();
        final setup = f.session.setup!;
        expect(setup.canStartHere, isTrue);
        expect(setup.currentMainlinePly, 3);
        expect(setup.startHereLabel, 'after 2.Nf3');
      },
    );

    test('"from here" is not offered inside a sideline or at the end', () {
      final f = _build(movetext: '1. e4 e5 (1... c5) 2. Nf3 *');
      f.handle.goToMainLineIndex(3);
      f.session.beginSetup();
      expect(f.session.setup!.canStartHere, isFalse);
      f.session.cancelSetup();

      f.handle.goToMainLineIndex(1);
      f.handle.goToVariationNode(f.handle.model.variationsByPly[1]!.first, 1);
      f.session.beginSetup();
      expect(f.session.setup!.canStartHere, isFalse);
    });

    test('the variations option appears only when there are sidelines', () {
      final f = _build(movetext: '1. e4 e5 (1... c5) 2. Nf3 *');
      f.session.beginSetup();
      expect(f.session.setup!.hasSidelines, isTrue);
    });

    test('refuses to open with no game loaded', () {
      final f = _build(hasGames: false);
      f.session.toggle();
      expect(f.session.isConfiguring, isFalse);
    });

    test(
      'toggling again closes setup; toggling a running session stops it',
      () {
        final f = _build();
        f.session.toggle();
        f.session.toggle();
        expect(f.session.isConfiguring, isFalse);

        _startDefault(f.session);
        expect(f.session.isActive, isTrue);
        f.session.toggle();
        expect(f.session.isActive, isFalse);
        expect(f.handle.reveal, isNull, reason: 'the movetext is unhidden');
      },
    );
  });

  group('starting a session', () {
    test('rewinds the board, clears analysis moves and hides the game', () {
      final f = _build();
      f.handle.goToMainLineIndex(2);
      f.handle.jumpedToIndices.clear();

      _startDefault(f.session);

      expect(f.session.isActive, isTrue);
      expect(
        f.handle.clearEphemeralCount,
        1,
        reason: 'stale analysis lines must not survive into a guessing run',
      );
      expect(f.handle.reveal?.mainlinePly, 0);
      expect(f.handle.mainLineIndex, 0);
    });

    test('the chosen side wins over the board orientation', () {
      final f = _build();
      f.session.beginSetup();
      f.session.updateSetup(userIsWhite: false);
      f.session.begin();
      expect(f.session.controller.userIsWhite, isFalse);
    });

    test('"from here" keeps the earlier moves visible and asks from there', () {
      final f = _build(movetext: '1. e4 e5 2. Nf3 Nc6 *');
      f.handle.goToMainLineIndex(2);
      f.session.beginSetup();
      f.session.updateSetup(fromCurrentMove: true);
      f.session.begin();

      expect(f.handle.reveal?.mainlinePly, 2);
      expect(f.session.controller.currentStep?.mainlinePly, 2);
      expect(f.handle.mainLineIndex, 2);
    });

    test('flipping the board mid-session does not change the side', () {
      final f = _build();
      _startDefault(f.session);
      f.setBottomIsWhite(false);
      expect(f.session.controller.userIsWhite, isTrue);
      expect(f.session.isActive, isTrue);
    });

    test('a new game restarts with the side read from the board again', () {
      final f = _build();
      _startDefault(f.session);
      f.setBottomIsWhite(false);
      f.handle.jumpedToIndices.clear();

      f.session.restartForNewGame();

      expect(f.session.controller.userIsWhite, isFalse);
      expect(f.handle.jumpedToIndices, contains(0));
    });
  });

  group('routing a board move', () {
    test('a move at the frontier is judged as a guess', () {
      final f = _build();
      _startDefault(f.session);

      f.session.handleBoardMove('e4');

      expect(
        f.handle.ephemeralMoves,
        isEmpty,
        reason: 'a guess at the frontier is not exploratory analysis',
      );
      expect(f.handle.reveal?.mainlinePly, 1);
      expect(f.handle.mainLineIndex, 1, reason: 'the board shows the move');
    });

    test('a wrong guess is recorded as a live variation', () {
      final f = _build();
      _startDefault(f.session);

      f.session.handleBoardMove('d4');

      expect(f.handle.variationMoves, ['d4']);
      expect(f.session.controller.currentAttempts, 1);
    });

    test('a move inside a variation is exploratory, never a guess', () {
      final f = _build();
      _startDefault(f.session);
      f.handle.forceInVariation = true;

      f.session.handleBoardMove('e4');

      expect(f.handle.ephemeralMoves, ['e4']);
      expect(f.handle.variationMoves, isEmpty);
    });

    test('a move behind the frontier is exploratory, never a guess', () {
      final f = _build(movetext: '1. e4 e5 2. Nf3 Nc6 *');
      f.handle.goToMainLineIndex(2);
      f.session.beginSetup();
      f.session.updateSetup(fromCurrentMove: true);
      f.session.begin();
      // Browsing back into the already-revealed region.
      f.handle.goToMainLineIndex(0);

      f.session.handleBoardMove('e4');

      expect(f.handle.ephemeralMoves, ['e4']);
      expect(f.handle.variationMoves, isEmpty);
    });
  });

  group('hints', () {
    test('a hint names the square of the piece that moves', () {
      final f = _build();
      _startDefault(f.session);
      expect(f.session.controller.canHint, isTrue);

      f.session.hintCurrentMove();

      expect(f.session.controller.hintSquare, 'e2');
      expect(f.session.controller.canHint, isFalse, reason: 'one per move');
    });

    test('a hinted move is logged as hinted, not first-try', () {
      final f = _build();
      _startDefault(f.session);
      f.session.hintCurrentMove();
      f.session.handleBoardMove('e4');

      final c = f.session.controller;
      expect(c.guessLog.single.wasHinted, isTrue);
      expect(c.guessLog.single.note, '(hinted)');
      expect(c.correctFirstTry, 0);
      expect(c.hintedCount, 1);
      expect(c.hintSquare, isNull);
    });

    test('hints wait for the reveal delay', () {
      final f = _build(revealDelaySec: 30);
      _startDefault(f.session);
      expect(f.session.controller.canHint, isFalse);
      f.session.hintCurrentMove();
      expect(f.session.controller.hintSquare, isNull);
      f.session.dispose();
    });
  });

  group('trophies', () {
    test('a positive count folds in and notifies', () {
      final f = _build();
      final before = f.changeCount();

      f.session.noteTrophiesEarned(3);

      expect(f.session.totalTrophyCount, 3);
      expect(f.changeCount(), greaterThan(before));
    });

    test('a zero or negative count is ignored without notifying', () {
      final f = _build();
      f.session.noteTrophiesEarned(2);
      final after = f.changeCount();

      f.session.noteTrophiesEarned(0);
      f.session.noteTrophiesEarned(-1);

      expect(f.session.totalTrophyCount, 2);
      expect(f.changeCount(), after);
    });
  });

  group('settings', () {
    test('reveal delay persists and is read back', () async {
      final f = _build();
      await f.session.setRevealDelay(15);
      expect(f.session.controller.revealDelaySec, 15);

      final g = _build();
      await g.session.loadSettings();
      expect(g.session.controller.revealDelaySec, 15);
    });

    test('an unset reveal delay falls back to the default', () async {
      final f = _build();
      await f.session.loadSettings();
      expect(f.session.controller.revealDelaySec, 60);
    });
  });

  group('revealing', () {
    test('does nothing when no session is running', () {
      final f = _build();
      final before = f.handle.jumpedToIndices.length;
      f.session.revealCurrentMove();
      expect(f.handle.jumpedToIndices.length, before);
    });

    test('an empty game never starts a session', () {
      final f = _build(movetext: '*');
      f.session.toggle();
      expect(f.session.isConfiguring, isFalse);
      expect(f.session.revealCurrentMove, returnsNormally);
    });

    test('a revealed move is logged and the game moves on', () {
      final f = _build();
      _startDefault(f.session);
      f.session.revealCurrentMove();
      final c = f.session.controller;
      expect(c.revealedCount, 1);
      expect(c.guessLog.single.wasRevealed, isTrue);
      expect(f.handle.reveal?.mainlinePly, 1);
    });
  });

  group('auto-play', () {
    testWidgets('the opponent replies after a short pause', (tester) async {
      final f = _build();
      _startDefault(f.session);
      f.session.handleBoardMove('e4');
      expect(f.session.controller.opponentPlaying, isTrue);

      await tester.pump(const Duration(milliseconds: 500));

      expect(f.session.controller.opponentPlaying, isFalse);
      expect(f.handle.reveal?.mainlinePly, 2);
      expect(f.handle.mainLineIndex, 2);
      expect(f.session.controller.waitingForUser, isTrue);
      f.session.dispose();
    });

    testWidgets('finishing the game writes the guess notes back', (
      tester,
    ) async {
      final f = _build(movetext: '1. e4 e5 *');
      _startDefault(f.session);
      f.session.handleBoardMove('d4');
      f.session.handleBoardMove('e4');
      await tester.pump(const Duration(milliseconds: 500));

      expect(f.session.controller.isComplete, isTrue);
      expect(f.handle.guessAnnotations, {0: '(tried d4 — 2 tries)'});
      expect(f.handle.guessVariations, {
        0: ['d4'],
      });
      f.session.dispose();
    });

    testWidgets('a variations drill opens each sideline with its premise', (
      tester,
    ) async {
      final f = _build(movetext: '1. e4 e5 (1... c5 2. Nf3) 2. Nf3 *');
      f.session.beginSetup();
      f.session.updateSetup(includeVariations: true);
      f.session.begin();
      final c = f.session.controller;

      f.session.handleBoardMove('e4');
      await tester.pump(const Duration(milliseconds: 500)); // e5 auto-plays
      expect(c.currentStep?.isPremise, isTrue);
      expect(c.opponentPlaying, isTrue);
      expect(
        f.handle.model.isNodeVisible(
          f.handle.model.variationsByPly[1]!.first,
          1,
        ),
        isFalse,
        reason: 'the sideline stays hidden until the drill reaches it',
      );

      await tester.pump(const Duration(milliseconds: 800)); // c5 is shown
      expect(f.handle.jumpedToNodes.first, 'c5');
      expect(c.waitingForUser, isTrue);
      expect(c.lastPremise?.san, 'c5');
      expect(f.handle.currentVariationNodeId, isNotNull);

      f.session.handleBoardMove('Nf3');
      expect(c.guessLog.last.step.node?.san, 'Nf3');
      expect(f.handle.jumpedToNodes.last, 'Nf3');

      // Back on the mainline for 2. Nf3, parked at the branch position.
      expect(c.currentStep?.mainlinePly, 2);
      expect(f.handle.inVariation, isFalse);
      expect(f.handle.mainLineIndex, 2);
      f.session.dispose();
    });

    testWidgets('a wrong try inside a sideline is saved under its node', (
      tester,
    ) async {
      final f = _build(movetext: '1. e4 e5 (1... c5 2. Nf3) 2. Nf3 *');
      f.session.beginSetup();
      f.session.updateSetup(includeVariations: true);
      f.session.begin();
      f.session.handleBoardMove('e4');
      await tester.pump(const Duration(milliseconds: 1300));

      f.session.handleBoardMove('d4');
      f.session.handleBoardMove('Nf3');
      f.session.handleBoardMove('Nf3');
      await tester.pump(const Duration(milliseconds: 500));

      final c5 = f.handle.model.variationsByPly[1]!.first;
      expect(f.session.controller.isComplete, isTrue);
      expect(f.handle.nodeVariations, {
        c5.id: ['d4'],
      });
      expect(f.handle.nodeAnnotations?.values, ['(tried d4 — 2 tries)']);
      f.session.dispose();
    });
  });

  test('dispose detaches from the controller', () {
    final f = _build();
    _startDefault(f.session);
    expect(f.session.dispose, returnsNormally);
  });

  test('a Black null ply is skipped after a correct White guess', () {
    final f = _build(movetext: '1. d4 -- 2. Nf3 *');
    _startDefault(f.session);
    expect(f.session.controller.revealedPly, 0);
    f.session.handleBoardMove('d4');
    expect(f.session.controller.revealedPly, 2);
    expect(f.session.controller.waitingForUser, isTrue);
  });
}
