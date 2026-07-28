/// BuildLauncher: the dialog + controller orchestration behind "Build from
/// games" and "Build by playing". The forms are stubbed, so the tests pin
/// which initial values each form receives and what a chosen config sets in
/// motion — username persistence, revealing the Lines/Draft surface, and
/// which controller starts with what.
library;

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/core/generation_session_controller.dart';
import 'package:chess_auto_prep/core/repertoire_controller.dart';
import 'package:chess_auto_prep/features/repertoire/controllers/build_launcher.dart';
import 'package:chess_auto_prep/models/build_tree_node.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/services/build_by_playing/build_by_playing_config.dart';
import 'package:chess_auto_prep/services/build_by_playing/build_by_playing_controller.dart';
import 'package:chess_auto_prep/services/games_library/game_filter.dart';
import 'package:chess_auto_prep/services/games_library/games_library_service.dart';
import 'package:chess_auto_prep/services/games_repertoire/games_draft_controller.dart';
import 'package:chess_auto_prep/services/games_repertoire/games_source_config.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRepertoire extends RepertoireController {
  RepertoireMetadata? metadata = RepertoireMetadata(
    filePath: '/tmp/rep/Main.pgn',
    name: 'Main',
    lastModified: DateTime(2026),
  );
  String? customStartingFen;
  List<String> moves = const [];
  bool white = true;
  bool atRoot = false;
  final MoveTree unionTree = MoveTree();

  @override
  RepertoireMetadata? get currentRepertoire => metadata;
  @override
  String? get startingFen => customStartingFen;
  @override
  String get fen => 'FEN-current';
  @override
  List<String> get currentMoveSequence => moves;
  @override
  bool get isRepertoireWhite => white;
  @override
  bool get isAtRootPosition => atRoot;
  @override
  String get rootFen => 'FEN-root';
  @override
  List<String> get rootMoveSans => const ['d4'];
  @override
  MoveTree buildRepertoireMoveTree() => unionTree;
}

class _FakeDraft extends GamesDraftController {
  GamesSourceConfig? builtConfig;
  MoveTree? builtAgainst;
  String? errorToReturn;

  @override
  Future<String?> build({
    required GamesSourceConfig config,
    required MoveTree repertoire,
  }) async {
    builtConfig = config;
    builtAgainst = repertoire;
    return errorToReturn;
  }
}

class _FakeSession extends BuildByPlayingController {
  _FakeSession({required super.repertoire});

  bool active = false;
  BuildByPlayingConfig midSessionConfig = const BuildByPlayingConfig(
    maxPly: 33,
  );
  BuildByPlayingConfig? started;
  BuildTree? startedTree;
  FenMap? startedFenMap;
  BuildByPlayingConfig? updated;

  @override
  bool get isActive => active;
  @override
  BuildByPlayingConfig get config => midSessionConfig;

  @override
  Future<void> start(
    BuildByPlayingConfig config, {
    BuildTree? generatedTree,
    FenMap? fenMap,
  }) async {
    started = config;
    startedTree = generatedTree;
    startedFenMap = fenMap;
  }

  @override
  void updateConfig(BuildByPlayingConfig config) {
    updated = config;
  }
}

class _FakeGeneration extends GenerationSessionController {
  final BuildTree tree = BuildTree(
    root: BuildTreeNode(
      fen: 'FEN-root',
      moveSan: '',
      moveUci: '',
      ply: 0,
      isWhiteToMove: true,
      nodeId: 0,
    ),
  );
  final FenMap map = FenMap();

  @override
  BuildTree? get generatedTree => tree;
  @override
  FenMap? get generatedTreeFenMap => map;
}

/// Everything a launcher test needs, wired to fakes and capture slots.
class _Harness {
  _Harness()
    : repertoire = _FakeRepertoire(),
      appState = AppState(),
      generation = _FakeGeneration(),
      settings = BuildByPlayingSettings.fresh() {
    draft = _FakeDraft();
    session = _FakeSession(repertoire: repertoire);
    launcher = BuildLauncher(
      repertoire: repertoire,
      draft: draft,
      session: session,
      generation: generation,
      appState: () => appState,
      showLinesSurface: () => surfaceShown++,
      settings: settings,
      gamesForm: _gamesForm,
      sessionForm: _sessionForm,
    );
  }

  final _FakeRepertoire repertoire;
  final AppState appState;
  final _FakeGeneration generation;
  final BuildByPlayingSettings settings;
  late final _FakeDraft draft;
  late final _FakeSession session;
  late final BuildLauncher launcher;

  int surfaceShown = 0;

  // What the stubbed forms were asked to show, and what they answer.
  Map<String, Object?>? gamesFormArgs;
  GamesSourceConfig? gamesFormAnswer;
  Map<String, Object?>? sessionFormArgs;
  BuildByPlayingConfig? sessionFormAnswer;

  Future<GamesSourceConfig?> _gamesForm(
    BuildContext context, {
    bool initialIsWhite = true,
    String? initialChesscomUsername,
    String? initialLichessUsername,
    bool atRoot = true,
    String? rootFen,
    String? currentFen,
    List<String> currentMoveSans = const [],
  }) async {
    gamesFormArgs = {
      'initialIsWhite': initialIsWhite,
      'initialChesscomUsername': initialChesscomUsername,
      'initialLichessUsername': initialLichessUsername,
      'atRoot': atRoot,
      'rootFen': rootFen,
      'currentFen': currentFen,
      'currentMoveSans': currentMoveSans,
    };
    return gamesFormAnswer;
  }

  Future<BuildByPlayingConfig?> _sessionForm(
    BuildContext context, {
    required BuildByPlayingConfig initial,
    required bool atRoot,
    String? rootFen,
    List<String> rootMoveSans = const [],
    String? currentFen,
    List<String> currentMoveSans = const [],
    bool boardFlipped = false,
  }) async {
    sessionFormArgs = {
      'initial': initial,
      'atRoot': atRoot,
      'rootFen': rootFen,
      'rootMoveSans': rootMoveSans,
      'currentFen': currentFen,
      'currentMoveSans': currentMoveSans,
      'boardFlipped': boardFlipped,
    };
    return sessionFormAnswer;
  }

  void dispose() {
    draft.dispose();
    session.dispose();
    generation.dispose();
    settings.dispose();
    appState.dispose();
    repertoire.dispose();
  }
}

Future<BuildContext> _pumpHost(WidgetTester tester) async {
  late BuildContext ctx;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      ),
    ),
  );
  return ctx;
}

const _gamesConfig = GamesSourceConfig(
  platform: GamesPlatform.chesscom,
  username: 'drew',
  isWhite: true,
  selection: GameSelection(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('buildFromGames', () {
    testWidgets('standard start, mid-line: offers building from the current '
        'position and prefills saved usernames', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.repertoire.moves = const ['e4', 'e5'];
      h.appState.setChesscomUsername('drew');
      h.appState.setLichessUsername('lichess-drew');

      await h.launcher.buildFromGames(await _pumpHost(tester));

      expect(h.gamesFormArgs, {
        'initialIsWhite': true,
        'initialChesscomUsername': 'drew',
        'initialLichessUsername': 'lichess-drew',
        'atRoot': false,
        'rootFen': isNotNull, // the standard start position
        'currentFen': 'FEN-current',
        'currentMoveSans': ['e4', 'e5'],
      });
    });

    testWidgets('custom starting position: real games cannot reach it, so the '
        'from-current option is off the table', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.repertoire.customStartingFen = 'FEN-custom';
      h.repertoire.moves = const ['e4', 'e5'];

      await h.launcher.buildFromGames(await _pumpHost(tester));

      expect(h.gamesFormArgs!['atRoot'], true);
      expect(h.gamesFormArgs!['currentFen'], isNull);
      expect(h.gamesFormArgs!['currentMoveSans'], isEmpty);
    });

    testWidgets('cancelling the form changes nothing', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);

      await h.launcher.buildFromGames(await _pumpHost(tester));

      expect(h.draft.builtConfig, isNull);
      expect(h.surfaceShown, 0);
      expect(h.appState.chesscomUsername, isNull);
    });

    testWidgets('a chosen config saves the username for its platform, reveals '
        'the surface, and drafts against the whole repertoire', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.gamesFormAnswer = _gamesConfig;

      await h.launcher.buildFromGames(await _pumpHost(tester));

      expect(h.appState.chesscomUsername, 'drew');
      expect(h.appState.lichessUsername, isNull);
      expect(h.surfaceShown, 1);
      expect(h.draft.builtConfig, same(_gamesConfig));
      // The union of every line, not just the loaded one.
      expect(h.draft.builtAgainst, same(h.repertoire.unionTree));
    });

    testWidgets('a failed draft build surfaces the error in a snackbar', (
      tester,
    ) async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.gamesFormAnswer = _gamesConfig;
      h.draft.errorToReturn = 'No games found for "drew".';

      await h.launcher.buildFromGames(await _pumpHost(tester));
      await tester.pump();

      expect(find.text('No games found for "drew".'), findsOneWidget);
    });
  });

  group('startBuildByPlaying', () {
    testWidgets('without a loaded repertoire nothing happens', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.repertoire.metadata = null;

      await h.launcher.startBuildByPlaying(await _pumpHost(tester));

      expect(h.sessionFormArgs, isNull);
      expect(h.surfaceShown, 0);
    });

    testWidgets('with a session already running the button re-reveals it '
        'instead of opening the form', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.session.active = true;

      await h.launcher.startBuildByPlaying(await _pumpHost(tester));

      expect(h.sessionFormArgs, isNull);
      expect(h.surfaceShown, 1);
    });

    testWidgets(
      'a chosen config is persisted as the new default and starts the '
      'session with the generated tree',
      (tester) async {
        final h = _Harness();
        addTearDown(h.dispose);
        h.repertoire.white = false;
        h.repertoire.moves = const ['d4', 'd5'];
        h.sessionFormAnswer = const BuildByPlayingConfig(maxPly: 42);
        final defaults = h.settings.config;

        await h.launcher.startBuildByPlaying(await _pumpHost(tester));

        expect(h.sessionFormArgs, {
          'initial': same(defaults),
          'atRoot': false,
          'rootFen': 'FEN-root',
          'rootMoveSans': ['d4'],
          'currentFen': 'FEN-current',
          'currentMoveSans': ['d4', 'd5'],
          // A Black repertoire plays from Black's side of the board.
          'boardFlipped': true,
        });
        expect(h.settings.config.maxPly, 42);
        expect(h.surfaceShown, 1);
        expect(h.session.started?.maxPly, 42);
        expect(h.session.startedTree, same(h.generation.tree));
        expect(h.session.startedFenMap, same(h.generation.map));
      },
    );

    testWidgets('cancelling starts nothing and keeps the saved defaults', (
      tester,
    ) async {
      final h = _Harness();
      addTearDown(h.dispose);
      final before = h.settings.config;

      await h.launcher.startBuildByPlaying(await _pumpHost(tester));

      expect(h.session.started, isNull);
      expect(h.settings.config, same(before));
      expect(h.surfaceShown, 0);
    });
  });

  group('openSessionSettings', () {
    testWidgets('edits start from the live session config and apply to both '
        'the saved defaults and the running session', (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.sessionFormAnswer = const BuildByPlayingConfig(maxPly: 21);

      await h.launcher.openSessionSettings(await _pumpHost(tester));

      expect(h.sessionFormArgs!['initial'], same(h.session.midSessionConfig));
      // Mid-session there is no start-from choice to make.
      expect(h.sessionFormArgs!['atRoot'], true);
      expect(h.settings.config.maxPly, 21);
      expect(h.session.updated?.maxPly, 21);
    });
  });
}
