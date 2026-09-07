import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/models/position_analysis.dart';
import 'package:chess_auto_prep/services/unified_analysis_builder.dart';
import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/utils/fen_utils.dart';

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

// A study chapter: it starts after 1. e4 e5, so it only has somewhere to hang
// once a game that reaches that position has gone into the tree.
const _chapterPgn = '''
[Event "Study chapter"]
[White "TestUser"]
[Black "Opponent4"]
[Result "1-0"]
[FEN "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"]

2. Nf3 Nc6 1-0
''';

const _reachesChapterPgn = '''
[Event "Rated blitz game"]
[White "TestUser"]
[Black "Opponent5"]
[Result "1-0"]

1. e4 e5 2. Bc4 Bc5 1-0
''';

// A redundant [FEN] header naming the standard start — an ordinary game in a
// chapter's clothes, which exported collections produce all the time.
const _redundantFenHeaderPgn = '''
[Event "Rated blitz game"]
[White "TestUser"]
[Black "Opponent6"]
[Result "1-0"]
[FEN "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"]

1. d4 d5 1-0
''';

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

    test('maxDepth caps how deep the tree records a game', () {
      // The cap is a parameter, not a constant: a caller that asks for four
      // plies must get four, whatever the default happens to be.
      int depthOf(OpeningTreeNode node) => node.children.isEmpty
          ? 0
          : 1 + node.children.values.map(depthOf).reduce((a, b) => a > b ? a : b);

      final shallow = UnifiedAnalysisBuilder.buildBoth(
        pgnList: _pgnList,
        username: 'TestUser',
        maxDepth: 2,
      );
      final deeper = UnifiedAnalysisBuilder.buildBoth(
        pgnList: _pgnList,
        username: 'TestUser',
        maxDepth: 6,
      );

      expect(depthOf(shallow.whiteTree.root), 2);
      expect(depthOf(deeper.whiteTree.root), greaterThan(2));
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

  group('custom start positions', () {
    test('a chapter first in the file still hangs under its line', () {
      // Order in the file must not decide the shape of the tree: a chapter
      // folded before anything stands at its start position grafts at the
      // root, and its first move then shows up as an opening move that is
      // not even legal from the start.
      final bundle = UnifiedAnalysisBuilder.buildBoth(
        pgnList: const [_chapterPgn, _reachesChapterPgn],
        username: 'TestUser',
      );

      expect(bundle.whiteTree.root.children.keys, ['e4']);
      final afterE5 = bundle.whiteTree.root.children['e4']!.children['e5']!;
      expect(afterE5.children.keys, containsAll(['Bc4', 'Nf3']));
    });

    test('a [FEN] header naming the start position is not a chapter', () {
      // Reading one as a chapter would defer the game behind every ordinary
      // game in the batch, silently reordering the games listed against a
      // position — including the starting position, which is every game.
      final bundle = UnifiedAnalysisBuilder.buildBoth(
        pgnList: const [_redundantFenHeaderPgn, _asWhitePgn],
        username: 'TestUser',
      );

      final startKey = normalizeFen(kStandardStartFen);
      expect(bundle.whiteAnalysis.fenToGameIndices[startKey], [0, 1]);
    });
  });

  // Progress is what a caller wires a progress bar to, so what matters is
  // the number it reports: games *completed*, 1-based, from a 0 that resets
  // the bar to a final call that lands exactly on the total. A build of
  // fewer than 100 games ticks once per game (the interval is
  // ceil(total / 100), floored at 1), so the whole sequence is pinned here.
  group('progress reporting', () {
    List<List<int>> progressOf(void Function(void Function(int, int)) run) {
      final seen = <List<int>>[];
      run((current, total) => seen.add([current, total]));
      return seen;
    }

    test('build counts completed games, ending on the total', () {
      final seen = progressOf(
        (onProgress) => UnifiedAnalysisBuilder.build(
          pgnList: _pgnList,
          username: 'TestUser',
          isWhite: true,
          onProgress: onProgress,
        ),
      );

      expect(seen.map((e) => e[0]), [0, 1, 2, 3, 4]);
      expect(seen.map((e) => e[1]), everyElement(_pgnList.length));
      expect(seen.last, [_pgnList.length, _pgnList.length]);
    });

    test('buildBoth counts completed games, ending on the total', () {
      final seen = progressOf(
        (onProgress) => UnifiedAnalysisBuilder.buildBoth(
          pgnList: _pgnList,
          username: 'TestUser',
          onProgress: onProgress,
        ),
      );

      expect(seen.map((e) => e[0]), [0, 1, 2, 3, 4]);
      expect(seen.map((e) => e[1]), everyElement(_pgnList.length));
      expect(seen.last, [_pgnList.length, _pgnList.length]);
    });

    test('a build reports progress for every game, never past the total', () {
      // Whether or not a game counts for the colour being built, it is still
      // one of the games the caller is waiting on.
      final seen = progressOf(
        (onProgress) => UnifiedAnalysisBuilder.build(
          pgnList: const [_asWhitePgn, _asBlackPgn],
          username: 'TestUser',
          isWhite: true,
          onProgress: onProgress,
        ),
      );

      expect(seen.map((e) => e[0]), [0, 1, 2]);
      expect(seen.every((e) => e[0] >= 0 && e[0] <= e[1]), isTrue);
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

      // The isolate hands back [error, stackTrace]; what surfaces to the
      // caller must be the error, not the stack — a UI that shows
      // "#0 UnifiedAnalysisBuilder._bothColorsEntry (package:...)" tells
      // nobody that the file held no games.
      await expectLater(
        UnifiedAnalysisBuilder.buildBothInIsolate(
          pgnFilePath: pgnPath,
          username: 'TestUser',
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('No games found'), isNot(contains('#0 '))),
          ),
        ),
      );
    });
  });
}
