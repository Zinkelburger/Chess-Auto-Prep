/// The match store and its BPGN.
///
/// The BPGN half is what the tests are really for. It is the only output of
/// this feature another program will ever read — `tools/bughouse_db/bpgn.py`
/// parses the same shape out of bughouse-db.org's archive — so the movetext
/// has to satisfy that parser's own regex, and a `1-0` has to mean what it
/// means there: a win for the pair holding White on board A.
library;

import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_tournament.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_tournament_store.dart';
import 'package:chess_auto_prep/models/game_outcome.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The regex `tools/bughouse_db/bpgn.py` reads a movetext with, verbatim.
final _moveRe = RegExp(r'(\d+)([AaBb])\.\s*([^\s{]+)');
final _tagRe = RegExp(r'\[([A-Za-z0-9_]+)\s+"([^"]*)"\]');

BughouseGameRecord _game({
  int number = 1,
  int whiteIndex = 0,
  int blackIndex = 1,
  GameResult result = GameResult.blackWins,
  List<String> moves = const ['1f2f3', '1e7e5', '1g2g4', '1d8h4'],
}) => BughouseGameRecord(
  number: number,
  whiteIndex: whiteIndex,
  blackIndex: blackIndex,
  whiteName: whiteIndex == 0 ? 'A + C' : 'B + D',
  blackName: whiteIndex == 0 ? 'B + D' : 'A + C',
  result: result,
  termination: TerminationReason.checkmate,
  detail: 'board 1',
  moves: moves,
  startedAt: DateTime(2026, 9, 4, 11, 30),
  durationMs: 42000,
);

StoredBughouseTournament _match({
  List<BughouseGameRecord>? games,
  String openingLabel = 'Board 1: 1. f3 e5',
}) => StoredBughouseTournament(
  id: 'test-match',
  directoryPath: '/tmp/test-match',
  config: BughouseTournamentConfig(
    name: 'Fool\'s mate',
    startDualFen: BughouseState.initial().dualFen,
    openingLabel: openingLabel,
    seed: 1,
  ),
  createdAt: DateTime(2026, 9, 4, 11, 0),
  status: BughouseTournamentStatus.completed,
  games: games ?? [_game()],
);

void main() {
  test('unfinished games do not count as draws or narrow the interval', () {
    final match = _match(
      games: [
        _game(result: GameResult.whiteWins),
        _game(result: GameResult.unfinished),
      ],
    );
    expect(match.openingScore.played, 1);
    expect(match.openingScore.draws, 0);
    expect(match.openingScoreLabel, '1/1');
    expect(match.openingScoreMargin, 1);
    expect(
      _match(games: [_game(result: GameResult.unfinished)]).openingScoreMargin,
      isNull,
    );
    final unanimous = _match(
      games: List.generate(20, (_) => _game(result: GameResult.whiteWins)),
    );
    expect(unanimous.openingScoreMargin, greaterThan(0.3));
    expect(unanimous.openingScoreMargin, lessThan(1));
  });

  group('BPGN', () {
    test('the movetext is what the archive parser reads', () {
      final bpgn = writeMatchBpgn(_match());

      final moves = [
        for (final m in _moveRe.allMatches(bpgn))
          '${m.group(1)}${m.group(2)} ${m.group(3)}',
      ];
      // Number, board letter, and the letter's case for the mover: `1A` is
      // board 1's White, `1a` its Black.
      expect(moves, ['1A f3', '1a e5', '2A g4', '2a Qh4#']);
    });

    test('the four seats are two participants, crossed over', () {
      final tags = {
        for (final m in _tagRe.allMatches(writeMatchBpgn(_match())))
          m.group(1)!: m.group(2)!,
      };

      expect(tags['WhiteA'], 'A + C');
      expect(tags['BlackA'], 'B + D');
      // Partners sit on opposite colours: White on board 1 is Black on board 2.
      expect(tags['WhiteB'], 'B + D');
      expect(tags['BlackB'], 'A + C');
      expect(tags['Result'], '0-1');
      expect(tags['Opening'], 'Board 1: 1. f3 e5');
      // From the standard opening, so there is nothing to set up.
      expect(tags.containsKey('SetUpDualFEN'), isFalse);
    });

    test('a match from a set-up position carries the position', () {
      final match = _match();
      final fromFen = StoredBughouseTournament(
        id: match.id,
        directoryPath: match.directoryPath,
        config: match.config.copyWith(
          startDualFen:
              '4k3/8/8/8/8/8/8/4K3[] w - - 0 1|'
              'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1',
        ),
        createdAt: match.createdAt,
        status: match.status,
        games: [_game(moves: const [])],
      );

      final tags = {
        for (final m in _tagRe.allMatches(writeMatchBpgn(fromFen)))
          m.group(1)!: m.group(2)!,
      };
      expect(tags['SetUpDualFEN'], startsWith('4k3/8/8/8/8/8/8/4K3'));
    });

    test('every game of a match is written, in order', () {
      final bpgn = writeMatchBpgn(
        _match(
          games: [
            _game(number: 1),
            _game(number: 2, whiteIndex: 1, blackIndex: 0),
          ],
        ),
      );
      expect('[Event '.allMatches(bpgn), hasLength(2));
      expect(
        bpgn.indexOf('[Round "1"]'),
        lessThan(bpgn.indexOf('[Round "2"]')),
      );
    });
  });

  group('on disk', () {
    late Directory root;
    late BughouseTournamentStore store;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('bughouse-matches');
      store = BughouseTournamentStore(root);
    });
    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('a match round-trips through its own JSON', () async {
      final created = await store.create(_match().config);
      await store.save(created.copyWith(games: [_game()]));

      final loaded = await store.load(created.id);

      expect(loaded, isNotNull);
      expect(loaded!.config.name, 'Fool\'s mate');
      expect(loaded.config.seed, 1);
      expect(loaded.games.single.moves, ['1f2f3', '1e7e5', '1g2g4', '1d8h4']);
      expect(loaded.games.single.result, GameResult.blackWins);
      expect(loaded.openingScoreLabel, '0/1');
    });

    test('the BPGN is written beside the metadata', () async {
      final created = await store.create(_match().config);
      await store.save(created.copyWith(games: [_game()]));

      final bpgn = File(p.join(root.path, created.id, 'games.bpgn'));
      expect(await bpgn.exists(), isTrue);
      expect(await bpgn.readAsString(), contains('1a. e5'));
    });

    test('a second match of the same name gets its own directory', () async {
      final first = await store.create(_match().config);
      final second = await store.create(_match().config);
      expect(second.id, isNot(first.id));
      expect(
        (await store.list()).map((m) => m.id),
        containsAll([first.id, second.id]),
      );
    });

    test(
      'a corrupt file hides one match rather than breaking the list',
      () async {
        final good = await store.create(_match().config);
        final bad = Directory(p.join(root.path, 'broken'));
        await bad.create();
        await File(p.join(bad.path, 'match.json')).writeAsString('{not json');

        final listed = await store.list();
        expect(listed.map((m) => m.id), [good.id]);
      },
    );

    test('a status nothing recognises reads back as stopped', () {
      final json =
          jsonDecode(jsonEncode(_match().toJson())) as Map<String, dynamic>;
      json['status'] = 'something-a-later-build-wrote';

      final reloaded = StoredBughouseTournament.fromJson(
        json,
        directoryPath: '/tmp/x',
      );
      // Never "running": a match this process is not playing is over,
      // whatever the file says.
      expect(reloaded.status, BughouseTournamentStatus.cancelled);
    });
  });

  group('the opening score', () {
    test('counts from White-on-board-1\'s side whoever is sitting there', () {
      final match = _match(
        games: [
          _game(number: 1, result: GameResult.whiteWins),
          // Seats swapped, but the score is still read from the same side of
          // the line — that is the whole point of it not being the crosstable.
          _game(
            number: 2,
            whiteIndex: 1,
            blackIndex: 0,
            result: GameResult.whiteWins,
          ),
          _game(number: 3, result: GameResult.draw),
          _game(number: 4, result: GameResult.blackWins),
        ],
      );

      final score = match.openingScore;
      expect(score.points, 2.5);
      expect(score.played, 4);
      expect(score.wins, 2);
      expect(score.draws, 1);
      expect(score.losses, 1);
      expect(match.openingScoreLabel, '2½/4');
      expect(match.openingScoreMargin, greaterThan(0));
    });

    test('says so rather than printing a score before any game', () {
      final empty = _match(games: const []);
      expect(empty.openingScoreLabel, 'No games yet');
      expect(empty.openingScoreMargin, isNull);
    });
  });
}
