/// Covers the directory's lookup logic *and* the real bundled asset.
///
/// The asset is the feature's only shipped data file, so a malformed or
/// mis-declared one would break identity resolution everywhere while every
/// fixture-based test kept passing.
library;

import 'package:chess_auto_prep/features/tournament/models/player_identity.dart';
import 'package:chess_auto_prep/features/tournament/services/player_directory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('bundled asset', () {
    late PlayerDirectory directory;

    setUpAll(() async {
      directory = await PlayerDirectory.ensureLoaded();
    });

    test('loads and is not trivially small', () {
      // If this drops sharply, the generator or the pubspec declaration broke.
      expect(directory.playerCount, greaterThan(3000));
      expect(directory.titledCount, greaterThan(10000));
      expect(directory.eventsProcessed, greaterThan(1000));
    });

    test('every shipped row has a username and a confidence we trust', () {
      // The generator filters to exact/high/medium; a row without a username
      // is dead weight in the asset.
      final sample = directory.search('a', limit: 50);
      expect(sample, isNotEmpty);
      for (final e in sample) {
        expect(e.chesscomUsername, isNotEmpty);
        expect(
          ['exact', 'high', 'medium'],
          contains(e.confidence),
          reason: '${e.uscfId} shipped with confidence "${e.confidence}"',
        );
      }
    });

    test('a known row resolves by id, name and username alike', () {
      // Verified against the real mapping data: this player resolved via
      // opponent-graph matching in a Dec 2023 USCF event.
      final byId = directory.byUscfId('17182781');
      expect(byId, isNotNull, reason: 'known mapped player missing');
      expect(byId!.chesscomUsername, 'Jianda2019');
      expect(byId.method, 'opponent_graph');
      expect(byId.confidence, 'exact');

      expect(
        directory.byChesscomUsername('Jianda2019')?.uscfId,
        '17182781',
        reason: 'reverse lookup must agree',
      );
      expect(
        directory.byChesscomUsername('JIANDA2019')?.uscfId,
        '17182781',
        reason: 'usernames are case-insensitive',
      );
    });

    test('resolve() on a real id yields an actionable identity', () {
      final identity = directory.resolve(uscfId: '17182781')!;
      expect(identity.chesscomUsername, 'Jianda2019');
      expect(identity.source, IdentitySource.uscfOnlineEvent);
      expect(identity.confidence, IdentityConfidence.exact);
      expect(identity.isActionable, isTrue);
      expect(identity.evidence, contains('opponent_graph'));
    });

    test('an unknown id simply misses', () {
      expect(directory.byUscfId('99999999'), isNull);
      expect(directory.resolve(uscfId: '99999999'), isNull);
    });

    test('titles are joined onto the accounts that have them', () {
      final withTitle = directory
          .search('a', limit: 400)
          .where((e) => e.title != null);
      for (final e in withTitle) {
        expect(['GM', 'IM', 'FM', 'NM', 'CM'], contains(e.title));
      }
    });
  });

  group('lookup semantics', () {
    final directory = PlayerDirectory.fromJson(
      mapping: {
        'events_processed': 10,
        'players': {
          '11111111': {
            'u': 'alpha',
            'n': 'John Smith',
            'c': 'exact',
            'm': 'opponent_graph',
            'e': '202401010001',
            'd': '2024-01-01',
          },
          '22222222': {
            'u': 'beta',
            'n': 'Smith, John',
            'c': 'exact',
            'm': 'signature',
          },
          '33333333': {
            'u': 'gamma',
            'n': 'Jane Doe',
            'c': 'medium',
            'm': 'score_position',
          },
        },
      },
      titled: {
        'titles': {'gamma': 'IM'},
      },
    );

    test('a name shared by two people is ambiguous, not a guess', () {
      final match = directory.byName('John Smith');
      expect(match.entries, hasLength(2));
      expect(match.isUnique, isFalse);

      final identity = directory.resolve(name: 'John Smith')!;
      expect(identity.confidence, IdentityConfidence.ambiguous);
      expect(identity.hasAccount, isFalse);
      expect(identity.alternates, hasLength(2));
      expect(identity.isActionable, isFalse);
    });

    test('a unique name match is downgraded below an id match', () {
      // The row is exact; our claim that it is *this* entrant is not.
      final identity = directory.resolve(name: 'Jane Doe')!;
      expect(identity.chesscomUsername, 'gamma');
      expect(identity.confidence, IdentityConfidence.medium);
      expect(identity.evidence, contains('matched on name'));
    });

    test('an id match beats a name that would have been ambiguous', () {
      final identity = directory.resolve(
        uscfId: '11111111',
        name: 'John Smith',
      )!;
      expect(identity.chesscomUsername, 'alpha');
      expect(identity.confidence, IdentityConfidence.exact);
    });

    test('falls back to the name when the id is unknown', () {
      final identity = directory.resolve(uscfId: '00000000', name: 'Jane Doe')!;
      expect(identity.chesscomUsername, 'gamma');
    });

    test('titles decorate the entry', () {
      expect(directory.byUscfId('33333333')!.title, 'IM');
      expect(directory.titleFor('GAMMA'), 'IM');
      expect(directory.titleFor('alpha'), isNull);
    });

    test('search covers id, name and username', () {
      expect(directory.search('11111111').single.chesscomUsername, 'alpha');
      expect(directory.search('beta').single.uscfId, '22222222');
      expect(directory.search('jane').single.chesscomUsername, 'gamma');
      expect(directory.search(''), isEmpty);
      expect(directory.search('zzzz'), isEmpty);
    });

    test('search honours its limit', () {
      expect(directory.search('a', limit: 1), hasLength(1));
    });

    test('an empty directory answers everything with a miss', () {
      const empty = PlayerDirectory.empty();
      expect(empty.playerCount, 0);
      expect(empty.byUscfId('11111111'), isNull);
      expect(empty.byName('John Smith').isEmpty, isTrue);
      expect(empty.resolve(uscfId: '1', name: 'x'), isNull);
      expect(empty.search('anything'), isEmpty);
    });
  });
}
