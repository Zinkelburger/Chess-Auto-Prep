import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/opening_index.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/workspace/index_build.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/big_chapter.dart';
import '../support/scripted_explorer.dart';
import '../support/viewer_fixture.dart';
import 'file_tree_test.dart' show afterD4D5;

void main() {
  test('games already read index as their text does', () async {
    for (final text in [threeGameFile, bigChapter(games: 1500)]) {
      final lines = parseChapter(name: 'games', text: text).lines;
      final fromText = OpeningIndex.of([for (final line in lines) line.text]);
      final fromLines = (await IndexBuild.ofLines(lines).result)!;
      expect(fromLines.gameCount, fromText.gameCount);
      expect(fromLines.unread, fromText.unread);
      for (final fen in [Fen.initial, afterD4D5]) {
        final a = fromLines.answer(fen);
        final b = fromText.answer(fen);
        expect(movesOf(a), movesOf(b));
        expect(
          [for (final m in a.moves) (m.white, m.draws, m.black, m.undecided)],
          [for (final m in b.moves) (m.white, m.draws, m.black, m.undecided)],
        );
        expect(
          [for (final g in a.games) g.id],
          [for (final g in b.games) g.id],
        );
      }
    }
  });

  test('a large file is indexed in turns, none longer than the games it '
      'reports progress by', () async {
    final lines = parseChapter(
      name: 'games',
      text: bigChapter(games: 1500),
    ).lines;
    final progress = <int>[];
    final build = IndexBuild.ofLines(lines, onProgress: progress.add);
    // Nothing is indexed before the event loop has had its turn.
    expect(progress, isEmpty);
    expect((await build.result)!.gameCount, 1500);
    expect(progress, isNotEmpty);
    var before = 0;
    for (final done in progress) {
      expect(done - before, inInclusiveRange(1, OpeningIndex.progressEvery));
      before = done;
    }
  });

  test('a file opened showing one game is indexed from the moves read on '
      'the other isolate, not read here a game at a time', () async {
    final text = bigChapter(games: 1500);
    final shown = await readChapterShowing(name: 'games', text: text, game: 0);
    final build = IndexBuild.ofLines(shown.lines);
    // Waiting for the moves to arrive, the build has asked no game for its.
    await Future<void>.delayed(Duration.zero);
    final unread = shown.lines.where((line) => !line.isRead).length;
    // All but the game shown, which the chapter read for the board.
    expect(unread, anyOf(0, shown.lines.length - 1));
    final index = (await build.result)!;
    final whole = OpeningIndex.of([for (final line in shown.lines) line.text]);
    expect(index.gameCount, 1500);
    expect(movesOf(index.answer(afterD4D5)), movesOf(whole.answer(afterD4D5)));
  });

  test('a build stopped while the moves are on their way indexes '
      'nothing', () async {
    final text = bigChapter(games: 1500);
    final shown = await readChapterShowing(name: 'games', text: text, game: 0);
    final progress = <int>[];
    final build = IndexBuild.ofLines(shown.lines, onProgress: progress.add);
    build.cancel();
    expect(await build.result, isNull);
    await movesBeingRead(shown.lines);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(progress, isEmpty);
  });

  test('a build stopped answers null and indexes no further', () async {
    final lines = parseChapter(
      name: 'games',
      text: bigChapter(games: 1500),
    ).lines;
    final progress = <int>[];
    final build = IndexBuild.ofLines(lines, onProgress: progress.add);
    build.cancel();
    expect(await build.result, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(progress, isEmpty);
  });

  for (final onWorker in [false, true]) {
    test(
      'a progress failure closes the ${onWorker ? 'isolate' : 'incremental'} '
      'build and is delivered through its result',
      () async {
        final text = bigChapter(games: 1500);
        final lines = parseChapter(name: 'games', text: text).lines;
        final failure = StateError('progress consumer failed');
        var reports = 0;
        void onProgress(int done) {
          reports++;
          throw failure;
        }

        final build = onWorker
            ? IndexBuild.start([
                for (final line in lines) line.text,
              ], onProgress: onProgress)
            : IndexBuild.ofLines(lines, onProgress: onProgress);
        await expectLater(build.result, throwsA(same(failure)));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(reports, 1);
        // Cancellation after failure cannot change the terminal result.
        build.cancel();
        await expectLater(build.result, throwsA(same(failure)));
      },
    );
  }
}
