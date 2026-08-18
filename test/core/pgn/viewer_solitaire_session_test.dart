import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/core/pgn/pgn_viewer_handle.dart';
import 'package:chess_auto_prep/core/pgn/solitaire_controller.dart';
import 'package:chess_auto_prep/core/pgn/viewer_solitaire_session.dart';

/// Characterization tests for [ViewerSolitaireSession].
///
/// This logic used to live in a `part` file as the private `_SolitaireOps`
/// mixin on `PgnViewerController`, where it could only be reached through a
/// fully-built controller — so none of it was tested. Extracting it into a
/// collaborator with injected suppliers is what makes the cases below
/// expressible at all; they pin the behaviour that extraction had to preserve.

/// Records what the session asks of the board, so each test can assert on the
/// commands rather than on a live widget.
class _FakeHandle implements PgnViewerHandle {
  _FakeHandle({List<String>? moves}) : mainLineMoves = moves ?? const [];

  @override
  final List<String> mainLineMoves;

  @override
  int mainLineIndex = 0;

  @override
  bool inVariation = false;

  final List<String> ephemeralMoves = [];
  final List<String> variationMoves = [];
  final List<int> jumpedToIndices = [];
  Map<int, String>? guessAnnotations;
  Map<int, List<String>>? guessVariations;
  int clearEphemeralCount = 0;

  @override
  int get mainLineLength => mainLineMoves.length;

  @override
  void addEphemeralMove(String san) => ephemeralMoves.add(san);

  @override
  void recordVariationMove(String san) => variationMoves.add(san);

  @override
  void clearEphemeralMoves() => clearEphemeralCount++;

  @override
  void goToMainLineIndex(int moveIndex) {
    jumpedToIndices.add(moveIndex);
    mainLineIndex = moveIndex;
  }

  @override
  void addGuessAnnotations(Map<int, String> notes) => guessAnnotations = notes;

  @override
  void addGuessVariations(Map<int, List<String>> wrongByPly) =>
      guessVariations = wrongByPly;

  @override
  String? get currentFen => null;
  @override
  void goBack() {}
  @override
  void goForward() {}
  @override
  void jumpToMove(int moveNumber, bool isWhiteToPlay) {}
}

/// Builds a session over [moves] with adjustable surroundings.
({
  ViewerSolitaireSession session,
  _FakeHandle handle,
  void Function(bool) setHasGames,
  int Function() changeCount,
})
_build({List<String> moves = const ['e4', 'e5', 'Nf3'], bool hasGames = true}) {
  final handle = _FakeHandle(moves: moves);
  var games = hasGames;
  var changes = 0;
  var stopAutoPlayCalls = 0;
  final session = ViewerSolitaireSession(
    handle: handle,
    hasGames: () => games,
    hasFilePath: () => true,
    userPlaysWhite: () => true,
    currentPosition: () => Chess.initial,
    stopAutoPlay: () => stopAutoPlayCalls++,
    onChanged: () => changes++,
  );
  return (
    session: session,
    handle: handle,
    setHasGames: (v) => games = v,
    changeCount: () => changes,
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('starting a session', () {
    test('toggle activates, rewinds the board and clears analysis moves', () {
      final f = _build();
      expect(f.session.isActive, isFalse);

      f.session.toggle();

      expect(f.session.isActive, isTrue);
      expect(
        f.handle.clearEphemeralCount,
        1,
        reason: 'stale analysis lines must not survive into a guessing run',
      );
      expect(f.handle.jumpedToIndices, contains(0));
    });

    test('refuses to start with no game loaded', () {
      final f = _build(hasGames: false);
      f.session.toggle();
      expect(f.session.isActive, isFalse);
      expect(f.handle.clearEphemeralCount, 0);
    });

    test('toggling again stops the session', () {
      final f = _build();
      f.session.toggle();
      f.session.toggle();
      expect(f.session.isActive, isFalse);
    });
  });

  group('routing a board move', () {
    test('a move at the frontier is judged as a guess', () {
      final f = _build();
      f.session.toggle();

      f.session.handleBoardMove('e4');

      expect(
        f.handle.ephemeralMoves,
        isEmpty,
        reason: 'a guess at the frontier is not exploratory analysis',
      );
    });

    test('a wrong guess is recorded as a live variation', () {
      final f = _build();
      f.session.toggle();

      f.session.handleBoardMove('d4');

      expect(f.handle.variationMoves, ['d4']);
    });

    test('a move inside a variation is exploratory, never a guess', () {
      final f = _build();
      f.session.toggle();
      f.handle.inVariation = true;

      f.session.handleBoardMove('e4');

      expect(f.handle.ephemeralMoves, ['e4']);
      expect(f.handle.variationMoves, isEmpty);
    });

    test('a move behind the frontier is exploratory, never a guess', () {
      final f = _build();
      f.session.toggle();
      // Browsing back into the already-revealed region.
      f.handle.mainLineIndex = f.session.controller.revealedPly + 5;

      f.session.handleBoardMove('e4');

      expect(f.handle.ephemeralMoves, ['e4']);
      expect(f.handle.variationMoves, isEmpty);
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

    test('past the end of the game is a no-op rather than a range error', () {
      final f = _build(moves: const []);
      f.session.toggle();
      expect(f.session.revealCurrentMove, returnsNormally);
    });
  });

  test('restartForCurrentOrientation rewinds to the start of the game', () {
    final f = _build();
    f.session.toggle();
    f.handle.jumpedToIndices.clear();

    f.session.restartForCurrentOrientation();

    expect(f.handle.jumpedToIndices.first, 0);
  });

  test('dispose detaches from the controller', () {
    final f = _build();
    f.session.toggle();
    expect(f.session.dispose, returnsNormally);
  });

  test(
    'after a correct guess, skips a Black null ply to the next White move',
    () {
      final c = SolitaireController();
      addTearDown(c.dispose);
      c.start(
        mainLineLength: 3,
        userPlaysWhite: true,
        mainlineSans: const ['d4', '--', 'Nf3'],
      );
      expect(c.revealedPly, 0);
      expect(c.handleMove('d4', Chess.initial, 'd4'), isTrue);
      expect(c.revealedPly, 2);
    },
  );
}
