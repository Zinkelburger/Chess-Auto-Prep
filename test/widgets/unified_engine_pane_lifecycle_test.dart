import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/services/engine/engine_lifecycle.dart';

const _startFen =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const _e4Fen =
    'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';

/// Mirrors [UnifiedEnginePane]'s lifecycle ↔ analysis coupling.
///
/// Keep in sync with `_onLifecycleChanged`, `_scheduleAnalysis`, and
/// `_runAnalysis` in `unified_engine_pane.dart` — regressions in that
/// interaction should fail these tests.
class _EnginePaneLifecycleHarness {
  _EnginePaneLifecycleHarness({required this.fenProvider}) {
    EngineLifecycle().addListener(_onLifecycleChanged);
    _lastLifecycleState = EngineLifecycle().state;
  }

  final String Function() fenProvider;

  int runAnalysisCount = 0;
  int scheduleAnalysisCount = 0;
  EngineState? _lastLifecycleState;
  bool _analysisScheduled = false;
  bool isActive = true;

  bool get _engineActive =>
      isActive && EngineLifecycle().state != EngineState.off;

  void dispose() {
    EngineLifecycle().removeListener(_onLifecycleChanged);
  }

  void runAnalysis() {
    runAnalysisCount++;
    EngineLifecycle().onPositionChanged(fenProvider());
  }

  void onFenChanged() {
    _scheduleAnalysis();
  }

  void _scheduleAnalysis() {
    scheduleAnalysisCount++;
    if (_analysisScheduled) return;
    _analysisScheduled = true;
  }

  void flushScheduledAnalysis() {
    _analysisScheduled = false;
    if (!_engineActive) return;
    runAnalysis();
  }

  void _onLifecycleChanged() {
    final state = EngineLifecycle().state;
    final prev = _lastLifecycleState;
    _lastLifecycleState = state;

    if (!_engineActive) return;

    final becameUsable = (prev == null ||
            prev == EngineState.off ||
            prev == EngineState.generating) &&
        (state == EngineState.idle || state == EngineState.analyzing) &&
        !(prev == null && state == EngineState.analyzing);
    if (becameUsable) {
      _scheduleAnalysis();
    }
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  late EngineLifecycle lifecycle;
  late int notificationCount;
  late VoidCallback countNotifications;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    lifecycle = EngineLifecycle();
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

  group('EnginePane lifecycle harness', () {
    test(
      'runAnalysis during analyzing does not cause extra lifecycle notifications',
      () async {
        await lifecycle.toggleOn();
        final harness = _EnginePaneLifecycleHarness(fenProvider: () => _startFen);

        harness.runAnalysis();
        expect(lifecycle.state, EngineState.analyzing);
        notificationCount = 0;

        harness.runAnalysis();
        expect(lifecycle.state, EngineState.analyzing);
        expect(notificationCount, 0);
        expect(harness.runAnalysisCount, 2);

        harness.dispose();
      },
    );

    test(
      'idle → analyzing listener transition does not re-schedule analysis',
      () async {
        await lifecycle.toggleOn();
        final harness = _EnginePaneLifecycleHarness(fenProvider: () => _startFen);

        harness.runAnalysis();
        expect(harness.scheduleAnalysisCount, 0);

        harness.dispose();
      },
    );

    test(
      'analyzing → idle completion does not re-schedule analysis',
      () async {
        await lifecycle.toggleOn();
        final harness = _EnginePaneLifecycleHarness(fenProvider: () => _startFen);

        harness.runAnalysis();
        lifecycle.onAnalysisComplete();
        expect(harness.scheduleAnalysisCount, 0);

        harness.dispose();
      },
    );

    test(
      'off → idle toggle re-schedules analysis once (engine became usable)',
      () async {
        final harness = _EnginePaneLifecycleHarness(fenProvider: () => _startFen);

        await lifecycle.toggleOn();
        expect(harness.scheduleAnalysisCount, 1);

        harness.dispose();
      },
    );

    test(
      'repeated runAnalysis while analyzing does not accumulate notifications',
      () async {
        await lifecycle.toggleOn();
        final harness =
            _EnginePaneLifecycleHarness(fenProvider: () => _startFen);
        notificationCount = 0;

        harness.runAnalysis();
        expect(notificationCount, 1);

        for (var i = 0; i < 5; i++) {
          harness.runAnalysis();
        }
        expect(notificationCount, 1);
        expect(lifecycle.state, EngineState.analyzing);

        harness.dispose();
      },
    );

    test(
      'FEN change schedules analysis post-frame instead of running synchronously',
      () async {
        await lifecycle.toggleOn();
        final harness =
            _EnginePaneLifecycleHarness(fenProvider: () => _e4Fen);

        harness.onFenChanged();
        expect(harness.runAnalysisCount, 0);

        harness.flushScheduledAnalysis();
        expect(harness.runAnalysisCount, 1);
        expect(lifecycle.state, EngineState.analyzing);

        harness.dispose();
      },
    );

    test(
      'FEN change plus flush does not amplify lifecycle notifications',
      () async {
        await lifecycle.toggleOn();
        final harness =
            _EnginePaneLifecycleHarness(fenProvider: () => _e4Fen);
        notificationCount = 0;

        harness.onFenChanged();
        harness.flushScheduledAnalysis();

        expect(harness.runAnalysisCount, 1);
        expect(notificationCount, 1);

        harness.dispose();
      },
    );
  });
}
