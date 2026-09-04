import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/core/pgn/pgn_pane_router.dart';
import 'package:chess_auto_prep/core/pgn/pgn_viewer_handle.dart';

class _RecordingHandle implements PgnViewerHandle {
  final calls = <String>[];

  @override
  int mainLineLength = 7;

  @override
  void addEphemeralMove(String san) => calls.add('move:$san');

  @override
  void goBack() => calls.add('back');

  @override
  void goForward() => calls.add('forward');

  @override
  void goToMainLineIndex(int moveIndex) => calls.add('index:$moveIndex');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('Book owns board and move navigation while it is active', () {
    final game = _RecordingHandle();
    final book = _RecordingHandle();
    var bookActive = true;
    final gameCalls = <String>[];
    final router = PgnPaneRouter(
      game: game,
      book: book,
      isBookActive: () => bookActive,
      onGameBoardMove: (san) => gameCalls.add('move:$san'),
    );

    router.playBoardMove('e4');
    router.goBack(() => gameCalls.add('back'));
    router.goForward(() => gameCalls.add('forward'));
    router.goToStart(() => gameCalls.add('start'));
    router.goToEnd(() => gameCalls.add('end'));

    expect(book.calls, ['move:e4', 'back', 'forward', 'index:0', 'index:7']);
    expect(game.calls, isEmpty);
    expect(gameCalls, isEmpty);

    bookActive = false;
    router.playBoardMove('d4');
    router.goBack(() => gameCalls.add('back'));
    router.goForward(() => gameCalls.add('forward'));
    router.goToStart(() => gameCalls.add('start'));
    router.goToEnd(() => gameCalls.add('end'));

    expect(gameCalls, ['move:d4', 'back', 'forward', 'start', 'end']);
    expect(router.active, same(game));
  });
}
