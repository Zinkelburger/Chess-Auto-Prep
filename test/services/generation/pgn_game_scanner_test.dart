import 'package:chess_auto_prep/chess_core/position/eval_canonicalize.dart';
import 'package:chess_auto_prep/services/generation/pgn_freq_map.dart';
import 'package:chess_auto_prep/services/generation/pgn_game_scanner.dart';
import 'package:chess_auto_prep/services/generation/pgn_lexer.dart';
import 'package:chess_auto_prep/utils/chess_utils.dart' show playUciMove;
import 'package:flutter_test/flutter_test.dart';

const _start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

PgnGame _game(
  String movetext, {
  String result = '1-0',
  String? whiteElo,
  String? blackElo,
  String date = '2021.05.01',
}) => PgnGame(
  headers: {
    'White': 'W',
    'Black': 'B',
    'Result': result,
    'Date': date,
    if (whiteElo != null) 'WhiteElo': whiteElo,
    if (blackElo != null) 'BlackElo': blackElo,
  },
  movetext: movetext,
);

void main() {
  PgnGameScanner scanner(
    PgnFreqMap map, {
    PgnFreqConfig config = const PgnFreqConfig(),
    String? targetKey,
  }) => PgnGameScanner(
    map: map,
    config: config,
    targetKey: targetKey,
    warnings: PgnScanWarnings(),
  );

  test('counts every position and move from the start', () {
    final map = PgnFreqMap(gameCapacity: 0);
    final result = scanner(
      map,
    ).scan(_game('1. e4 e5 2. Nf3 1-0'), gameIndex: 1);

    expect(result, GameScan.ok);
    final root = map.get(_start)!;
    expect(root.moves.single.uci, 'e2e4');
    expect(root.moves.single.whiteWins, 1);
    expect(root.moves.single.lastYear, 2021);
    final afterE4 = map.get(playUciMove(_start, 'e2e4')!)!;
    expect(afterE4.reachCount, 1);
    expect(afterE4.moves.single.uci, 'e7e5');
  });

  test('stops counting at maxPly', () {
    final map = PgnFreqMap(gameCapacity: 0);
    scanner(
      map,
      config: const PgnFreqConfig(maxPly: 1),
    ).scan(_game('1. e4 e5 2. Nf3'), gameIndex: 1);

    expect(map.get(_start)!.moves.single.uci, 'e2e4');
    expect(map.get(playUciMove(_start, 'e2e4')!)!.moves, isEmpty);
  });

  test('skips a game where both players are rated below the floor', () {
    final map = PgnFreqMap(gameCapacity: 0);
    final s = scanner(map, config: const PgnFreqConfig(minElo: 2000));

    expect(
      s.scan(_game('1. e4', whiteElo: '1500', blackElo: '1600'), gameIndex: 1),
      GameScan.belowEloFloor,
    );
    // One rating above the floor keeps the game; unrated pairings too.
    expect(
      s.scan(_game('1. e4', whiteElo: '1500', blackElo: '2200'), gameIndex: 2),
      GameScan.ok,
    );
    expect(s.scan(_game('1. e4'), gameIndex: 3), GameScan.ok);
    expect(map.get(_start)!.moves.single.count, 2);
  });

  test('a game that never reaches the target is a prefix skip', () {
    final map = PgnFreqMap(gameCapacity: 0);
    final afterE4 = canonicalizeFen4(playUciMove(_start, 'e2e4')!);
    final s = scanner(map, targetKey: afterE4);

    expect(s.scan(_game('1. d4 d5'), gameIndex: 1), GameScan.prefixSkip);
    expect(s.scan(_game('1. e4 c5'), gameIndex: 2), GameScan.ok);
    expect(
      map.get(_start),
      isNull,
      reason: 'moves before the target are not counted',
    );
    expect(map.get(afterE4)!.moves.single.uci, 'c7c5');
  });

  test('an unparsable move inside the counted window is an error', () {
    final map = PgnFreqMap(gameCapacity: 0);
    expect(
      scanner(map).scan(_game('1. e4 Qh4 2. Nf3'), gameIndex: 1),
      GameScan.error,
    );
  });

  test('retains a strong game and back-references its positions', () {
    final map = PgnFreqMap(gameCapacity: 4);
    final result =
        scanner(
          map,
          config: const PgnFreqConfig(retainGames: 4, retainMinElo: 2400),
        ).scan(
          _game('1. e4 e5 2. Nf3 Nc6', whiteElo: '2600', blackElo: '2500'),
          gameIndex: 1,
        );

    expect(result, GameScan.ok);
    final game = map.games.entries.single;
    expect(game.movesSan, ['e4', 'e5', 'Nf3', 'Nc6']);
    expect(game.averageElo, 2550);
    expect(map.get(_start)!.gameRefs, [0]);
  });

  test('a game below the retention floor is counted but not kept', () {
    final map = PgnFreqMap(gameCapacity: 4);
    scanner(
      map,
      config: const PgnFreqConfig(retainGames: 4, retainMinElo: 2400),
    ).scan(_game('1. e4', whiteElo: '2000', blackElo: '2000'), gameIndex: 1);

    expect(map.get(_start)!.moves.single.count, 1);
    expect(map.games.isEmpty, isTrue);
  });

  test('eloTag treats blanks and ? as unrated', () {
    expect(eloTag({'WhiteElo': '2500'}, 'WhiteElo'), 2500);
    expect(eloTag({'WhiteElo': '?'}, 'WhiteElo'), 0);
    expect(eloTag({'WhiteElo': ''}, 'WhiteElo'), 0);
    expect(eloTag(const {}, 'WhiteElo'), 0);
  });
}
