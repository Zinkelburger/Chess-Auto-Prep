import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/models/position_analysis.dart';
import 'package:chess_auto_prep/services/unified_analysis_builder.dart';

const _asWhitePgn = '''
[Event "Rated blitz game"]
[White "TestUser"]
[Black "Opponent1"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 1-0
''';

const _asBlackPgn = '''
[Event "Rated blitz game"]
[White "Opponent2"]
[Black "TestUser"]
[Result "0-1"]

1. e4 c5 2. Nf3 d6 0-1
''';

const _asWhiteAgainPgn = '''
[Event "Rated rapid game"]
[White "TestUser"]
[Black "Opponent3"]
[Result "1/2-1/2"]

1. e4 e5 2. Nf3 Nf6 1/2-1/2
''';

// Neither player matches → ambiguous, counts for both colours.
const _ambiguousPgn = '''
[Event "Casual game"]
[White "SomeoneElse"]
[Black "AnotherPlayer"]
[Result "1-0"]

1. d4 d5 2. c4 e6 1-0
''';

const _pgnList = [_asWhitePgn, _asBlackPgn, _asWhiteAgainPgn, _ambiguousPgn];

void _expectAnalysisEquals(PositionAnalysis actual, PositionAnalysis expected) {
  expect(
    actual.positionStats.keys.toSet(),
    expected.positionStats.keys.toSet(),
  );
  for (final entry in expected.positionStats.entries) {
    final a = actual.positionStats[entry.key]!;
    expect(a.games, entry.value.games, reason: 'games for ${entry.key}');
    expect(a.wins, entry.value.wins, reason: 'wins for ${entry.key}');
    expect(a.losses, entry.value.losses, reason: 'losses for ${entry.key}');
    expect(a.draws, entry.value.draws, reason: 'draws for ${entry.key}');
  }
  expect(actual.fenToGameIndices, expected.fenToGameIndices);
  expect(actual.games.length, expected.games.length);
}

void _expectTreeEquals(OpeningTreeNode actual, OpeningTreeNode expected) {
  expect(actual.move, expected.move);
  expect(actual.gamesPlayed, expected.gamesPlayed);
  expect(actual.wins, expected.wins);
  expect(actual.losses, expected.losses);
  expect(actual.draws, expected.draws);
  expect(actual.children.keys.toSet(), expected.children.keys.toSet());
  for (final key in expected.children.keys) {
    _expectTreeEquals(actual.children[key]!, expected.children[key]!);
  }
}

void main() {
  group('buildBoth', () {
    test('matches the per-colour single builds', () {
      final (whiteAnalysis, whiteTree) = UnifiedAnalysisBuilder.build(
        pgnList: _pgnList,
        username: 'TestUser',
        isWhite: true,
      );
      final (blackAnalysis, blackTree) = UnifiedAnalysisBuilder.build(
        pgnList: _pgnList,
        username: 'TestUser',
        isWhite: false,
      );

      final bundle = UnifiedAnalysisBuilder.buildBoth(
        pgnList: _pgnList,
        username: 'TestUser',
      );

      _expectAnalysisEquals(bundle.whiteAnalysis, whiteAnalysis);
      _expectAnalysisEquals(bundle.blackAnalysis, blackAnalysis);
      _expectTreeEquals(bundle.whiteTree.root, whiteTree.root);
      _expectTreeEquals(bundle.blackTree.root, blackTree.root);
    });

    test('ambiguous games count for both colours', () {
      final bundle = UnifiedAnalysisBuilder.buildBoth(
        pgnList: _pgnList,
        username: 'TestUser',
      );

      // White: two own games + the ambiguous one; Black: one + ambiguous.
      expect(bundle.whiteTree.totalGames, 3);
      expect(bundle.blackTree.totalGames, 2);
    });

    test('fenToGameIndices holds no duplicate game indices', () {
      final bundle = UnifiedAnalysisBuilder.buildBoth(
        pgnList: _pgnList,
        username: 'TestUser',
      );

      for (final analysis in [bundle.whiteAnalysis, bundle.blackAnalysis]) {
        for (final entry in analysis.fenToGameIndices.entries) {
          expect(
            entry.value.toSet().length,
            entry.value.length,
            reason: 'duplicate index for ${entry.key}',
          );
        }
      }
    });
  });

  group('buildBothInIsolate + loadCachedBundle', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('uab_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test(
      'cache written by the build round-trips through loadCachedBundle',
      () async {
        final pgnPath = '${tempDir.path}/games.pgn';
        final whiteCachePath = '${tempDir.path}/white_analysis.json';
        final blackCachePath = '${tempDir.path}/black_analysis.json';
        await File(pgnPath).writeAsString(_pgnList.join('\n\n'));

        final built = await UnifiedAnalysisBuilder.buildBothInIsolate(
          pgnFilePath: pgnPath,
          username: 'TestUser',
          whiteCachePath: whiteCachePath,
          blackCachePath: blackCachePath,
        );

        expect(File(whiteCachePath).existsSync(), isTrue);
        expect(File(blackCachePath).existsSync(), isTrue);

        final cached = await UnifiedAnalysisBuilder.loadCachedBundle(
          pgnFilePath: pgnPath,
          whiteCachePath: whiteCachePath,
          blackCachePath: blackCachePath,
        );

        expect(cached, isNotNull);
        _expectAnalysisEquals(cached!.whiteAnalysis, built.whiteAnalysis);
        _expectAnalysisEquals(cached.blackAnalysis, built.blackAnalysis);
        _expectTreeEquals(cached.whiteTree.root, built.whiteTree.root);
        _expectTreeEquals(cached.blackTree.root, built.blackTree.root);
      },
    );

    test('cache misses when the PGN file changed after the build', () async {
      final pgnPath = '${tempDir.path}/games.pgn';
      final whiteCachePath = '${tempDir.path}/white_analysis.json';
      final blackCachePath = '${tempDir.path}/black_analysis.json';
      await File(pgnPath).writeAsString(_pgnList.join('\n\n'));

      await UnifiedAnalysisBuilder.buildBothInIsolate(
        pgnFilePath: pgnPath,
        username: 'TestUser',
        whiteCachePath: whiteCachePath,
        blackCachePath: blackCachePath,
      );

      // Simulate a re-download: different content → different size.
      await File(pgnPath).writeAsString('$_asWhitePgn\n\n$_asBlackPgn');

      final cached = await UnifiedAnalysisBuilder.loadCachedBundle(
        pgnFilePath: pgnPath,
        whiteCachePath: whiteCachePath,
        blackCachePath: blackCachePath,
      );

      expect(cached, isNull);
    });

    test('loadCachedBundle returns null when caches are absent', () async {
      final pgnPath = '${tempDir.path}/games.pgn';
      await File(pgnPath).writeAsString(_asWhitePgn);

      final cached = await UnifiedAnalysisBuilder.loadCachedBundle(
        pgnFilePath: pgnPath,
        whiteCachePath: '${tempDir.path}/missing_white.json',
        blackCachePath: '${tempDir.path}/missing_black.json',
      );

      expect(cached, isNull);
    });

    test('build throws on a PGN file with no games', () async {
      final pgnPath = '${tempDir.path}/empty.pgn';
      await File(pgnPath).writeAsString('');

      await expectLater(
        UnifiedAnalysisBuilder.buildBothInIsolate(
          pgnFilePath: pgnPath,
          username: 'TestUser',
        ),
        throwsA(isA<Exception>()),
      );
    });
  });
}
