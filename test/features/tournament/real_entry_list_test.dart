/// Pins the parser against a real US Chess event entry list.
///
/// This format is why the test exists: FIDE ID sits *before* USCF ID and both
/// are 7–9 digits, FIDE rating sits before USCF rating, ratings carry `[EQ]`
/// annotations or read `Unr`, and the name column smuggles in `(WCM)` and
/// `(Withdrawn)`. Every one of those quietly produced wrong data before.
library;

import 'package:chess_auto_prep/features/tournament/services/roster_import.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tab-separated, exactly as the event page renders it.
const _entryList =
    "Player's Name\tFIDE ID\tFIDE Rating\tUSCF ID\tUSCF Rating\tState\t"
    'Section\tSchedule\tBye(s)\n'
    'Anatra, Owen Chance\t30997160 [USA]\t1807\t30379415\t1858\tCT\t'
    'Under 2100\t4 Day\t\n'
    'Bernal, Andrew\t30992060 [USA]\t1866\t16009740\t1977\tMA\t'
    'Under 2100\t3 Day\t\n'
    'Farley, Jeremiah\t11106972 [BAR]\t1835\t33132698\t1900 [EQ]\t\t'
    'Under 2100\t4 Day\t\n'
    'Grennan, Rhyan\t566023718 [USA]\tUnr\t16448236\t1907\tNY\t'
    'Under 2100\t3 Day\t\n'
    'Herve-mignucci, Calliste\t3263177 [AUS]\t1719\t16787928\t1930\tCT\t'
    'Under 2100\t4 Day\t1/2:R1\n'
    'Sandeep Kumar, Arav (Withdrawn)\t39963470 [USA]\t1646\t31425499\t1700\tNJ\t'
    'Under 2100\t4 Day\t1/2:R1\n'
    'Tereshchenko, Eliza (WCM) (Withdrawn)\t34389890 [FID]\t1924\t33203591\t'
    '2000 [EQ]\tMA\tUnder 2100\t4 Day\t\n';

void main() {
  late RosterImportResult result;

  setUp(() {
    result = RosterImporter.parse(
      _entryList,
      eventName: 'Test Open',
      rounds: 5,
      myUscfId: '16009740',
    );
  });

  test('parses through the header path, not the freeform fallback', () {
    // The freeform parser cannot tell a FIDE ID from a USCF ID; only the
    // header row disambiguates them.
    expect(result.format, 'csv');
    expect(result.roster.entries, hasLength(7));
  });

  test('takes the USCF ID, not the FIDE ID that precedes it', () {
    final anatra = result.roster.entries.first;
    expect(anatra.name, 'Anatra, Owen Chance');
    expect(anatra.uscfId, '30379415');
    expect(anatra.uscfId, isNot('30997160'), reason: 'that is the FIDE ID');
    expect(anatra.id, '30379415');
  });

  test('takes the USCF rating, not the FIDE rating that precedes it', () {
    final anatra = result.roster.entries.first;
    expect(anatra.rating, 1858);
    expect(anatra.rating, isNot(1807), reason: 'that is the FIDE rating');
  });

  test('reads a rating annotated [EQ] rather than discarding it', () {
    final farley = result.roster.entries.firstWhere(
      (e) => e.name.startsWith('Farley'),
    );
    expect(farley.rating, 1900);
    expect(
      result.warnings.join(),
      isNot(contains('1900')),
      reason: '[EQ] is an annotation, not an unreadable value',
    );
  });

  test('an "Unr" FIDE rating does not leak into the USCF rating', () {
    final grennan = result.roster.entries.firstWhere(
      (e) => e.name.startsWith('Grennan'),
    );
    expect(grennan.rating, 1907);
    expect(grennan.uscfId, '16448236');
  });

  test('a blank state column does not shift the other fields', () {
    final farley = result.roster.entries.firstWhere(
      (e) => e.name.startsWith('Farley'),
    );
    expect(farley.uscfId, '33132698');
    expect(farley.section, 'Under 2100');
  });

  test('(Withdrawn) becomes a flag and leaves the name clean', () {
    final arav = result.roster.entries.firstWhere(
      (e) => e.name.startsWith('Sandeep'),
    );
    expect(arav.name, 'Sandeep Kumar, Arav');
    expect(arav.withdrawn, isTrue);
    expect(result.roster.active.map((e) => e.name), isNot(contains(arav.name)));
  });

  test('(WCM) becomes a title, alongside a withdrawal on the same cell', () {
    final eliza = result.roster.entries.firstWhere(
      (e) => e.name.startsWith('Tereshchenko'),
    );
    expect(eliza.name, 'Tereshchenko, Eliza');
    expect(eliza.title, 'WCM');
    expect(eliza.withdrawn, isTrue);
    expect(eliza.rating, 2000);
  });

  test('finds me by USCF ID', () {
    expect(result.roster.me?.name, 'Bernal, Andrew');
    expect(result.roster.me?.rating, 1977);
    expect(result.roster.entries.where((e) => e.isMe), hasLength(1));
  });

  test('withdrawals are excluded from the pairing pool', () {
    expect(result.roster.entries, hasLength(7));
    expect(result.roster.active, hasLength(5));
  });

  test('a hyphenated surname survives the join key', () {
    final calliste = result.roster.entries.firstWhere(
      (e) => e.name.startsWith('Herve'),
    );
    expect(calliste.name, 'Herve-mignucci, Calliste');
    expect(calliste.uscfId, '16787928');
    expect(calliste.rating, 1930);
  });

  test('parses cleanly, with no warnings about this format', () {
    expect(
      result.warnings,
      isEmpty,
      reason: 'warnings were: ${result.warnings}',
    );
  });
}
