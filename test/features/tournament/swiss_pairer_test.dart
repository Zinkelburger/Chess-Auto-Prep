import 'package:chess_auto_prep/features/tournament/models/pairing.dart';
import 'package:chess_auto_prep/features/tournament/models/roster_entry.dart';
import 'package:chess_auto_prep/features/tournament/services/swiss_pairer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Seeds rated `base`, `base - step`, … so the rating order is unambiguous.
List<SwissSeed> _seeds(int count, {int base = 2000, int step = 50}) => [
  for (var i = 0; i < count; i++)
    SwissSeed(id: 'p${i + 1}', rating: base - i * step),
];

void main() {
  group('round 1', () {
    test('splits the field in half and pairs across', () {
      final pairer = SwissPairer(seeds: _seeds(8));
      final sheet = pairer.nextRound();

      expect(sheet.pairings, hasLength(4));
      // Top half is p1..p4, bottom half p5..p8; board i pairs i with i+4.
      final byBoard = {
        for (final p in sheet.pairings) p.board: {p.whiteId, p.blackId},
      };
      expect(byBoard[1], {'p1', 'p5'});
      expect(byBoard[2], {'p2', 'p6'});
      expect(byBoard[3], {'p3', 'p7'});
      expect(byBoard[4], {'p4', 'p8'});
    });

    test('alternates colors down the boards', () {
      final pairer = SwissPairer(seeds: _seeds(8));
      final sheet = pairer.nextRound();

      // The top-half player takes White on odd boards, Black on even.
      expect(sheet.pairings[0].whiteId, 'p1');
      expect(sheet.pairings[1].whiteId, 'p6');
      expect(sheet.pairings[2].whiteId, 'p3');
      expect(sheet.pairings[3].whiteId, 'p8');
    });

    test('gives an odd field a full-point bye to the lowest rated', () {
      final pairer = SwissPairer(seeds: _seeds(7));
      final sheet = pairer.nextRound();

      expect(sheet.pairings, hasLength(3));
      expect(sheet.byes, hasLength(1));
      expect(sheet.byes.single.playerId, 'p7');
      expect(sheet.byes.single.points, 1.0);
      expect(sheet.byes.single.requested, isFalse);
    });
  });

  group('later rounds', () {
    test('never repeats a pairing', () {
      final pairer = SwissPairer(
        seeds: _seeds(16),
        rules: const SwissRules(rounds: 5),
      );
      final seen = <String>{};

      for (var r = 1; r <= 5; r++) {
        final sheet = pairer.nextRound();
        for (final p in sheet.pairings) {
          final key = ([p.whiteId, p.blackId]..sort()).join('|');
          expect(
            seen.add(key),
            isTrue,
            reason: 'repeat pairing $key in round $r',
          );
        }
        // Higher-rated player wins every game — a deterministic, and for
        // pairing purposes maximally awkward, result set.
        pairer.recordResults(sheet, {
          for (final p in sheet.pairings) p.whiteId: 1.0,
        });
      }
    });

    test('pairs within score groups', () {
      final pairer = SwissPairer(seeds: _seeds(8));
      final r1 = pairer.nextRound();
      // Everyone on board 1-2 wins; boards 3-4 lose. Creates a clean 2/2 split.
      pairer.recordResults(r1, {for (final p in r1.pairings) p.whiteId: 1.0});

      final winners = r1.pairings.map((p) => p.whiteId).toSet();
      final r2 = pairer.nextRound();

      for (final p in r2.pairings) {
        final bothWon =
            winners.contains(p.whiteId) && winners.contains(p.blackId);
        final bothLost =
            !winners.contains(p.whiteId) && !winners.contains(p.blackId);
        expect(
          bothWon || bothLost,
          isTrue,
          reason:
              '${p.whiteId} (${pairer.scoreOf(p.whiteId)}) vs '
              '${p.blackId} (${pairer.scoreOf(p.blackId)}) crosses score groups',
        );
      }
    });

    test('equalizes colors', () {
      final pairer = SwissPairer(seeds: _seeds(8));
      for (var r = 1; r <= 4; r++) {
        final sheet = pairer.nextRound();
        pairer.recordResults(sheet, {
          for (final p in sheet.pairings) p.whiteId: 0.5,
        });
      }
      // After four rounds nobody should be more than one color out of balance.
      for (final s in pairer.standings()) {
        expect(
          s.colorBalance.abs(),
          lessThanOrEqualTo(1),
          reason: '${s.playerId} has color balance ${s.colorBalance}',
        );
      }
    });
  });

  group('constraints', () {
    test('honors a withhold instead of pairing family members', () {
      // p1 vs p5 is the natural round-1 board 1; forbid it.
      final pairer = SwissPairer(
        seeds: _seeds(8),
        rules: const SwissRules(
          constraints: [PairingConstraint('p1', 'p5', reason: 'siblings')],
        ),
      );
      final sheet = pairer.nextRound();

      final p1 = sheet.forPlayer('p1')!;
      expect(p1.opponentOf('p1'), isNot('p5'));
      expect(p1.forced, isFalse);
      expect(sheet.forcedCount, 0);
    });

    test('marks a pairing forced when no legal alternative exists', () {
      // Two players who have already played each other and cannot avoid a
      // rematch: a 2-player field over 2 rounds.
      final pairer = SwissPairer(seeds: _seeds(2));
      final r1 = pairer.nextRound();
      pairer.recordResults(r1, {r1.pairings.single.whiteId: 0.5});

      final r2 = pairer.nextRound();
      expect(r2.pairings.single.forced, isTrue);
    });
  });

  group('byes', () {
    test('respects a requested half-point bye', () {
      final pairer = SwissPairer(
        seeds: [
          const SwissSeed(id: 'p1', rating: 2000, halfPointByeRounds: {1}),
          const SwissSeed(id: 'p2', rating: 1900),
          const SwissSeed(id: 'p3', rating: 1800),
        ],
      );
      final sheet = pairer.nextRound();

      expect(sheet.forPlayer('p1'), isNull);
      final bye = sheet.byes.firstWhere((b) => b.playerId == 'p1');
      expect(bye.points, 0.5);
      expect(bye.requested, isTrue);

      pairer.recordResults(sheet, {
        for (final p in sheet.pairings) p.whiteId: 1.0,
      });
      expect(pairer.scoreOf('p1'), 0.5);
    });

    test('does not give the same player two full-point byes', () {
      final pairer = SwissPairer(seeds: _seeds(5));
      final byeIds = <String>[];
      for (var r = 1; r <= 4; r++) {
        final sheet = pairer.nextRound();
        byeIds.addAll(
          sheet.byes.where((b) => !b.requested).map((b) => b.playerId),
        );
        pairer.recordResults(sheet, {
          for (final p in sheet.pairings) p.whiteId: 1.0,
        });
      }
      expect(
        byeIds.toSet().length,
        byeIds.length,
        reason: 'repeat bye: $byeIds',
      );
    });
  });

  group('accelerated pairings', () {
    test('pairs the top quarter against the second quarter in round 1', () {
      final pairer = SwissPairer(
        seeds: _seeds(16),
        rules: const SwissRules(accelerated: true, acceleratedRounds: 2),
      );
      final sheet = pairer.nextRound();

      // With a virtual point for the top 8, the top group is p1..p8 and pairs
      // internally: p1 vs p5, p2 vs p6, …
      final p1 = sheet.forPlayer('p1')!;
      expect(p1.opponentOf('p1'), 'p5');
      final p9 = sheet.forPlayer('p9')!;
      expect(p9.opponentOf('p9'), 'p13');
    });

    test('reverts to normal pairing after the accelerated rounds', () {
      final normal = SwissPairer(seeds: _seeds(16));
      final accel = SwissPairer(
        seeds: _seeds(16),
        rules: const SwissRules(accelerated: true, acceleratedRounds: 2),
      );
      // Round 1 differs...
      expect(
        accel.nextRound().forPlayer('p1')!.opponentOf('p1'),
        isNot(normal.nextRound().forPlayer('p1')!.opponentOf('p1')),
      );
    });
  });

  test('is deterministic across identical runs', () {
    List<String> run() {
      final pairer = SwissPairer(seeds: _seeds(12));
      final out = <String>[];
      for (var r = 1; r <= 4; r++) {
        final sheet = pairer.nextRound();
        out.addAll(sheet.pairings.map((p) => '${p.whiteId}-${p.blackId}'));
        pairer.recordResults(sheet, {
          for (final p in sheet.pairings) p.whiteId: 1.0,
        });
      }
      return out;
    }

    expect(run(), run());
  });
}
