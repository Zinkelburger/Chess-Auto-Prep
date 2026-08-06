/// Export/import round trips and PGN validity.
///
/// The roster CSV is the documented hand-off format between the app and an
/// agent, so a round trip through it must preserve the trust model — an
/// unconfirmed proposal that comes back trusted would silently defeat the
/// confirmation gate that the whole identity design rests on.
library;

import 'package:chess_auto_prep/features/tournament/models/opponent_probability.dart';
import 'package:chess_auto_prep/features/tournament/models/player_identity.dart';
import 'package:chess_auto_prep/features/tournament/models/roster_entry.dart';
import 'package:chess_auto_prep/features/tournament/services/prep_export.dart';
import 'package:chess_auto_prep/features/tournament/services/roster_import.dart';
import 'package:chess_auto_prep/features/tournament/services/tournament_prep_service.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

PrepPosition _position({
  List<String> movePath = const ['e4', 'c5', 'Nf3'],
  String missingMove = 'e6',
  bool weAreWhite = true,
  bool transposes = false,
  List<PrepOpponentRef> opponents = const [
    PrepOpponentRef(
      playerId: 'a',
      playerName: 'Someone',
      pairingProb: 0.4,
      moveShare: 0.5,
      reachProbability: 0.9,
    ),
  ],
}) => PrepPosition(
  fen: 'irrelevant',
  movePath: movePath,
  missingMove: missingMove,
  weAreWhite: weAreWhite,
  transposes: transposes,
  opponents: opponents,
);

TournamentPrepReport _report(List<PrepPosition> positions) =>
    TournamentPrepReport(
      eventName: 'Spring Open',
      positions: positions,
      clashReports: const [],
      simulation: SimulationResult.empty,
      elapsed: Duration.zero,
    );

void main() {
  group('roster CSV round trip', () {
    test('does not promote an unconfirmed agent proposal', () {
      final roster = Roster(
        entries: [
          const RosterEntry(
            id: 'x',
            name: 'Guessed Person',
            rating: 1800,
            identity: PlayerIdentity(
              chesscomUsername: 'agent_guess',
              confidence: IdentityConfidence.low,
              source: IdentitySource.agentProposed,
              evidence: 'A hunch from a search result',
            ),
          ),
        ],
      );

      final back = RosterImporter.parse(
        PrepExporter.rosterToCsv(roster),
      ).roster;
      final identity = back.entries.single.identity!;

      expect(identity.chesscomUsername, 'agent_guess');
      expect(identity.source, IdentitySource.agentProposed);
      expect(identity.confidence, IdentityConfidence.low);
      expect(
        identity.isActionable,
        isFalse,
        reason: 'a round trip must not launder a guess into a trusted identity',
      );
      expect(identity.evidence, contains('hunch'));
    });

    test('preserves a confirmed identity as confirmed', () {
      final roster = Roster(
        entries: [
          const RosterEntry(
            id: 'x',
            name: 'Known Person',
            rating: 1800,
            identity: PlayerIdentity(
              chesscomUsername: 'known',
              confidence: IdentityConfidence.exact,
              source: IdentitySource.manual,
              evidence: 'Confirmed by the user',
            ),
          ),
        ],
      );

      final back = RosterImporter.parse(
        PrepExporter.rosterToCsv(roster),
      ).roster;
      expect(back.entries.single.identity!.isActionable, isTrue);
    });

    test('a hand-made sheet with no provenance columns is trusted', () {
      // A username the user typed themselves is an assertion, so with no
      // Confidence/Source columns present the manual/exact default stands.
      const csv = '''
Name,Rating,chess.com
Alice Brown,1700,alicebrown99
''';
      final identity = RosterImporter.parse(
        csv,
      ).roster.entries.single.identity!;
      expect(identity.source, IdentitySource.manual);
      expect(identity.isActionable, isTrue);
    });

    test('survives commas and quotes inside the evidence', () {
      final roster = Roster(
        entries: [
          const RosterEntry(
            id: 'x',
            name: 'Person, Tricky',
            rating: 1800,
            identity: PlayerIdentity(
              chesscomUsername: 'tricky',
              confidence: IdentityConfidence.medium,
              source: IdentitySource.agentProposed,
              evidence: 'Bio said "USCF 123, MA", which matches',
            ),
          ),
        ],
      );

      final back = RosterImporter.parse(
        PrepExporter.rosterToCsv(roster),
      ).roster;
      expect(back.entries.single.name, 'Person, Tricky');
      expect(
        back.entries.single.identity!.evidence,
        'Bio said "USCF 123, MA", which matches',
      );
    });
  });

  group('prep PGN', () {
    test('parses, with the mainline ending on the uncovered move', () {
      final pgn = PrepExporter.toPgn(_report([_position()]));
      final game = PgnGame.parsePgn(pgn);

      expect(game.moves.mainline().map((n) => n.san).toList(), [
        'e4',
        'c5',
        'Nf3',
        'e6',
      ]);
      expect(game.headers['Result'], '*');
    });

    test('handles a Black-repertoire line', () {
      final pgn = PrepExporter.toPgn(
        _report([
          _position(
            movePath: ['d4', 'Nf6', 'c4'],
            missingMove: 'e6',
            weAreWhite: false,
          ),
        ]),
      );
      final game = PgnGame.parsePgn(pgn);
      expect(game.moves.mainline().map((n) => n.san).toList(), [
        'd4',
        'Nf6',
        'c4',
        'e6',
      ]);
      expect(game.headers['White'], 'Opponent');
      expect(game.headers['Black'], 'You');
    });

    test('a gap on move one still produces valid movetext', () {
      final pgn = PrepExporter.toPgn(
        _report([_position(movePath: const [], missingMove: 'e4')]),
      );
      final game = PgnGame.parsePgn(pgn);
      expect(game.moves.mainline().map((n) => n.san).toList(), ['e4']);
    });

    test('braces in an opponent name cannot truncate the comment', () {
      // PGN comments are brace-delimited; an unescaped brace would silently
      // cut the annotation short.
      final pgn = PrepExporter.toPgn(
        _report([
          _position(
            opponents: const [
              PrepOpponentRef(
                playerId: 'a',
                playerName: 'Someone {weird}',
                pairingProb: 0.4,
                moveShare: 0.5,
                reachProbability: 0.9,
              ),
            ],
          ),
        ]),
      );

      expect(pgn, isNot(contains('{weird}')));
      final game = PgnGame.parsePgn(pgn);
      expect(game.moves.mainline().map((n) => n.san).toList(), [
        'e4',
        'c5',
        'Nf3',
        'e6',
      ]);
    });

    test('every position becomes its own game', () {
      final pgn = PrepExporter.toPgn(
        _report([
          _position(),
          _position(movePath: const ['d4'], missingMove: 'f5'),
        ]),
      );
      expect(PgnGame.parseMultiGamePgn(pgn), hasLength(2));
    });

    test('an empty report still emits parseable PGN', () {
      final pgn = PrepExporter.toPgn(_report([]));
      expect(() => PgnGame.parsePgn(pgn), returnsNormally);
    });

    test('a per-opponent export keeps only that opponent', () {
      final report = _report([
        _position(),
        _position(
          movePath: const ['d4'],
          missingMove: 'f5',
          opponents: const [
            PrepOpponentRef(
              playerId: 'b',
              playerName: 'Other',
              pairingProb: 0.3,
              moveShare: 0.4,
              reachProbability: 0.8,
            ),
          ],
        ),
      ]);

      final pgn = PrepExporter.opponentPgn(report, 'a');
      expect(PgnGame.parseMultiGamePgn(pgn), hasLength(1));
      expect(pgn, contains('Someone'));
      expect(pgn, isNot(contains('Other')));
    });
  });

  group('briefing', () {
    test('lists positions with their colour and score', () {
      final text = PrepExporter.toBriefing(_report([_position()]));
      expect(text, contains('Spring Open'));
      expect(text, contains('as White'));
      expect(text, contains('e4 c5 Nf3 e6'));
    });

    test('says so plainly when there is nothing to prepare', () {
      expect(PrepExporter.toBriefing(_report([])), contains('No gaps found'));
    });
  });
}
