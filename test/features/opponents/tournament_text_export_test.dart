import 'package:chess_auto_prep/features/opponents/models/person_record.dart';
import 'package:chess_auto_prep/features/opponents/models/tournament.dart';
import 'package:chess_auto_prep/features/opponents/services/tournament_text_export.dart';
import 'package:flutter_test/flutter_test.dart';

/// The text export is what the user keeps after the event: the field as a
/// table, then notes and prep lines per opponent. Pin its shape.
void main() {
  test('renders the table and one section per opponent', () {
    final now = DateTime(2026, 9, 4);
    final jane = PersonRecord(
      id: 'j',
      name: 'Jane Doe',
      uscfId: '12345678',
      chesscom: 'janed',
      rating: 1850,
      notes: 'Plays the London.',
      createdAt: now,
      updatedAt: now,
    );
    final bob = PersonRecord(
      id: 'b',
      name: 'Bob | Roe',
      lichess: 'bobr',
      createdAt: now,
      updatedAt: now,
    );
    final t = Tournament(
      id: 'spring-open-2026',
      name: 'Spring Open 2026',
      date: '2026-04-12',
      rounds: 5,
      entries: [
        const TournamentEntry(
          personId: 'j',
          rating: 1850,
          pairingProb: 0.42,
          likelyRound: 2,
          prepared: true,
        ),
        const TournamentEntry(personId: 'b', rating: 1700),
      ],
      createdAt: now,
      updatedAt: now,
    );
    final text = renderTournamentText(t, [
      TournamentTextRow(
        person: jane,
        entry: t.entries[0],
        gameCount: 120,
        chapters: const [
          PrepChapterText(
            name: 'As White',
            movetext: '1. d4 d5 2. Bf4 {her London}',
          ),
          PrepChapterText(name: 'As Black', movetext: ''),
        ],
      ),
      TournamentTextRow(person: bob, entry: t.entries[1]),
    ], now: now);

    expect(
      text,
      startsWith(
        '# Spring Open 2026\n\n2026-04-12 · 5 rounds · 2 opponents · 1 prepared\n',
      ),
    );
    expect(
      text,
      contains('| 1 | Jane Doe | 1850 | 12345678 | janed |  | 42% | yes |'),
    );
    expect(text, contains(r'| 2 | Bob \| Roe | 1700 |  |  | bobr |  |  |'));
    expect(
      text,
      contains(
        '## Jane Doe\n\n1850 · USCF 12345678 · chess.com janed · likely round 2 · 42% to face · 120 games downloaded · prepared\n\nPlays the London.\n',
      ),
    );
    expect(text, contains('### As White\n\n1. d4 d5 2. Bf4 {her London}\n'));
    expect(text, contains('### As Black\n\n(no moves yet)\n'));
    expect(text, contains('## Bob | Roe\n\n1700 · lichess bobr\n'));
  });
}
