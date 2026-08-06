import 'package:chess_auto_prep/features/tournament/models/player_identity.dart';
import 'package:chess_auto_prep/features/tournament/models/roster_entry.dart';
import 'package:chess_auto_prep/features/tournament/services/player_name.dart';
import 'package:chess_auto_prep/features/tournament/services/roster_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('name normalization', () {
    test('collapses the two orderings to one key', () {
      // The directory stores "First Middle Last"; entry lists publish
      // "Last, First". Both must land on the same key.
      expect(
        playerNameKey('VIDIP KUMAR KONA'),
        playerNameKey('Kona, Vidip Kumar'),
      );
      expect(
        playerNameKey('Justin Weicheng Zhang'),
        playerNameKey('Zhang, Justin'),
      );
    });

    test('ignores case, punctuation and generational suffixes', () {
      expect(playerNameKey("O'Brien, Sean"), playerNameKey('Sean OBrien'));
      expect(playerNameKey('John Smith Jr.'), playerNameKey('Smith, John'));
      expect(
        playerNameKey('Anne-Marie Dubois'),
        playerNameKey('Dubois, Anne Marie'),
      );
    });

    test('keeps multi-word surnames together when a comma marks them', () {
      final parsed = parsePlayerName('Van Der Berg, Jan');
      expect(parsed.first, 'JAN');
      expect(parsed.last, 'VANDERBERG');
    });

    test('distinguishes different people', () {
      expect(playerNameKey('John Smith'), isNot(playerNameKey('Jane Smith')));
      expect(playerNameKey('John Smith'), isNot(playerNameKey('John Smyth')));
    });

    test('survives empty and single-token input', () {
      expect(parsePlayerName('').isEmpty, isTrue);
      expect(parsePlayerName('   ').isEmpty, isTrue);
      expect(parsePlayerName('Magnus').last, 'MAGNUS');
    });
  });

  group('CSV import', () {
    test('reads a standard export', () {
      const csv = '''
Name,USCF ID,Rating,Section
"Smith, John",12345678,1850,Open
"Doe, Jane",87654321,2010,Open
"Roe, Rick",11112222,1490,U1600
''';
      final result = RosterImporter.parse(csv, eventName: 'Spring Open');

      expect(result.format, 'csv');
      expect(result.roster.entries, hasLength(3));

      final john = result.roster.entries.first;
      expect(john.name, 'Smith, John');
      expect(john.uscfId, '12345678');
      expect(john.rating, 1850);
      expect(john.section, 'Open');
      expect(john.id, '12345678', reason: 'USCF ID is the stable key');

      expect(result.roster.sections, ['Open', 'U1600']);
    });

    test('accepts alternative header spellings', () {
      const csv = '''
Player,Member ID,Rtg
Alice Brown,12345678,1700
''';
      final result = RosterImporter.parse(csv);
      expect(result.roster.entries.single.rating, 1700);
      expect(result.roster.entries.single.uscfId, '12345678');
    });

    test('treats explicit username columns as asserted, not inferred', () {
      const csv = '''
Name,Rating,chess.com
Alice Brown,1700,alicebrown99
''';
      final result = RosterImporter.parse(csv);
      final identity = result.roster.entries.single.identity!;

      expect(identity.chesscomUsername, 'alicebrown99');
      expect(identity.source, IdentitySource.manual);
      expect(identity.confidence, IdentityConfidence.exact);
      expect(identity.isActionable, isTrue);
    });

    test('warns rather than guessing when the rating is unreadable', () {
      const csv = '''
Name,Rating
Alice Brown,about 1700ish
''';
      final result = RosterImporter.parse(csv);
      expect(result.roster.entries.single.rating, isNull);
      expect(result.warnings.join(), contains('about 1700ish'));
    });

    test('an explicit "no rating" marker is not a parse failure', () {
      // "Unr" and a blank cell are the organizer stating a fact, not the
      // parser losing one — warning about them would train the user to
      // ignore the warning list.
      const csv = '''
Name,Rating
Alice Brown,Unr
Bob Green,
Carol White,unrated
''';
      final result = RosterImporter.parse(csv);
      expect(result.roster.entries.map((e) => e.rating), everyElement(isNull));
      expect(result.warnings.where((w) => w.contains('rating "')), isEmpty);
    });

    test('warns when there is no rating column at all', () {
      const csv = '''
Name,Section
Alice Brown,Open
''';
      final result = RosterImporter.parse(csv);
      expect(result.warnings.join(), contains('No rating column'));
    });
  });

  group('freeform import', () {
    test('parses a column-aligned entry list', () {
      const text = '''
1   Smith, John        12345678   1850
2   Doe, Jane          87654321   2010
3   Roe, Rick          11112222   1490
''';
      final result = RosterImporter.parse(text);

      expect(result.format, 'text');
      expect(result.roster.entries, hasLength(3));
      expect(result.roster.entries[1].name, 'Doe, Jane');
      expect(result.roster.entries[1].rating, 2010);
      expect(result.roster.entries[1].uscfId, '87654321');
    });

    test('parses space-separated lines and picks up titles', () {
      const text = '''
GM Hikaru Nakamura 12345678 2800
Jane Doe 87654321 2010
''';
      final result = RosterImporter.parse(text);

      expect(result.roster.entries.first.title, 'GM');
      expect(result.roster.entries.first.name, 'Hikaru Nakamura');
      expect(result.roster.entries.first.rating, 2800);
      expect(result.roster.entries[1].title, isNull);
    });

    test('reads provisional and slashed ratings', () {
      const text = '''
Alice Brown 12345678 1700P12
Bob Green 12345679 1650/24
''';
      final result = RosterImporter.parse(text);
      expect(result.roster.entries[0].rating, 1700);
      expect(result.roster.entries[1].rating, 1650);
    });

    test('does not mistake a rating for a USCF ID', () {
      const text = 'Alice Brown 1700';
      final result = RosterImporter.parse(text);
      expect(result.roster.entries.single.rating, 1700);
      expect(result.roster.entries.single.uscfId, isNull);
    });
  });

  group('identifiers and self-marking', () {
    test('gives entrants without a USCF ID a stable slug', () {
      const text = 'Alice Brown 1700\nBob Green 1650';
      final result = RosterImporter.parse(text);
      expect(result.roster.entries.map((e) => e.id), [
        'alice-brown',
        'bob-green',
      ]);
    });

    test('keeps duplicate names distinct', () {
      const text = 'Alice Brown 1700\nAlice Brown 1500';
      final result = RosterImporter.parse(text);
      final ids = result.roster.entries.map((e) => e.id).toList();
      expect(ids.toSet(), hasLength(2));
    });

    test('marks exactly one entrant as me, by USCF ID', () {
      const text = 'Alice Brown 12345678 1700\nBob Green 87654321 1650';
      final result = RosterImporter.parse(text, myUscfId: '87654321');

      expect(result.roster.me?.name, 'Bob Green');
      expect(result.roster.entries.where((e) => e.isMe), hasLength(1));
    });

    test('marks me by name when no id is given', () {
      const text = 'Alice Brown 1700\nBob Green 1650';
      final result = RosterImporter.parse(text, myName: 'Bob Green');
      expect(result.roster.me?.id, 'bob-green');
    });

    test('warns loudly when I am not on the list', () {
      const text = 'Alice Brown 1700';
      final result = RosterImporter.parse(text, myName: 'Nobody Here');
      expect(result.roster.me, isNull);
      expect(result.warnings.join(), contains('not found on the entry list'));
    });
  });

  test('empty input yields an empty roster and a warning', () {
    final result = RosterImporter.parse('   ');
    expect(result.roster.entries, isEmpty);
    expect(result.warnings, isNotEmpty);
  });

  test('roster survives a JSON round trip', () {
    const csv = '''
Name,USCF ID,Rating,Section
"Smith, John",12345678,1850,Open
''';
    final original = RosterImporter.parse(
      csv,
      eventName: 'Spring Open',
      rounds: 4,
      myUscfId: '12345678',
    ).roster;

    final restored = Roster.fromMap(original.toMap());
    expect(restored.eventName, 'Spring Open');
    expect(restored.rounds, 4);
    expect(restored.entries.single.uscfId, '12345678');
    expect(restored.me?.name, 'Smith, John');
  });
}
