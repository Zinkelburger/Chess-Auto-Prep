import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/workspace/parsed_files.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/viewer_fixture.dart';

const _path = '/Documents/pgn_collections/games.pgn';

void main() {
  Future<Chapter> read(
    ParsedFiles files,
    String text, {
    String path = _path,
    int? game = 0,
  }) => files.read(path: path, name: 'games', text: text, game: game);

  test('a file read again with the same text is not parsed again: its games '
      'are the very ones read before', () async {
    final files = ParsedFiles();
    final first = await read(files, threeGameFile);
    final again = await read(files, threeGameFile);
    expect(again, same(first));
  });

  test('another game of it is shown over the same games', () async {
    final files = ParsedFiles();
    final first = await read(files, threeGameFile);
    final third = await read(files, threeGameFile, game: 2);
    expect(third.game, 2);
    expect(third.lines, same(first.lines));
    expect(third.tree, same(first.lines[2].tree));
  });

  test('a file whose text changed is parsed again', () async {
    final files = ParsedFiles();
    final first = await read(files, threeGameFile);
    final edited = await read(
      files,
      '$threeGameFile\n[Event "Late"]\n\n1. g3 *\n',
    );
    expect(edited.lines, hasLength(4));
    expect(edited.lines, isNot(same(first.lines)));
    // The old text is no longer the file's, and is not kept beside it.
    final back = await read(files, threeGameFile);
    expect(back.lines, isNot(same(first.lines)));
  });

  test('every game merged and one game alone are not made from each '
      'other', () async {
    final files = ParsedFiles();
    final merged = await read(files, threeGameFile, game: null);
    final one = await read(files, threeGameFile);
    expect(merged.game, isNull);
    expect(one.game, 0);
    expect(one.lines, isNot(same(merged.lines)));
  });

  test('a renamed file is read under its new name', () async {
    final files = ParsedFiles();
    await read(files, threeGameFile);
    final renamed = await files.read(
      path: _path,
      name: 'other',
      text: threeGameFile,
      game: 0,
    );
    expect(renamed.name, 'other');
  });

  test('the files read longest ago go first once the budget is spent, and '
      'a file larger than it is not kept', () async {
    final files = ParsedFiles(budget: threeGameFile.length * 2);
    final a = await read(files, threeGameFile, path: '/a.pgn');
    final b = await read(files, threeGameFile, path: '/b.pgn');
    // Reading a again makes b the one read longest ago.
    expect(await read(files, threeGameFile, path: '/a.pgn'), same(a));
    await read(files, threeGameFile, path: '/c.pgn');
    expect(await read(files, threeGameFile, path: '/a.pgn'), same(a));
    expect(await read(files, threeGameFile, path: '/b.pgn'), isNot(same(b)));

    final large = '$threeGameFile\n$threeGameFile\n$threeGameFile';
    final first = await read(files, large, path: '/large.pgn');
    final again = await read(files, large, path: '/large.pgn');
    expect(again, isNot(same(first)));
  });
}
