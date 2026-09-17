/// Cutting a chapter file into games and editing it game by game. The
/// reorder and cross-file move primitives are covered by
/// `repertoire_service_move_games_test.dart`.
library;

import 'package:chess_auto_prep/chess_core/pgn/repertoire_document_mutation.dart';

import 'dart:io';

import 'package:chess_auto_prep/services/repertoire_file_editor.dart';
import 'package:chess_auto_prep/services/repertoire_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

String _game(String event, String moves) =>
    '[Event "$event"]\n[EventDate "2020.01.01"]\n[Result "*"]\n\n$moves *';

void main() {
  group('splitRepertoireDocument', () {
    test('keeps the preamble and cuts games at [Event lines only', () {
      final document = splitRepertoireDocument(
        '﻿// Color: Black\n// Chapter: One\n\n'
        '${_game('a', '1. e4 e5')}\n\n  ${_game('b', '1. d4 d5')}\n',
      );
      expect(document.preamble, '// Color: Black\n// Chapter: One');
      expect(document.games, hasLength(2));
      expect(document.games[0], startsWith('[Event "a"]'));
      expect(document.games[0], endsWith('1. e4 e5 *'));
      expect(document.games[1], startsWith('  [Event "b"]'));
    });

    test('an empty file has no preamble and no games', () {
      final document = splitRepertoireDocument('');
      expect(document.preamble, isEmpty);
      expect(document.games, isEmpty);
    });
  });

  group('lineIdsForGames', () {
    test('agrees with the parser, collisions included', () {
      final games = [
        _game('x', '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7'),
        '[Event "y"]\n[LineID "custom"]\n\n1. d4 *',
        '[Event "empty"]\n\n*',
      ];
      final ids = lineIdsForGames(games);
      final parsed = RepertoireService().parseRepertoirePgn(games.join('\n\n'));
      expect(ids, [parsed[0].id, 'custom', null]);
    });
  });

  group('on disk', () {
    late Directory tmp;
    late String path;
    const editor = RepertoireFileEditor();

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('repertoire_file_editor');
      path = p.join(tmp.path, 'chapter.pgn');
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('appendGameTexts creates the file, then appends to it', () async {
      await editor.appendGameTexts(path, [_game('a', '1. e4')]);
      await editor.appendGameTexts(path, ['  ${_game('b', '1. d4')}  ', ' ']);
      final document = (await editor.readPgnDocument(path))!;
      expect(document.games.map((g) => g.substring(0, 12)), [
        '[Event "a"]\n',
        '[Event "b"]\n',
      ]);
      expect(document.originalContent, endsWith('1. d4 *\n'));
    });

    test(
      'deleteLinesAt removes exactly the named indexes in one write',
      () async {
        await editor.writePgnDocument(
          path,
          preamble: '// Color: White',
          games: [
            for (final e in ['a', 'b', 'c', 'd']) _game(e, '1. e4'),
          ],
        );
        expect(await editor.deleteLinesAt(path, {0, 2, 9}), 2);
        expect(await editor.deleteLinesAt(path, {}), 0);
        final document = (await editor.readPgnDocument(path))!;
        expect(document.preamble, '// Color: White');
        expect(document.games.map((g) => g.substring(8, 9)), ['b', 'd']);
      },
    );

    test(
      'updateLineTitle finds a line by id even after the file moved',
      () async {
        await editor.writePgnDocument(
          path,
          preamble: '',
          games: [_game('a', '1. e4 e5'), _game('b', '1. d4 d5')],
        );
        final lines = RepertoireService().parseRepertoirePgn(
          await File(path).readAsString(),
        );
        expect(
          await editor.updateLineTitle(
            path,
            lines[1].id,
            'Queen pawn',
            gameIndex: 0,
          ),
          isTrue,
          reason: 'a stale gameIndex falls back to the id lookup',
        );
        expect(
          await editor.readGameTextAt(path, 1),
          contains('[Event "Queen pawn"]'),
        );
        expect(await editor.updateLineTitle(path, 'missing', 'x'), isFalse);
        expect(
          await editor.updateLineTitle(
            p.join(tmp.path, 'none.pgn'),
            lines[0].id,
            'x',
          ),
          isFalse,
        );
      },
    );
  });
}
