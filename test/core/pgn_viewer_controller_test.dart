import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/core/pgn_viewer_controller.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:chess_auto_prep/services/game_analysis_controller.dart';
import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';

/// Stub analysis controller: no isolates, no engine, no IO. Lets us exercise
/// `loadCurrentGame` (called by every navigation/slice method) deterministically.
class _FakeAnalysisController extends GameAnalysisController {
  @override
  Future<bool> tryLoadFromPgn(String pgnText) async => true;

  @override
  void cancel() {}
}

PgnGameEntry _game({String white = 'A', String black = 'B'}) {
  return PgnGameEntry(
    headers: {'White': white, 'Black': black},
    pgnText: '[White "$white"]\n[Black "$black"]\n\n1. e4 e5 *',
  );
}

PgnViewerController _makeController() {
  // A detached widget controller behaves as a no-op stub (its methods guard on
  // a null attached state), so it is safe to use without mounting a widget.
  return PgnViewerController(
    pgnWidgetController: PgnViewerWidgetController(),
    analysisController: _FakeAnalysisController(),
  );
}

/// Populate the game list without going through `loadFile` (which needs storage
/// IO). Mirrors the post-load state the controller expects.
void _seed(PgnViewerController c, List<PgnGameEntry> games) {
  c.allGames = List.of(games);
  c.filteredGames = List.of(games);
  c.currentGameIndex = 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('game navigation', () {
    test('goToGame moves to a valid index', () {
      final c = _makeController();
      _seed(c, [_game(), _game(), _game()]);

      c.goToGame(2);
      expect(c.currentGameIndex, 2);
    });

    test('goToGame ignores out-of-range indices', () {
      final c = _makeController();
      _seed(c, [_game(), _game(), _game()]);

      c.goToGame(1);
      c.goToGame(-1);
      expect(c.currentGameIndex, 1, reason: 'negative index is a no-op');

      c.goToGame(99);
      expect(c.currentGameIndex, 1, reason: 'index >= length is a no-op');
    });

    test('nextGame/prevGame clamp at the list bounds', () {
      final c = _makeController();
      _seed(c, [_game(), _game(), _game()]);

      c.prevGame();
      expect(c.currentGameIndex, 0, reason: 'cannot go before first');

      c.nextGame();
      c.nextGame();
      c.nextGame();
      expect(c.currentGameIndex, 2, reason: 'cannot go past last');

      c.prevGame();
      expect(c.currentGameIndex, 1);
    });

    test('navigation is a no-op when there are no games', () {
      final c = _makeController();
      expect(c.filteredGames, isEmpty);

      c.nextGame();
      c.prevGame();
      c.goToGame(0);
      expect(c.currentGameIndex, 0);
    });
  });

  group('perspective', () {
    test('setPerspective updates the field and notifies', () {
      final c = _makeController();
      var notifications = 0;
      c.addListener(() => notifications++);

      c.setPerspective(const Perspective(mode: PerspectiveMode.black));
      expect(c.perspective.mode, PerspectiveMode.black);
      expect(notifications, greaterThan(0));
    });

    test('orientation follows perspective for the current game', () {
      final c = _makeController();
      // allGames empty so persistPerspective short-circuits (no debounce timer),
      // but filteredGames drives board orientation.
      c.filteredGames = [_game(white: 'hero', black: 'villain')];

      c.setPerspective(const Perspective(mode: PerspectiveMode.white));
      expect(c.boardFlipped, isFalse);

      c.setPerspective(const Perspective(mode: PerspectiveMode.black));
      expect(c.boardFlipped, isTrue);

      c.setPerspective(
          const Perspective(mode: PerspectiveMode.player, playerName: 'villain'));
      expect(c.boardFlipped, isTrue, reason: 'protagonist plays Black');

      c.setPerspective(
          const Perspective(mode: PerspectiveMode.player, playerName: 'hero'));
      expect(c.boardFlipped, isFalse, reason: 'protagonist plays White');
    });
  });

  group('slicing', () {
    test('applySlice filters to the given indices and resets position', () {
      final c = _makeController();
      final games = List.generate(5, (i) => _game(white: 'P$i'));
      _seed(c, games);
      c.goToGame(3);

      c.applySlice([1, 3], const SliceConfig.empty());

      expect(c.filteredGames, hasLength(2));
      expect(c.filteredGames[0], same(games[1]));
      expect(c.filteredGames[1], same(games[3]));
      expect(c.hasActiveFilters, isTrue);
      expect(c.currentGameIndex, 0, reason: 'slice resets to first game');
    });

    test('applySlice with identical indices+config is a no-op', () {
      final c = _makeController();
      _seed(c, [_game(), _game(), _game()]);

      c.applySlice([0, 1], const SliceConfig.empty());
      c.goToGame(1);
      c.applySlice([0, 1], const SliceConfig.empty());

      expect(c.currentGameIndex, 1,
          reason: 'repeat slice must not reset the cursor');
    });

    test('resetFilters restores the full game list', () {
      final c = _makeController();
      final games = List.generate(4, (i) => _game(white: 'P$i'));
      _seed(c, games);
      c.applySlice([2], const SliceConfig.empty());
      expect(c.filteredGames, hasLength(1));

      c.resetFilters();

      expect(c.filteredGames, hasLength(4));
      expect(c.hasActiveFilters, isFalse);
      expect(c.activeSliceConfig.isEmpty, isTrue);
      expect(c.currentGameIndex, 0);
    });
  });
}
