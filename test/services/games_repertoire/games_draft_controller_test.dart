import 'dart:async';

import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/models/opening_tree.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:chess_auto_prep/services/games_library/games_library_service.dart';
import 'package:chess_auto_prep/services/games_repertoire/games_draft_controller.dart';
import 'package:chess_auto_prep/services/games_repertoire/games_source_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory [GamesLibraryService]: never touches network or the on-disk
/// games cache. [gate] lets a test hold a build open to observe the
/// in-flight state.
class _FakeGamesLibrary extends GamesLibraryService {
  List<GameRecord> records = [];
  Object? error;
  Completer<void>? gate;
  int calls = 0;

  @override
  Future<List<GameRecord>> getGames({
    required GamesPlatform platform,
    required String username,
    GameSelection selection = const GameSelection(),
    bool forceRefresh = false,
    void Function(String message)? onProgress,
  }) async {
    calls++;
    onProgress?.call('Downloading $username…');
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    return records;
  }
}

const _gamePgn = '''
[Event "Test"]
[Site "https://lichess.org/abc123"]
[White "me"]
[Black "opp"]
[Result "1-0"]

1. e4 e5 2. Nf3 1-0
''';

GamesSourceConfig _config({
  bool isWhite = true,
  List<String> startMoves = const [],
}) {
  return GamesSourceConfig(
    platform: GamesPlatform.lichess,
    username: 'me',
    isWhite: isWhite,
    selection: const GameSelection(),
    startMoves: startMoves,
  );
}

/// Walk an [OpeningTree] to the node reached by [sans].
OpeningTreeNode? _nodeFor(OpeningTree tree, List<String> sans) {
  var node = tree.root;
  for (final san in sans) {
    final next = node.children[san];
    if (next == null) return null;
    node = next;
  }
  return node;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeGamesLibrary library;
  late GamesDraftController controller;

  setUp(() {
    library = _FakeGamesLibrary();
    controller = GamesDraftController(gamesLibrary: library);
  });

  test('build happy path produces a classified draft', () async {
    library.records = [GameRecord.parse(_gamePgn)];

    final error = await controller.build(
      config: _config(),
      repertoire: MoveTree(),
    );

    expect(error, isNull);
    expect(controller.draft, isNotNull);
    expect(controller.isBuilding, isFalse);
    expect(controller.isActive, isTrue);
    expect(controller.isWhite, isTrue);
    expect(controller.sourceLabel, 'me');
    expect(controller.progress, contains('Building tree'));

    final draft = controller.draft!;
    expect(draft.isWhite, isTrue);
    expect(_nodeFor(draft.tree, ['e4', 'e5', 'Nf3']), isNotNull);
    controller.dispose();
  });

  test('building flag toggles and notifies around the async build', () async {
    library.records = [GameRecord.parse(_gamePgn)];
    final buildingSnapshots = <bool>[];
    controller.addListener(() => buildingSnapshots.add(controller.isBuilding));

    await controller.build(config: _config(), repertoire: MoveTree());

    expect(buildingSnapshots.first, isTrue, reason: 'start notified');
    expect(buildingSnapshots.last, isFalse, reason: 'finish notified');
    expect(buildingSnapshots, contains(true));
    controller.dispose();
  });

  test('no games found returns an error and deactivates', () async {
    library.records = [];

    final error = await controller.build(
      config: _config(),
      repertoire: MoveTree(),
    );

    expect(error, 'No games found for "me".');
    expect(controller.draft, isNull);
    expect(controller.isBuilding, isFalse);
    expect(controller.isActive, isFalse);
    controller.dispose();
  });

  test('fetch failure surfaces as a build error', () async {
    library.error = Exception('network down');

    final error = await controller.build(
      config: _config(),
      repertoire: MoveTree(),
    );

    expect(error, startsWith('Could not build draft:'));
    expect(error, contains('network down'));
    expect(controller.draft, isNull);
    expect(controller.isBuilding, isFalse);
    controller.dispose();
  });

  test(
    'start-position restriction failure returns the restrict error',
    () async {
      library.records = [GameRecord.parse(_gamePgn)];

      final error = await controller.build(
        config: _config(startMoves: ['d4']),
        repertoire: MoveTree(),
      );

      expect(error, contains('None of the downloaded games reach'));
      expect(controller.draft, isNull);
      expect(controller.isBuilding, isFalse);
      controller.dispose();
    },
  );

  test('start-position restriction keeps only the matching branch', () async {
    library.records = [GameRecord.parse(_gamePgn)];

    final error = await controller.build(
      config: _config(startMoves: ['e4']),
      repertoire: MoveTree(),
    );

    expect(error, isNull);
    final root = controller.draft!.tree.root;
    expect(root.children.keys, ['e4']);
    controller.dispose();
  });

  test('a second build while one is running is a no-op', () async {
    library.records = [GameRecord.parse(_gamePgn)];
    library.gate = Completer<void>();

    final first = controller.build(config: _config(), repertoire: MoveTree());
    expect(controller.isBuilding, isTrue);

    final second = await controller.build(
      config: _config(),
      repertoire: MoveTree(),
    );
    expect(second, isNull, reason: 'silently refused');
    expect(library.calls, 1, reason: 'no second fetch started');

    library.gate!.complete();
    expect(await first, isNull);
    expect(controller.draft, isNotNull);
    controller.dispose();
  });

  test('close discards the draft and deactivates', () async {
    library.records = [GameRecord.parse(_gamePgn)];
    await controller.build(config: _config(), repertoire: MoveTree());
    expect(controller.isActive, isTrue);

    var notified = 0;
    controller.addListener(() => notified++);
    controller.close();

    expect(controller.draft, isNull);
    expect(controller.isBuilding, isFalse);
    expect(controller.isActive, isFalse);
    expect(notified, 1);
    controller.dispose();
  });

  test(
    'dispose during an in-flight build completes without throwing',
    () async {
      library.records = [GameRecord.parse(_gamePgn)];
      library.gate = Completer<void>();

      final build = controller.build(config: _config(), repertoire: MoveTree());
      controller.dispose();
      library.gate!.complete();

      // The build finishes after dispose; its notifyListeners calls are
      // swallowed by SafeChangeNotifier instead of asserting.
      expect(await build, isNull);
    },
  );
}
