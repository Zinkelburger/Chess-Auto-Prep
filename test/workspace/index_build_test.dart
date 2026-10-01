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
}
