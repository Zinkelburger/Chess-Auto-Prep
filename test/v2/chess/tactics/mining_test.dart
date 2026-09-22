import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/v2/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/v2/chess/tactics/analyzed_games.dart';
import 'package:chess_auto_prep/v2/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/v2/chess/tactics/mined_set.dart';
import 'package:chess_auto_prep/v2/chess/tactics/mining.dart';
import 'package:chess_auto_prep/v2/chess/tactics/puzzle.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../../support/my_games_fixture.dart';
import '../../support/tactics_fixture.dart';

void main() {
  group('a move is judged by the winning chance it gave away', () {
    test('0.1, 0.2 and 0.3 are the lines between the three marks', () {
      expect(mistakeFor(0.09), isNull);
      expect(mistakeFor(0.1), MistakeKind.inaccuracy);
      expect(mistakeFor(0.2), MistakeKind.mistake);
      expect(mistakeFor(0.3), MistakeKind.blunder);
      expect(mistakeFor(0.95), MistakeKind.blunder);
    });

    test('Lichess\'s curve, held within 1000 centipawns', () {
      expect(winningChance(0), 0);
      expect(winningChance(100), closeTo(0.1821, 1e-3));
      expect(winningChance(1000), winningChance(5000));
      expect(winningChance(-300), closeTo(-winningChance(300), 1e-12));
    });

    test('the score after the move is the opponent\'s, turned round', () {
      // Level, then the opponent is a pawn up: a mistake from 0 to -1.
      expect(
        judge(const Verdict(), const Verdict(cp: 100)),
        MistakeKind.inaccuracy,
      );
      expect(
        judge(const Verdict(), const Verdict(cp: 150)),
        MistakeKind.mistake,
      );
      // Allowing mate in one from a level position.
      expect(
        judge(const Verdict(), const Verdict(mate: 1)),
        MistakeKind.blunder,
      );
      // Eight pawns up to fifteen pawns up gives nothing away.
      expect(judge(const Verdict(cp: 800), const Verdict(cp: -1500)), isNull);
    });

    test('scores are written as the old app writes them in the note', () {
      expect(evalText(const Verdict(cp: 63)), '+0.6');
      expect(evalText(const Verdict(cp: 63), negate: true), '-0.6');
      expect(evalText(const Verdict()), '+0.0');
      expect(evalText(const Verdict(mate: 3)), '#3');
      expect(evalText(const Verdict(mate: 1), negate: true), '#-1');
    });
  });

  group('the line a puzzle asks for', () {
    test('a quiet first move is the whole puzzle', () {
      expect(trainableLine(['a6', 'a4', 'Rb8', 'Bg2']), ['a6']);
    });

    test('forcing moves go on, up to five of the solver\'s', () {
      expect(trainableLine(['Rxe8+', 'Kh7', 'Qg8+', 'Kg6', 'h4']), [
        'Rxe8+',
        'Kh7',
        'Qg8+',
      ]);
      final checks = [for (var i = 0; i < 20; i++) i.isEven ? 'Qh$i+' : 'Kg$i'];
      expect(trainableLine(checks), hasLength(9));
    });

    test('moves are numbered from the position', () {
      const black = Fen('8/8/8/8/8/8/8/k6K b - - 0 8');
      expect(numberedSan(black, ['a6', 'a4', 'Rb8']), '8... a6 9. a4 Rb8');
      expect(numberedSan(Fen.initial, ['e4', 'e5', 'Nf3']), '1. e4 e5 2. Nf3');
    });
  });

  group('mining a game', () {
    final read = readGame(scholarsMate);
    final tree = read.tree!;

    test('only the user\'s moves are looked at', () {
      final black = movesBy(tree, Side.black);
      expect([for (final m in black) m.san], ['e5', 'Nc6', 'Nf6']);
      expect(movesBy(tree, Side.white), hasLength(4));
      expect(isOver(black.last.after), isFalse);
      var last = tree.children.first;
      while (last.children.isNotEmpty) {
        last = last.children.first;
      }
      expect(isOver(last.fen), isTrue);
    });

    test('the engine\'s own choice is recognised by the position', () {
      final e5 = movesBy(tree, Side.black).first;
      expect(playedBest(e5, const Verdict(pv: ['e7e5'])), isTrue);
      expect(playedBest(e5, const Verdict(pv: ['c7c5'])), isFalse);
      expect(playedBest(e5, const Verdict()), isFalse);
    });

    test('a blunder becomes the old app\'s puzzle, word for word', () {
      final nf6 = movesBy(tree, Side.black).last;
      final game = SourceGame.of(read.tags, tree, gameIdIn(scholarsMate));
      final puzzle = minedFrom(
        nf6,
        const Verdict(pv: ['g7g6', 'h5f3']),
        const Verdict(mate: 1, pv: ['h5f7']),
        game,
      )!;
      expect(puzzle.kind, MistakeKind.blunder);
      expect(puzzle.answer, ['g6']);
      expect(puzzleText(puzzle, event: 'Default #6'), scholarsMatePuzzle);
    });

    test('a move that lost nothing, or with no line to learn, is none', () {
      final nf6 = movesBy(tree, Side.black).last;
      final game = SourceGame.of(read.tags, tree, 'x');
      expect(
        minedFrom(nf6, const Verdict(pv: ['g7g6']), const Verdict(), game),
        isNull,
      );
      expect(
        minedFrom(nf6, const Verdict(), const Verdict(mate: 1), game),
        isNull,
      );
    });
  });

  group('game ids are the old app\'s', () {
    test('from the address, the GameId header or neither', () {
      expect(gameIdIn(scholarsMate), 'lichess_AbCd1234');
      expect(gameIdIn(quietChesscomGame), 'chesscom_111');
      expect(gameIdIn('[GameId "lichess_xyz"]\n\n1. e4 *'), 'lichess_xyz');
      expect(gameIdIn('[GameId "Zz12Zz12"]\n\n1. e4 *'), 'lichess_Zz12Zz12');
      expect(
        gameIdIn('[Site "https://lichess.org/tournament/abcdefgh"]\n\n1. e4 *'),
        '',
      );
    });

    test('the user is found by name, ignoring case, and exactly', () {
      final tags = readGame(scholarsMate).tags;
      expect(sideOf(tags, 'ME'), Side.black);
      expect(sideOf(tags, 'rival'), Side.white);
      expect(sideOf(tags, 'M'), isNull);
    });
  });

  group('the analysed-games line', () {
    test('reads the line the old app wrote', () {
      expect(analyzedIn(tacticsSet), {'lichess_abc'});
      expect(analyzedIn('[Event "x"]'), isEmpty);
      expect(
        () => analyzedIn('$analyzedGamesPrefix!!!\n'),
        throwsFormatException,
      );
    });

    test('is written sorted, first in the file, and reads back', () {
      final written = withAnalyzed('', {'b', 'a'});
      expect(written, '${analyzedGamesPrefix}WyJhIiwiYiJd\n');
      expect(analyzedIn(withAnalyzed(written, {'c'})), {'c'});
      expect(withAnalyzed('// note\n', {'a'}), endsWith('\n// note\n'));
    });
  });

  group('adding puzzles to the set', () {
    final set = parseChapter(name: 'Default', text: tacticsSet);
    final puzzle = minedScholarsMate();

    test('appends the puzzle and names the game done in one edit', () {
      final edit = withMined(
        set,
        [puzzle],
        analyzed: {'lichess_abc', 'lichess_AbCd1234'},
      );
      final edited = (edit as ChapterEdited).chapter;
      final text = writeChapter(edited);
      String games(String file) => file.substring(file.indexOf('[Event'));
      expect(games(text), startsWith(games(tacticsSet).trimRight()));
      expect(text, endsWith('*\n\n$scholarsMatePuzzle\n'));
      expect(analyzedIn(edited.preamble), {'lichess_abc', 'lichess_AbCd1234'});
      expect(edit.games.order, [0, 1, 2, 3, 4, null]);
      expect(edit.games.heading, isTrue);
    });

    test('what it writes is read back as the same puzzle', () {
      final edit = withMined(set, [puzzle], analyzed: {'lichess_AbCd1234'});
      final text = writeChapter((edit as ChapterEdited).chapter);
      final read = puzzlesOf(parseChapter(name: 'Default', text: text).lines);
      final mined = read.last;
      expect(read, hasLength(6));
      expect(mined.fen, puzzle.fen);
      expect(mined.answer, ['g6']);
      expect(mined.kind, MistakeKind.blunder);
      expect(mined.played, 'Nf6');
      expect(mined.refutation, 'Qxf7#');
      expect(mined.gameId, 'lichess_AbCd1234');
      expect(mined.label, '3... Nf6??');
      expect(mined.note?.before, '+0.0');
      expect(mined.note?.after, '#-1');
      expect(mined.stats.isNew, isTrue);
    });

    test('a position the set already has is not added twice', () {
      final once = writeChapter(
        (withMined(set, [puzzle], analyzed: {'g'}) as ChapterEdited).chapter,
      );
      final again = withMined(
        parseChapter(name: 'Default', text: once),
        [puzzle, puzzle],
        analyzed: {'g'},
      );
      expect(again, isA<ChapterUnchanged>());
    });
  });

  group('adding to a set with little in it', () {
    final set = parseChapter(name: 'Default', text: tacticsSet);
    final puzzle = minedScholarsMate();

    test('an empty set gets the line and the puzzle', () {
      final empty = parseChapter(name: 'Default', text: '');
      final edit = withMined(empty, [puzzle], analyzed: {'g'});
      expect(
        writeChapter((edit as ChapterEdited).chapter),
        '${withAnalyzed('', {'g'})}'
        '${scholarsMatePuzzle.replaceFirst('#6', '#1')}\n',
      );
    });

    test('a game with no puzzles is still marked done', () {
      final edit = withMined(set, const [], analyzed: {'lichess_abc', 'new'});
      final edited = (edit as ChapterEdited).chapter;
      expect(edited.lines, hasLength(5));
      expect(analyzedIn(edited.preamble), {'lichess_abc', 'new'});
    });
  });
}
