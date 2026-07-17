import 'dart:io';

import 'package:chess_auto_prep/services/analysis_games_service.dart';
import 'package:chess_auto_prep/services/games_library/games_library_service.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// End-to-end proof that a user-supplied username can never steer a cache
/// write outside its intended directory (PATH TRAVERSAL) and that hostile
/// names don't clobber unrelated players.
///
/// [AnalysisGamesService] and [GamesLibraryService] both interpolate the
/// username into a filename, but only after folding everything outside
/// `[a-z0-9_-]` to `_`. These tests drive the real services against a temp
/// documents dir and assert every file they touch stays under the intended
/// cache root — the on-disk counterpart to the pure-string contract pinned in
/// test/models/analysis_player_info_test.dart.

/// Routes path_provider's documents/support dirs at a per-test temp dir so the
/// real File I/O in the services never touches the developer's data.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// A minimal one-game PGN so parse/filter succeeds on the round trip.
String _pgnFor(String black) =>
    '[Event "Rated blitz game"]\n'
    '[White "me"]\n'
    '[Black "$black"]\n'
    '[UTCDate "2026.06.01"]\n'
    '[TimeControl "300"]\n'
    '[Result "1-0"]\n\n'
    '1. e4 e5 2. Nf3 1-0';

/// Canonical absolute paths of every regular file anywhere under [root].
Future<List<String>> _allFiles(Directory root) async {
  final out = <String>[];
  await for (final e in root.list(recursive: true, followLinks: false)) {
    if (e is File) out.add(p.canonicalize(e.path));
  }
  return out;
}

/// The hostile inputs every traversal assertion runs against.
const _hostileNames = <String>[
  '../../etc/passwd',
  '../../../../../../etc/shadow',
  r'..\..\..\Windows\System32',
  '/etc/passwd',
  r'C:\Windows\System32\drivers',
  '..',
  '%2e%2e%2f%2e%2e%2f',
  'a/../../b',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String docsRoot;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('path_sanitization_test');
    docsRoot = tempDir.path;
    PathProviderPlatform.instance = _FakePathProvider(docsRoot);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  // ── GamesLibraryService (games_library/<platform>_<user>.pgn) ────────
  group('GamesLibraryService cache path confinement', () {
    /// A service whose fetcher just echoes a fixed PGN — no network.
    GamesLibraryService serviceReturning(String pgn) => GamesLibraryService(
      chesscomFetcher: (u, {maxGames = 300, since, onProgress}) async => pgn,
      lichessFetcher: (u, {maxGames = 300, since, onProgress}) async => pgn,
    );

    test('benign username round-trips within the games_library dir', () async {
      final svc = serviceReturning(_pgnFor('opponentA'));
      final games = await svc.getGames(
        platform: GamesPlatform.chesscom,
        username: 'Hikaru',
      );
      expect(games, isNotEmpty);

      final libDir = await AppPaths.gamesLibraryDirectory();
      final files = await _allFiles(libDir);
      expect(files, hasLength(1));
      expect(p.basename(files.single), 'chesscom_hikaru.pgn');

      // A second call is served from cache without re-fetching.
      expect(await svc.hasFreshCache(GamesPlatform.chesscom, 'Hikaru'), isTrue);
    });

    test('hostile usernames never write outside games_library', () async {
      final libDir = await AppPaths.gamesLibraryDirectory(create: true);
      final libRoot = p.canonicalize(libDir.path);

      for (final hostile in _hostileNames) {
        final svc = serviceReturning(_pgnFor('victim'));
        await svc.getGames(platform: GamesPlatform.lichess, username: hostile);
      }

      // Every file created anywhere under the temp documents root must live
      // inside the games_library directory — nothing escaped upward.
      for (final f in await _allFiles(tempDir)) {
        expect(
          p.isWithin(libRoot, f),
          isTrue,
          reason: '"$f" escaped the intended cache root "$libRoot"',
        );
        // And each is a flat file directly in the cache dir (no new nesting).
        expect(p.dirname(f), libRoot);
      }
    });

    test('a hostile name cannot overwrite an unrelated benign cache', () async {
      // Seed a benign player's cache.
      await serviceReturning(
        _pgnFor('benign-opponent'),
      ).getGames(platform: GamesPlatform.chesscom, username: 'realuser');

      final libDir = await AppPaths.gamesLibraryDirectory();
      final benignFile = File(p.join(libDir.path, 'chesscom_realuser.pgn'));
      final before = await benignFile.readAsString();
      expect(before, contains('benign-opponent'));

      // A hostile name that tries to point back at the benign file.
      await serviceReturning(_pgnFor('attacker')).getGames(
        platform: GamesPlatform.chesscom,
        username: '../chesscom_realuser',
      );

      // The benign cache is untouched; the hostile write landed in its own
      // separate sanitized slot (a different, flat filename).
      expect(await benignFile.readAsString(), before);
      final files = await _allFiles(libDir);
      expect(files, hasLength(2));
      final hostileFile = files.firstWhere(
        (f) => p.canonicalize(f) != p.canonicalize(benignFile.path),
      );
      expect(await File(hostileFile).readAsString(), contains('attacker'));
    });

    test('empty and unicode usernames do not crash', () async {
      final svc = serviceReturning(_pgnFor('x'));
      await svc.getGames(platform: GamesPlatform.lichess, username: '');
      await svc.getGames(platform: GamesPlatform.lichess, username: 'café♞名前');
      final libDir = await AppPaths.gamesLibraryDirectory();
      for (final f in await _allFiles(libDir)) {
        expect(p.dirname(p.canonicalize(f)), p.canonicalize(libDir.path));
      }
    });
  });

  // ── AnalysisGamesService (analysis_games/<platform>_<user>.*) ────────
  group('AnalysisGamesService path confinement', () {
    test('derived paths stay under analysis_games for hostile names', () async {
      final svc = AnalysisGamesService();
      final dir = await AppPaths.analysisGamesDirectory(create: true);
      final root = p.canonicalize(dir.path);

      for (final hostile in _hostileNames) {
        final paths = <String>[
          await svc.analysisPgnPath('import', hostile),
          await svc.cachedAnalysisPath('import', hostile, true),
          await svc.cachedAnalysisPath('import', hostile, false),
          await svc.holesReportPath('import', hostile, true),
          await svc.holesReportPath('import', hostile, false),
        ];
        for (final path in paths) {
          final canon = p.canonicalize(path);
          expect(
            p.isWithin(root, canon),
            isTrue,
            reason: '"$path" for username "$hostile" escaped "$root"',
          );
          // Flat file directly in the analysis dir — no traversal nesting.
          expect(p.dirname(canon), root);
        }
      }
    });

    test('saveAnalysisGames round-trips and confines a hostile name', () async {
      final svc = AnalysisGamesService();
      final dir = await AppPaths.analysisGamesDirectory(create: true);
      final root = p.canonicalize(dir.path);

      await svc.saveAnalysisGames(
        _pgnFor('opp'),
        platform: 'import',
        username: '../../evil name',
        maxGames: 10,
      );

      // Read-back succeeds for the same hostile identity.
      final loaded = await svc.loadAnalysisGames('import', '../../evil name');
      expect(loaded, contains('[Black "opp"]'));

      // Nothing was written outside the analysis directory.
      for (final f in await _allFiles(tempDir)) {
        expect(p.isWithin(root, f), isTrue, reason: '"$f" escaped "$root"');
      }
    });

    test(
      'a hostile name does not overwrite an unrelated benign player',
      () async {
        final svc = AnalysisGamesService();

        // Benign player.
        await svc.saveAnalysisGames(
          _pgnFor('benign'),
          platform: 'chesscom',
          username: 'realuser',
          maxGames: 10,
        );
        // Hostile name that sanitizes to a *different* key.
        await svc.saveAnalysisGames(
          _pgnFor('attacker'),
          platform: 'chesscom',
          username: '../realuser',
          maxGames: 10,
        );

        expect(
          await svc.loadAnalysisGames('chesscom', 'realuser'),
          contains('[Black "benign"]'),
        );
        expect(
          await svc.loadAnalysisGames('chesscom', '../realuser'),
          contains('[Black "attacker"]'),
        );
      },
    );

    test(
      'names colliding after sanitization share one slot (documented)',
      () async {
        final svc = AnalysisGamesService();
        await svc.saveAnalysisGames(
          _pgnFor('first'),
          platform: 'import',
          username: 'AC/DC',
          maxGames: 10,
        );
        // "AC DC" folds to the same key as "AC/DC" — findExistingPlayer must
        // report the occupied slot so callers can warn before overwriting.
        final existing = await svc.findExistingPlayer('import', 'AC DC');
        expect(existing, isNotNull);
        expect(existing!.username, 'AC/DC');
      },
    );

    test('very long username fails gracefully (no path escape)', () async {
      final svc = AnalysisGamesService();
      final dir = await AppPaths.analysisGamesDirectory(create: true);
      final root = p.canonicalize(dir.path);

      final longName = 'a' * 5000;
      // A component this long exceeds filesystem limits; the write may throw a
      // FileSystemException, but it must never escape the cache dir and must
      // not corrupt unrelated files.
      try {
        await svc.saveAnalysisGames(
          _pgnFor('x'),
          platform: 'import',
          username: longName,
          maxGames: 10,
        );
      } on FileSystemException {
        // Acceptable: OS rejected the over-long name.
      }
      for (final f in await _allFiles(tempDir)) {
        expect(p.isWithin(root, f), isTrue);
      }
    });
  });
}
