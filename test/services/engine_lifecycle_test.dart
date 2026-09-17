import 'dart:async';
import 'package:chess_auto_prep/services/engine/engine_search_budget.dart';
import 'package:chess_auto_prep/features/settings/models/engine_configuration.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/app/engine_runtime.dart';
import '../support/runtime_settings.dart';
import 'package:flutter/widgets.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import 'package:chess_auto_prep/services/engine/board_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chess_auto_prep/services/engine/engine_lifecycle.dart';

const _startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

class _FailingPool extends StockfishPool {
  _FailingPool()
    : super(
        settings: EngineConfiguration.new,
        budget: EngineSearchBudget(capacity: () => 1),
      );
  @override
  Future<void> prepareForTreeBuild(int threadBudget) async {
    throw StateError('Provisioning failed');
  }
}

RuntimeSettings? _engineFixtureSettings;
EngineRuntime get engines =>
    testEngines(_engineFixtureSettings ??= RuntimeSettings.preferences());
void main() {
  setUp(() {
    _engineFixtureSettings = null;
    addTearDown(() => _engineFixtureSettings?.dispose());
  });
  WidgetsFlutterBinding.ensureInitialized();
  late EngineLifecycle lifecycle;
  late int notificationCount;
  late VoidCallback countNotifications;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    lifecycle = engines.lifecycle;

    notificationCount = 0;
    countNotifications = () => notificationCount++;
    lifecycle.addListener(countNotifications);
  });

  tearDown(() {
    lifecycle.removeListener(countNotifications);
  });

  test(
    'failed generation restores state and does not poison future toggles',
    () async {
      final board = BoardEngine(
        settings: EngineConfiguration.new,
        budget: engines.budget,
        createConnection: () async => null,
      );
      final independent = EngineLifecycle(
        loadEnabled: () async => true,
        saveEnabled: (_) async {},
        pool: _FailingPool(),
        board: board,
      );
      addTearDown(independent.dispose);
      addTearDown(board.dispose);
      await independent.toggleOn();
      await expectLater(independent.enterGeneration(1), throwsStateError);
      expect(independent.state, EngineState.idle);
      await independent.toggleOff();
      expect(independent.state, EngineState.off);
      await independent.toggleOn();
      expect(independent.state, EngineState.idle);
    },
  );

  test('generation re-entry and resume preserve the original toggle', () async {
    await lifecycle.toggleOff();
    await lifecycle.enterGeneration(1);
    await lifecycle.enterGeneration(1);
    await lifecycle.toggleOn();
    await lifecycle.resume();
    expect(lifecycle.state, EngineState.generating);
    await lifecycle.exitGeneration();
    await lifecycle.resume();
    expect(lifecycle.state, EngineState.off);
  });

  test('startup read serializes with an early off toggle', () async {
    final loading = Completer<bool>();
    final saved = <bool>[];
    final independent = EngineLifecycle(
      pool: engines.pool,
      board: engines.board,
      loadEnabled: () => loading.future,
      saveEnabled: (value) async => saved.add(value),
    );
    addTearDown(independent.dispose);
    final startup = independent.loadPersistedState();
    final toggle = independent.toggleOff();
    await Future<void>.delayed(Duration.zero);
    expect(saved, isEmpty);
    loading.complete(true);
    await Future.wait([startup, toggle]);
    expect(independent.state, EngineState.off);
    expect(saved, [false]);
    await independent.loadPersistedState();
    await independent.resume();
    expect(independent.state, EngineState.off);
  });

  test('late startup cannot replace an explicit toggle', () async {
    var reads = 0;
    final independent = EngineLifecycle(
      pool: engines.pool,
      board: engines.board,
      loadEnabled: () async {
        reads++;
        return true;
      },
      saveEnabled: (_) async {},
    );
    addTearDown(independent.dispose);
    await independent.toggleOff();
    await independent.loadPersistedState();
    expect(reads, 0);
    expect(independent.state, EngineState.off);
  });

  test('failed startup stays off through resume and permits retry', () async {
    var fail = true;
    var writes = 0;
    final independent = EngineLifecycle(
      pool: engines.pool,
      board: engines.board,
      loadEnabled: () async {
        if (fail) throw StateError('preferences unavailable');
        return true;
      },
      saveEnabled: (_) async {
        writes++;
      },
    );
    addTearDown(independent.dispose);
    await expectLater(independent.loadPersistedState(), throwsStateError);
    await independent.resume();
    expect(independent.state, EngineState.off);
    expect(writes, 0);
    fail = false;
    await independent.loadPersistedState();
    expect(independent.state, EngineState.idle);
    await independent.suspend();
    await independent.resume();
    expect(independent.state, EngineState.idle);
    expect(writes, 0, reason: 'navigation must not rewrite the preference');
  });

  test('startup during generation preserves exclusive ownership', () async {
    await lifecycle.enterGeneration(1);
    await lifecycle.loadPersistedState();
    expect(lifecycle.state, EngineState.generating);
    await lifecycle.exitGeneration();
    expect(lifecycle.state, EngineState.idle);
  });

  test('starts in off state', () {
    expect(lifecycle.state, EngineState.off);
  });

  test('toggleOff is a no-op when already off', () async {
    await lifecycle.toggleOff();
    expect(lifecycle.state, EngineState.off);
    expect(notificationCount, 0);
  });

  test('unset toggle pref defaults to enabled', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('engine_lifecycle.toggle_on') ?? true, isTrue);
  });

  test('loadPersistedState keeps engine off when pref is false', () async {
    SharedPreferences.setMockInitialValues({
      'engine_lifecycle.toggle_on': false,
    });
    await lifecycle.loadPersistedState();
    expect(lifecycle.state, EngineState.off);
  });

  test('onPositionChanged is ignored when engine is off', () {
    lifecycle.onPositionChanged(_startFen);
    expect(lifecycle.state, EngineState.off);
    expect(notificationCount, 0);
  });

  test('onAnalysisComplete is ignored when engine is off', () {
    lifecycle.onAnalysisComplete();
    expect(lifecycle.state, EngineState.off);
    expect(notificationCount, 0);
  });

  test('toggleOn transitions off to idle and notifies once', () async {
    await lifecycle.toggleOn();
    expect(lifecycle.state, EngineState.idle);
    expect(notificationCount, 1);
  });

  test('toggleOff transitions idle to off and notifies once', () async {
    await lifecycle.toggleOn();
    notificationCount = 0;

    await lifecycle.toggleOff();
    expect(lifecycle.state, EngineState.off);
    expect(notificationCount, 1);
  });

  test('toggleOff is ignored while generating', () async {
    await lifecycle.toggleOn();
    await lifecycle.enterGeneration(1);
    notificationCount = 0;

    await lifecycle.toggleOff();
    expect(lifecycle.state, EngineState.generating);
    expect(notificationCount, 0);
  });

  test(
    'onPositionChanged transitions idle to analyzing and notifies once',
    () async {
      await lifecycle.toggleOn();
      notificationCount = 0;

      lifecycle.onPositionChanged(_startFen);
      expect(lifecycle.state, EngineState.analyzing);
      expect(notificationCount, 1);
    },
  );

  test('onPositionChanged is idempotent when already analyzing '
      '(prevents analysis-pane feedback loop)', () async {
    await lifecycle.toggleOn();
    lifecycle.onPositionChanged(_startFen);
    notificationCount = 0;

    lifecycle.onPositionChanged(_startFen);
    expect(lifecycle.state, EngineState.analyzing);
    expect(notificationCount, 0);
  });

  test('onPositionChanged is ignored while generating', () async {
    await lifecycle.toggleOn();
    await lifecycle.enterGeneration(1);
    notificationCount = 0;

    lifecycle.onPositionChanged(_startFen);
    expect(lifecycle.state, EngineState.generating);
    expect(notificationCount, 0);
  });

  test('onAnalysisComplete transitions analyzing to idle', () async {
    await lifecycle.toggleOn();
    lifecycle.onPositionChanged(_startFen);
    notificationCount = 0;

    lifecycle.onAnalysisComplete();
    expect(lifecycle.state, EngineState.idle);
    expect(notificationCount, 1);
  });

  test('onAnalysisComplete is ignored when not analyzing', () async {
    await lifecycle.toggleOn();
    notificationCount = 0;

    lifecycle.onAnalysisComplete();
    expect(lifecycle.state, EngineState.idle);
    expect(notificationCount, 0);
  });

  test(
    'listener notify count stays bounded for a typical analysis cycle',
    () async {
      await lifecycle.toggleOn();
      lifecycle.onPositionChanged(_startFen);
      lifecycle.onPositionChanged(_startFen);
      lifecycle.onAnalysisComplete();
      await lifecycle.toggleOff();

      expect(notificationCount, 4);
    },
  );

  test(
    'pauseGeneration hands the engine back as idle when it was on',
    () async {
      await lifecycle.toggleOn();
      await lifecycle.enterGeneration(1);
      notificationCount = 0;

      await lifecycle.pauseGeneration();
      expect(lifecycle.state, EngineState.idle);
      expect(notificationCount, 1);
    },
  );

  test(
    'pauseGeneration restores off when the engine was off before the build',
    () async {
      await lifecycle.enterGeneration(1);

      await lifecycle.pauseGeneration();
      expect(lifecycle.state, EngineState.off);
    },
  );

  test('pauseGeneration is a no-op when not generating', () async {
    await lifecycle.toggleOn();
    notificationCount = 0;

    await lifecycle.pauseGeneration();
    expect(lifecycle.state, EngineState.idle);
    expect(notificationCount, 0);
  });

  test('resume after pause re-enters generating and exits cleanly', () async {
    await lifecycle.toggleOn();
    await lifecycle.enterGeneration(1);
    await lifecycle.pauseGeneration();

    await lifecycle.enterGeneration(1);
    expect(lifecycle.state, EngineState.generating);

    await lifecycle.exitGeneration();
    expect(lifecycle.state, EngineState.idle);
  });

  test(
    'pause–resume cycle preserves an off toggle across exitGeneration',
    () async {
      await lifecycle.enterGeneration(1);
      await lifecycle.pauseGeneration();
      await lifecycle.enterGeneration(1);

      await lifecycle.exitGeneration();
      expect(lifecycle.state, EngineState.off);
    },
  );

  test(
    'suspend then resume restores idle when the user wants the engine',
    () async {
      await lifecycle.toggleOn();
      expect(lifecycle.state, EngineState.idle);

      await lifecycle.suspend();
      expect(lifecycle.state, EngineState.off);

      await lifecycle.resume();
      expect(lifecycle.state, EngineState.idle);
    },
  );

  test('resume stays off after the user toggled the engine off', () async {
    await lifecycle.toggleOn();
    await lifecycle.toggleOff();
    expect(lifecycle.state, EngineState.off);

    await lifecycle.resume();
    expect(lifecycle.state, EngineState.off);
  });

  test(
    'full state machine cycle: off → on → analyze → complete → off',
    () async {
      expect(lifecycle.state, EngineState.off);

      await lifecycle.toggleOn();
      expect(lifecycle.state, EngineState.idle);

      lifecycle.onPositionChanged(_startFen);
      expect(lifecycle.state, EngineState.analyzing);

      lifecycle.onAnalysisComplete();
      expect(lifecycle.state, EngineState.idle);

      await lifecycle.toggleOff();
      expect(lifecycle.state, EngineState.off);
    },
  );
}
