import 'package:chess_auto_prep/features/tournament/models/roster_entry.dart';
import 'package:chess_auto_prep/features/tournament/services/event_simulator.dart';
import 'package:flutter_test/flutter_test.dart';

/// A field of `count` players 50 points apart, with `meIndex` flagged as us.
Roster _field(
  int count, {
  int meIndex = 0,
  int rounds = 5,
  bool accelerated = false,
  List<PairingConstraint> constraints = const [],
}) => Roster(
  eventName: 'Test Open',
  rounds: rounds,
  accelerated: accelerated,
  constraints: constraints,
  entries: [
    for (var i = 0; i < count; i++)
      RosterEntry(
        id: 'p${i + 1}',
        name: 'Player ${i + 1}',
        rating: 2000 - i * 50,
        isMe: i == meIndex,
      ),
  ],
);

const _fast = SimulationConfig(trials: 400);

void main() {
  test('round 1 is a near-certain pairing against the half-split opponent', () {
    // 16 players, we are the top seed: round 1 must be p1 vs p9 every time.
    final result = EventSimulator.run(_field(16), config: _fast);

    final p9 = result.opponents.firstWhere((o) => o.playerId == 'p9');
    expect(p9.probByRound[0], 1.0);
    expect(p9.mostLikelyRound, 1);
  });

  test('later rounds diffuse across many opponents', () {
    final result = EventSimulator.run(_field(16), config: _fast);

    final round1Opponents = result.opponents
        .where((o) => o.probByRound[0] > 0)
        .length;
    final round4Opponents = result.opponents
        .where((o) => o.probByRound[3] > 0)
        .length;

    expect(round1Opponents, 1);
    expect(
      round4Opponents,
      greaterThan(2),
      reason: 'round 4 should spread over several plausible opponents',
    );
  });

  test('probabilities are bounded and rounds sum to at most one', () {
    final result = EventSimulator.run(_field(20), config: _fast);

    for (final o in result.opponents) {
      expect(o.probAny, inInclusiveRange(0.0, 1.0));
      // You cannot face the same person twice, so per-opponent round
      // probabilities must sum to probAny.
      final sum = o.probByRound.fold<double>(0, (s, p) => s + p);
      expect(sum, closeTo(o.probAny, 1e-9));
      expect(o.probAsWhite + o.probAsBlack, closeTo(o.probAny, 1e-9));
    }
  });

  test('total pairing mass equals the number of rounds played', () {
    const rounds = 5;
    final result = EventSimulator.run(
      _field(20, rounds: rounds),
      config: _fast,
    );

    final total = result.opponents.fold<double>(0, (s, o) => s + o.probAny);
    // Every round produces exactly one opponent unless we got a bye.
    expect(total, closeTo(rounds - result.byeProb * 1, 0.05));
  });

  test('a stronger player scores more than a weaker one', () {
    final strong = EventSimulator.run(_field(16, meIndex: 0), config: _fast);
    final weak = EventSimulator.run(_field(16, meIndex: 15), config: _fast);

    expect(strong.expectedScore, greaterThan(weak.expectedScore));
  });

  test('rounds 2+ pull opponents toward our own strength', () {
    // Round 1 is a deliberate top-half/bottom-half split, so the top seed
    // meets the middle of the field by design. From round 2 the score groups
    // take over and a winning top seed should meet distinctly stronger
    // players than the field average.
    final result = EventSimulator.run(_field(24, meIndex: 0), config: _fast);
    final ratings = {for (var i = 0; i < 24; i++) 'p${i + 1}': 2000 - i * 50};

    var mass = 0.0;
    var weighted = 0.0;
    for (final o in result.opponents) {
      // Skip round 1, which is structural rather than strength-driven.
      final laterMass = o.probAny - o.probByRound[0];
      if (laterMass <= 0) continue;
      mass += laterMass;
      weighted += laterMass * ratings[o.playerId]!;
    }

    final meanOpponent = weighted / mass;
    final fieldMean = ratings.values.reduce((a, b) => a + b) / ratings.length;

    expect(
      meanOpponent,
      greaterThan(fieldMean + 100),
      reason:
          'top seed met mean ${meanOpponent.round()} vs field mean '
          '${fieldMean.round()} — score groups should concentrate the strong',
    );
  });

  test('a withhold constraint removes that opponent entirely', () {
    final result = EventSimulator.run(
      _field(
        16,
        constraints: const [PairingConstraint('p1', 'p9', reason: 'siblings')],
      ),
      config: _fast,
    );

    final p9 = result.opponents.where((o) => o.playerId == 'p9');
    expect(
      p9.isEmpty || p9.first.probAny < 0.02,
      isTrue,
      reason: 'a forbidden pairing should essentially never occur',
    );
  });

  test('withdrawn players are never faced', () {
    final base = _field(16);
    final roster = base.copyWith(
      entries: base.entries
          .map((e) => e.id == 'p9' ? e.copyWith(withdrawn: true) : e)
          .toList(),
    );

    final result = EventSimulator.run(roster, config: _fast);
    expect(result.opponents.where((o) => o.playerId == 'p9'), isEmpty);
  });

  test('attendance probability scales how often a player is faced', () {
    final base = _field(16);
    final roster = base.copyWith(
      entries: base.entries
          .map((e) => e.id == 'p9' ? e.copyWith(attendanceProb: 0.5) : e)
          .toList(),
    );

    final result = EventSimulator.run(
      roster,
      config: const SimulationConfig(trials: 2000),
    );
    final p9 = result.opponents.firstWhere((o) => o.playerId == 'p9');
    // Round 1 against p9 is otherwise certain, so P(face in R1) tracks
    // attendance directly.
    expect(p9.probByRound[0], closeTo(0.5, 0.06));
  });

  test('sections are simulated independently', () {
    final roster = Roster(
      rounds: 3,
      entries: [
        for (var i = 0; i < 8; i++)
          RosterEntry(
            id: 'open$i',
            name: 'Open $i',
            rating: 2000 - i * 50,
            section: 'Open',
            isMe: i == 0,
          ),
        for (var i = 0; i < 8; i++)
          RosterEntry(
            id: 'u1600-$i',
            name: 'U1600 $i',
            rating: 1500 - i * 50,
            section: 'U1600',
          ),
      ],
    );

    final result = EventSimulator.run(roster, config: _fast);
    expect(
      result.opponents.every((o) => o.playerId.startsWith('open')),
      isTrue,
      reason: 'never paired across sections',
    );
    expect(result.notes.join(), contains('Open'));
  });

  test('reports when there is no reference player', () {
    final roster = Roster(
      entries: const [RosterEntry(id: 'a', name: 'A', rating: 1500)],
    );
    final result = EventSimulator.run(roster, config: _fast);
    expect(result.opponents, isEmpty);
    expect(result.notes.join(), contains('marked as you'));
  });

  test('unrated entrants are seeded and reported', () {
    final roster = Roster(
      rounds: 3,
      entries: const [
        RosterEntry(id: 'a', name: 'A', rating: 2000, isMe: true),
        RosterEntry(id: 'b', name: 'B', rating: 1800),
        RosterEntry(id: 'c', name: 'C'),
        RosterEntry(id: 'd', name: 'D', rating: 1600),
      ],
    );
    final result = EventSimulator.run(roster, config: _fast);
    expect(result.notes.join(), contains('unrated'));
    expect(result.opponents.map((o) => o.playerId), contains('c'));
  });

  test('is reproducible for a fixed seed and varies with a different one', () {
    List<double> probs(int seed) => EventSimulator.run(
      _field(16),
      config: SimulationConfig(trials: 300, seed: seed),
    ).opponents.map((o) => o.probAny).toList();

    expect(probs(1), probs(1));
    expect(probs(1), isNot(probs(2)));
  });

  test('topByCoverage returns the smallest set covering the mass', () {
    final result = EventSimulator.run(_field(24, meIndex: 11), config: _fast);
    final all = result.opponents.fold<double>(0, (s, o) => s + o.probAny);
    final top = result.topByCoverage(0.8);

    final covered = top.fold<double>(0, (s, o) => s + o.probAny);
    expect(covered / all, greaterThanOrEqualTo(0.8));
    expect(top.length, lessThan(result.opponents.length));
  });

  test('an unsectioned player in a sectioned event is warned, not misled', () {
    // Over-including is the safe direction, but the note must say so rather
    // than claim a filter that did not happen.
    final roster = Roster(
      rounds: 3,
      entries: [
        const RosterEntry(id: 'me', name: 'Me', rating: 1900, isMe: true),
        for (var i = 0; i < 6; i++)
          RosterEntry(
            id: 'open$i',
            name: 'Open $i',
            rating: 2000 - i * 50,
            section: 'Open',
          ),
        for (var i = 0; i < 6; i++)
          RosterEntry(
            id: 'u1200-$i',
            name: 'U1200 $i',
            rating: 1100 - i * 50,
            section: 'U1200',
          ),
      ],
    );

    final result = EventSimulator.run(roster, config: _fast);
    final notes = result.notes.join();

    expect(notes, contains('no section'));
    expect(notes, contains('ALL'));
    expect(
      notes,
      isNot(contains('only')),
      reason: 'must not claim a section filter that did not happen',
    );
  });
}
