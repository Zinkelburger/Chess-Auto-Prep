import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chess_auto_prep/services/engine/engine_lifecycle.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('starts in off state', () {
    expect(EngineLifecycle().state, EngineState.off);
  });

  test('toggleOff is a no-op when already off', () async {
    await EngineLifecycle().toggleOff();
    expect(EngineLifecycle().state, EngineState.off);
  });

  test('loadPersistedState keeps engine off when pref is false', () async {
    SharedPreferences.setMockInitialValues({'engine_lifecycle.toggle_on': false});
    await EngineLifecycle().loadPersistedState();
    expect(EngineLifecycle().state, EngineState.off);
  });

  test('onPositionChanged is ignored when engine is off', () {
    EngineLifecycle().onPositionChanged(
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
    );
    expect(EngineLifecycle().state, EngineState.off);
  });

  test('onAnalysisComplete is ignored when engine is off', () {
    EngineLifecycle().onAnalysisComplete();
    expect(EngineLifecycle().state, EngineState.off);
  });
}
