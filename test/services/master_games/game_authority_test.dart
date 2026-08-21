import 'package:chess_auto_prep/services/master_games/game_authority.dart';
import 'package:flutter_test/flutter_test.dart';

/// The classifier decides what a repertoire is allowed to cite as theory, so
/// the cases here are drawn from the real corpus rather than invented: every
/// online venue in five years of TWIC writes its platform into `Site` and ends
/// it with the `INT` country code, and no over-the-board site does.
void main() {
  group('classifyAuthority', () {
    GameAuthority of(String site, String event) =>
        classifyAuthority(site: site, event: event);

    test('internet venues are online, whatever the event is called', () {
      for (final site in const [
        'chess.com INT',
        'lichess.org INT',
        'FIDE Online Arena INT',
        'Tornelo INT',
        'chess24.com INT',
        'Europe-Echecs INT',
        'ICC INT',
        // Engine events ride along in the same issues; they are certainly not
        // master practice.
        'tcec-chess.com INT',
        'CCC Int',
      ]) {
        expect(
          of(site, 'Some Classical Open'),
          GameAuthority.online,
          reason: site,
        );
      }
    });

    test('Titled Tuesday is online even before the event name is read', () {
      expect(
        of('chess.com INT', 'Titled Tue 16th Dec 2025'),
        GameAuthority.online,
      );
    });

    test('over-the-board speed events are their own tier', () {
      expect(of('Warsaw POL', 'World Blitz 2021'), GameAuthority.speedOtb);
      expect(of('Almaty KAZ', 'World Rapid 2022'), GameAuthority.speedOtb);
      expect(of('Riyadh KSA', 'Bullet Invitational'), GameAuthority.speedOtb);
      expect(of('Baku AZE', 'Armageddon Series'), GameAuthority.speedOtb);
    });

    test('esports events are rapid, however they are dressed up', () {
      expect(
        of('Paris FRA', 'Esports World Cup LCQ GpB'),
        GameAuthority.speedOtb,
      );
      expect(of('Oslo NOR', 'Oslo Esports Cup 2022'), GameAuthority.speedOtb);
      expect(
        of('Riyadh KSA', 'Esports World Cup 2025'),
        GameAuthority.speedOtb,
      );
    });

    test('substring markers do not swallow classical events', () {
      // Every one of these was a real near-miss when the marker list was
      // being chosen; between them they are ~3,500 classical games.
      expect(
        of('Reykjavik ISL', 'Kvika Reykjavik Open 2022'),
        GameAuthority.classical,
        reason: 'Kvika is the sponsoring bank, not a time control',
      );
      expect(
        of('Reykjavik ISL', 'TCh-ISL Kvika 2024-25'),
        GameAuthority.classical,
      );
      expect(
        of('Uppsala SWE', 'Uppsala Young Champions'),
        GameAuthority.classical,
      );
      expect(
        of('Khartoum SUD', 'Arab Championship 2023'),
        GameAuthority.classical,
      );
      expect(
        of('Izmir TUR', 'Satranc Arena IM Chess 12'),
        GameAuthority.classical,
      );
      expect(of('Minsk BLR', 'Minsk Open 2023'), GameAuthority.classical);
      expect(
        of('Rotterdam NED', 'V Mindsports Int Open'),
        GameAuthority.classical,
      );
      expect(
        of('Bohumin CZE', '6th Bohumin Open 2023'),
        GameAuthority.classical,
      );
    });

    test('an ordinary open is classical, and it is the only citable tier', () {
      expect(
        of('Pardubice CZE', '36th Czech Open A 2025'),
        GameAuthority.classical,
      );
      expect(
        of('Wijk aan Zee NED', 'Tata Steel Masters'),
        GameAuthority.classical,
      );

      expect(GameAuthority.classical.isCitable, isTrue);
      expect(GameAuthority.speedOtb.isCitable, isFalse);
      expect(GameAuthority.online.isCitable, isFalse);
    });

    test('a site that merely contains "int" is not online', () {
      // Otherwise every Flint, Sprint or Pinto would be read as a server.
      expect(of('Flint USA', 'City Championship'), GameAuthority.classical);
      expect(of('Pinto ESP', 'Open'), GameAuthority.classical);
    });

    test(
      'missing headers degrade to classical rather than dropping a game',
      () {
        expect(of('', ''), GameAuthority.classical);
      },
    );

    test('codes round-trip, and an unknown code is not a crash', () {
      for (final a in GameAuthority.values) {
        expect(GameAuthority.fromCode(a.code), a);
      }
      expect(GameAuthority.fromCode(99), GameAuthority.classical);
      expect(GameAuthority.fromCode(-1), GameAuthority.classical);
    });
  });
}
