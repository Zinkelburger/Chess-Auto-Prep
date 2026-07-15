import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/opening_tree_builder.dart';
import 'package:chess_auto_prep/services/pgn_tree_core.dart';
import 'package:chess_auto_prep/services/unified_analysis_builder.dart';

void main() {
  group('isRepertoirePlayer', () {
    test('matches known repertoire patterns case-insensitively', () {
      expect(isRepertoirePlayer('My Repertoire'), isTrue);
      expect(isRepertoirePlayer('TRAINING'), isTrue);
      expect(isRepertoirePlayer('me'), isTrue);
      expect(isRepertoirePlayer('Player 1'), isTrue);
      expect(isRepertoirePlayer('Lichess Study'), isTrue);
    });

    test('does not match ordinary opponent names', () {
      expect(isRepertoirePlayer('Magnus Carlsen'), isFalse);
      expect(isRepertoirePlayer('hikaru'), isFalse);
      expect(isRepertoirePlayer(''), isFalse);
    });
  });

  group('resolveUserColor - strict matching', () {
    // NB: opponent names must avoid the loose repertoire patterns
    // ('me', 'player', ...) — e.g. 'SomeOpponent' contains 'me'.
    bool? resolve({
      String white = 'Alice',
      String black = 'Bob',
      String username = 'testuser',
      bool? filter,
      UnattributableGamePolicy policy = UnattributableGamePolicy.skip,
    }) {
      return resolveUserColor(
        whiteHeader: white,
        blackHeader: black,
        usernameLower: username.toLowerCase(),
        userIsWhiteFilter: filter,
        strictPlayerMatching: true,
        unattributablePolicy: policy,
      );
    }

    test('username in White header attributes user to White', () {
      expect(resolve(white: 'TestUser'), isTrue);
    });

    test('username in Black header attributes user to Black', () {
      expect(resolve(black: 'TestUser'), isFalse);
    });

    test('username match is case-insensitive and substring-based', () {
      expect(resolve(white: 'GM_TESTUSER_2000'), isTrue);
    });

    test('repertoire pattern in White header attributes user to White', () {
      expect(resolve(white: 'White Repertoire'), isTrue);
    });

    test('repertoire pattern in Black header attributes user to Black', () {
      expect(resolve(black: 'Training'), isFalse);
    });

    test('ambiguous game (neither matches) with null filter is skipped '
        'under skip policy', () {
      expect(
        resolve(filter: null, policy: UnattributableGamePolicy.skip),
        isNull,
      );
    });

    test('ambiguous game (neither matches) with null filter defaults to '
        'White under assumeWhite policy', () {
      expect(
        resolve(filter: null, policy: UnattributableGamePolicy.assumeWhite),
        isTrue,
      );
    });

    test('ambiguous game (both match) with null filter is skipped under '
        'skip policy', () {
      expect(
        resolve(
          white: 'TestUser',
          black: 'My Repertoire',
          filter: null,
          policy: UnattributableGamePolicy.skip,
        ),
        isNull,
      );
    });

    test('ambiguous game falls back to the filter under both policies', () {
      for (final policy in UnattributableGamePolicy.values) {
        expect(
          resolve(filter: true, policy: policy),
          isTrue,
          reason: 'filter=true, policy=$policy',
        );
        expect(
          resolve(filter: false, policy: policy),
          isFalse,
          reason: 'filter=false, policy=$policy',
        );
      }
    });

    test('both headers matching falls back to the filter', () {
      expect(
        resolve(white: 'TestUser', black: 'TestUser2', filter: false),
        isFalse,
      );
      expect(
        resolve(white: 'TestUser', black: 'TestUser2', filter: true),
        isTrue,
      );
    });

    test('colour filter rejects games where user played the other colour', () {
      // User matched as Black, but filter demands White games.
      expect(resolve(black: 'TestUser', filter: true), isNull);
      // User matched as White, but filter demands Black games.
      expect(resolve(white: 'TestUser', filter: false), isNull);
    });

    test('colour filter keeps games matching the requested colour', () {
      expect(resolve(white: 'TestUser', filter: true), isTrue);
      expect(resolve(black: 'TestUser', filter: false), isFalse);
    });
  });

  group('resolveUserColor - non-strict matching', () {
    bool? resolve(bool? filter) {
      return resolveUserColor(
        whiteHeader: 'TestUser', // headers must be ignored in this mode
        blackHeader: 'Opponent',
        usernameLower: 'testuser',
        userIsWhiteFilter: filter,
        strictPlayerMatching: false,
        unattributablePolicy: UnattributableGamePolicy.skip,
      );
    }

    test('filter dictates perspective regardless of headers', () {
      expect(resolve(true), isTrue);
      expect(resolve(false), isFalse);
    });

    test('null filter assumes White (never skips)', () {
      expect(resolve(null), isTrue);
    });
  });

  group('resultForUser', () {
    test('1-0 scores 1.0 for White user and 0.0 for Black user', () {
      expect(resultForUser('1-0', true), 1.0);
      expect(resultForUser('1-0', false), 0.0);
    });

    test('0-1 scores 0.0 for White user and 1.0 for Black user', () {
      expect(resultForUser('0-1', true), 0.0);
      expect(resultForUser('0-1', false), 1.0);
    });

    test('draws and unfinished games score 0.5 for both colours', () {
      for (final result in ['1/2-1/2', '*', '']) {
        expect(resultForUser(result, true), 0.5, reason: 'result=$result');
        expect(resultForUser(result, false), 0.5, reason: 'result=$result');
      }
    });

    test('surrounding whitespace is ignored', () {
      expect(resultForUser(' 1-0 ', true), 1.0);
      expect(resultForUser('0-1\n', false), 1.0);
    });
  });

  group('walkMainlineIntoTree', () {
    PgnGame<PgnNodeData> parse(String pgn) => PgnGame.parsePgn(pgn);

    test('builds tree nodes along the mainline and updates stats', () {
      final tree = OpeningTree();
      walkMainlineIntoTree(
        tree: tree,
        game: parse('1. e4 e5 2. Nf3 *'),
        userResult: 1.0,
        maxDepth: 30,
      );

      expect(tree.root.gamesPlayed, 1);
      expect(tree.root.wins, 1);
      final e4 = tree.root.children['e4'];
      expect(e4, isNotNull);
      expect(e4!.gamesPlayed, 1);
      final e5 = e4.children['e5'];
      expect(e5, isNotNull);
      final nf3 = e5!.children['Nf3'];
      expect(nf3, isNotNull);
      expect(nf3!.children, isEmpty);
    });

    test('merges repeated lines and accumulates results', () {
      final tree = OpeningTree();
      walkMainlineIntoTree(
        tree: tree,
        game: parse('1. e4 e5 *'),
        userResult: 1.0,
        maxDepth: 30,
      );
      walkMainlineIntoTree(
        tree: tree,
        game: parse('1. e4 c5 *'),
        userResult: 0.0,
        maxDepth: 30,
      );

      final e4 = tree.root.children['e4']!;
      expect(e4.gamesPlayed, 2);
      expect(e4.wins, 1);
      expect(e4.losses, 1);
      expect(e4.children.keys, containsAll(['e5', 'c5']));
    });

    test('respects maxDepth', () {
      final tree = OpeningTree();
      walkMainlineIntoTree(
        tree: tree,
        game: parse('1. e4 e5 2. Nf3 Nc6 *'),
        userResult: 0.5,
        maxDepth: 2,
      );

      final e5 = tree.root.children['e4']!.children['e5']!;
      expect(e5.children, isEmpty);
    });

    test('stops on an illegal move without throwing', () {
      final tree = OpeningTree();
      walkMainlineIntoTree(
        tree: tree,
        game: parse('1. e4 Ke7 2. Nf3 *'),
        userResult: 0.5,
        maxDepth: 30,
      );

      final e4 = tree.root.children['e4']!;
      expect(e4.children, isEmpty);
    });

    test('honours a custom start position', () {
      const startFen =
          'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 1';
      final tree = OpeningTree();
      walkMainlineIntoTree(
        tree: tree,
        game: parse('[FEN "$startFen"]\n\n1... e5 *'),
        userResult: 1.0,
        maxDepth: 30,
        startPosition: Chess.fromSetup(Setup.parseFen(startFen)),
      );

      final e5 = tree.root.children['e5'];
      expect(e5, isNotNull);
      expect(e5!.fen, contains(' w '));
    });

    test('invokes per-ply and completion callbacks with correct positions', () {
      final tree = OpeningTree();
      final beforeMoveFens = <String>[];
      String? finalFen;

      walkMainlineIntoTree(
        tree: tree,
        game: parse('1. e4 e5 *'),
        userResult: 0.5,
        maxDepth: 30,
        onPositionBeforeMove: (p) => beforeMoveFens.add(p.fen),
        onWalkComplete: (p) => finalFen = p.fen,
      );

      expect(beforeMoveFens, hasLength(2));
      expect(beforeMoveFens.first, Chess.initial.fen);
      expect(beforeMoveFens[1], contains(' b '));
      expect(finalFen, tree.root.children['e4']!.children['e5']!.fen);
    });
  });

  group('builder policies end-to-end', () {
    const ambiguousPgn =
        '[White "Alice"]\n'
        '[Black "Bob"]\n'
        '[Result "1-0"]\n'
        '\n'
        '1. e4 e5 *';

    test('OpeningTreeBuilder skips games it cannot attribute '
        '(userIsWhite null)', () async {
      final tree = await OpeningTreeBuilder.buildTree(
        pgnList: [ambiguousPgn],
        username: 'testuser',
        userIsWhite: null,
      );
      expect(tree.totalGames, 0);
    });

    test(
      'OpeningTreeBuilder keeps attributable games when userIsWhite null',
      () async {
        final tree = await OpeningTreeBuilder.buildTree(
          pgnList: [ambiguousPgn.replaceFirst('Alice', 'TestUser')],
          username: 'testuser',
          userIsWhite: null,
        );
        expect(tree.totalGames, 1);
        expect(tree.root.wins, 1);
      },
    );

    test('UnifiedAnalysisBuilder defaults ambiguous games to the filter', () {
      final (_, treeAsWhite) = UnifiedAnalysisBuilder.build(
        pgnList: [ambiguousPgn],
        username: 'testuser',
        isWhite: true,
      );
      expect(treeAsWhite.totalGames, 1);
      expect(treeAsWhite.root.wins, 1); // 1-0 from White's perspective

      final (_, treeAsBlack) = UnifiedAnalysisBuilder.build(
        pgnList: [ambiguousPgn],
        username: 'testuser',
        isWhite: false,
      );
      expect(treeAsBlack.totalGames, 1);
      expect(treeAsBlack.root.losses, 1); // 1-0 from Black's perspective
    });

    test('UnifiedAnalysisBuilder filters out games of the other colour', () {
      final (_, tree) = UnifiedAnalysisBuilder.build(
        pgnList: [ambiguousPgn.replaceFirst('Bob', 'TestUser')],
        username: 'testuser',
        isWhite: true,
      );
      expect(tree.totalGames, 0);
    });
  });
}
