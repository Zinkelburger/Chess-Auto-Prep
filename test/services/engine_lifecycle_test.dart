import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chess_auto_prep/services/engine/engine_lifecycle.dart';

const _startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  late EngineLifecycle lifecycle;
  late int notificationCount;
  late VoidCallback countNotifications;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    lifecycle = EngineLifecycle.instance;
    lifecycle.resetForTest();
    EngineLifecycle.testMode = true;
    notificationCount = 0;
    countNotifications = () => notificationCount++;
    lifecycle.addListener(countNotifications);
  });

  tearDown(() {
    lifecycle.removeListener(countNotifications);
    lifecycle.resetForTest();
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
