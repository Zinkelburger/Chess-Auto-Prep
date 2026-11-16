import 'dart:async';

import 'package:chess_auto_prep/chess/tactics/analyzed_games.dart';
import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/chess/tactics/mined_set.dart';
import 'package:chess_auto_prep/chess/tactics/mistake_counts.dart';
import 'package:chess_auto_prep/features/tactics/source_games.dart';
import 'package:chess_auto_prep/storage/my_accounts.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_store.dart';
import '../../support/tactics_fixture.dart';
import '../../support/window_fixture.dart';

/// The game the set's first puzzle (`lichess_abc`, 4.Qe2??) was mined from,
/// as the download saved it.
const _savedGame = '''
[Event "Rated blitz game"]
[White "Me"]
[Black "Rival"]
[Result "0-1"]
[GameId "lichess_abc"]

1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 4. Qe2 Nd4 5. Qd1 0-1''';

const _otherGame = '''
[Event "Rated blitz game"]
[White "Me"]
[Black "Someone"]
[Result "1-0"]
[GameId "lichess_xyz"]

1. d4 d5 1-0''';

/// The games the puzzles came from, found in the account's saved games;
/// the Game tab follows the puzzle up, by its position and its place in the
/// list, and takes the counts a review writes.
void main() {
  late WindowFixture w;
  late SourceGames sources;

  void saveGames(List<String> games) {
    final text = '${games.join('\n\n')}\n';
    w.store.documents[w.gamesCache.refFor(GameSite.lichess, 'Me')] = Opened(
      text,
      scriptedRevision(text),
    );
  }

  setUp(() async {
    w = WindowFixture();
    w.accounts.accounts[GameSite.lichess] = const Account('Me');
    sources = w.parts.training.sources;
    await w.tactics.load();
  });
  tearDown(() => w.dispose());

  test('a puzzle\'s saved game is found by its id, and found again without '
      'reading the file', () async {
    saveGames([_otherGame, _savedGame]);
    final puzzle = w.tactics.at(0)!;
    final game = await sources.gameOf(puzzle);
    expect(game!.text, _savedGame);
    expect(game.sans[game.mistake!], 'Qe2');
    final reads = w.store.opens;
    expect((await sources.gameOf(puzzle))!.text, _savedGame);
    expect(w.store.opens, reads);
  });

  test('a game the file does not hold is looked for again once a download '
      'changed it', () async {
    saveGames([_otherGame]);
    final puzzle = w.tactics.at(0)!;
    expect(await sources.gameOf(puzzle), isNull);
    expect(await sources.gameOf(puzzle), isNull);
    saveGames([_otherGame, _savedGame]);
    expect((await sources.gameOf(puzzle))!.text, _savedGame);
  });

  test('a saved-games file that cannot be read answers with the puzzle\'s '
      'own record of the game', () async {
    w.store.documents[w.gamesCache.refFor(GameSite.lichess, 'Me')] =
        const Unreadable('disk error');
    final withSource = tacticsSet.replaceFirst(
      '[FlawTags "opening hasty"]',
      '[FlawTags "opening hasty"]\n'
          '[SourceMovetext "1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 4. Qe2"]',
    );
    w.store.documents[tacticsRef] = Opened(
      withSource,
      scriptedRevision(withSource),
    );
    await w.tactics.load();
    final game = await sources.gameOf(w.tactics.at(0)!);
    expect(game!.tag('Black'), 'Rival');
    expect(game.sans, hasLength(7));
  });

  test('the Game tab follows the puzzle up', () async {
    saveGames([_savedGame]);
    expect(sources.view, isA<NoPuzzleUp>());
    unawaited(w.trainer.show(w.tactics.at(0)!));
    await pumpEventQueue();
    final shown = sources.view as SourceShown;
    expect(shown.game.text, _savedGame);
    expect(shown.puzzle.gameId, 'lichess_abc');
  });

  test('the same puzzle shown again is not read again', () async {
    saveGames([_savedGame]);
    unawaited(w.trainer.show(w.tactics.at(0)!));
    await pumpEventQueue();
    final shown = sources.view;
    unawaited(w.trainer.show(w.tactics.at(0)!));
    await pumpEventQueue();
    expect(sources.view, same(shown));
  });

  test('a second puzzle from the same position is followed', () async {
    final first = RegExp(
      r'\[Event "Default #1"\][\s\S]*?\*\n',
    ).firstMatch(tacticsSet)![0]!;
    final twin = first
        .replaceFirst('Default #1', 'Default #0')
        .replaceFirst('lichess_abc', 'lichess_twin');
    final text = tacticsSet.replaceFirst(first, '$first\n$twin');
    w.store.documents[tacticsRef] = Opened(text, scriptedRevision(text));
    await w.tactics.load();
    expect(w.tactics.at(1)!.fen, w.tactics.at(0)!.fen);
    unawaited(w.trainer.show(w.tactics.at(0)!));
    await pumpEventQueue();
    unawaited(w.trainer.show(w.tactics.at(1)!));
    await pumpEventQueue();
    expect(
      sources.view,
      isA<NoSourceGame>(),
      reason: 'the twin\'s game is not saved',
    );
  });

  test('the game on view takes the counts the review writes', () async {
    saveGames([_savedGame]);
    unawaited(w.trainer.show(w.tactics.at(0)!));
    await pumpEventQueue();
    expect(w.tactics.isOpen, isTrue);
    expect((sources.view as SourceShown).counts, isNull);
    // A review whose game made no new puzzle writes its counts alone.
    expect(
      w.session.apply(
        (set) => withMined(
          set,
          const [],
          analyzed: analyzedIn(set.preamble),
          mistakes: {'lichess_abc': const MistakeCounts(blunders: 2)},
        ),
      ),
      isNull,
    );
    await pumpEventQueue();
    expect((sources.view as SourceShown).counts!.blunders, 2);
  });

  test(
    'a puzzle that moved up the list is followed at its new place',
    () async {
      saveGames([_savedGame.replaceFirst('lichess_abc', 'lichess_def')]);
      unawaited(w.trainer.show(w.tactics.at(1)!));
      await pumpEventQueue();
      expect((sources.view as SourceShown).puzzle.index, 1);
      expect(await w.tactics.delete(w.tactics.at(0)!), isNull);
      await pumpEventQueue();
      expect((sources.view as SourceShown).puzzle.index, 0);
    },
  );
}
