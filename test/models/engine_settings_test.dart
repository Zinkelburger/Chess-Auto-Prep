import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chess_auto_prep/models/engine_settings.dart';
import 'package:chess_auto_prep/constants/engine_defaults.dart';

void main() {
  late EngineSettings settings;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    settings = EngineSettings.instance;
    settings.resetToDefaults();
  });

  group('EngineSettings defaults', () {
    test('new and reset settings use one worker and one inline thread', () {
      final fresh = EngineSettings.fresh();
      addTearDown(fresh.dispose);
      expect(fresh.workers, 1);
      expect(fresh.inlineThreads, 1);
      expect(settings.workers, 1);
      expect(settings.inlineThreads, 1);
    });

    test('depth defaults to kDefaultDepth', () {
      expect(settings.depth, kDefaultDepth);
    });

    test('multiPv defaults to kDefaultMultiPv', () {
      expect(settings.multiPv, kDefaultMultiPv);
    });

    test('maxAnalysisMoves defaults to kDefaultMaxAnalysisMoves', () {
      expect(settings.maxAnalysisMoves, kDefaultMaxAnalysisMoves);
    });
  });

  group('EngineSettings setters', () {
    test('depth rejects out-of-range values', () {
      settings.depth = 10;
      expect(settings.depth, 10);

      settings.depth = 200;
      expect(settings.depth, 10);

      settings.depth = 0;
      expect(settings.depth, 10);
    });

    test('multiPv rejects out-of-range values', () {
      settings.multiPv = 3;
      expect(settings.multiPv, 3);

      settings.multiPv = 0;
      expect(settings.multiPv, 3);

      settings.multiPv = 100;
      expect(settings.multiPv, 3);
    });

    test('maxAnalysisMoves rejects out-of-range values', () {
      settings.maxAnalysisMoves = 8;
      expect(settings.maxAnalysisMoves, 8);

      settings.maxAnalysisMoves = 0;
      expect(settings.maxAnalysisMoves, 8);

      settings.maxAnalysisMoves = 1000;
      expect(settings.maxAnalysisMoves, 8);
    });

    test('setting same value does not notify', () {
      var notifications = 0;
      settings.addListener(() => notifications++);

      final currentDepth = settings.depth;
      settings.depth = currentDepth;
      expect(notifications, 0);
    });

    test('setting new valid value notifies listeners', () {
      var notifications = 0;
      settings.addListener(() => notifications++);

      settings.depth = settings.depth + 5;
      expect(notifications, 1);
    });
  });

  group('EngineSettings persistence', () {
    test('loadFromPrefs restores saved values', () async {
      SharedPreferences.setMockInitialValues({
        'engine_settings.depth': 25,
        'engine_settings.multi_pv': 5,
        'engine_settings.workers': EngineSettings.systemCores,
        'engine_settings.inline_threads': EngineSettings.systemCores,
      });

      await settings.loadFromPrefs();

      expect(settings.depth, 25);
      expect(settings.multiPv, 5);
      expect(settings.workers, EngineSettings.systemCores);
      expect(settings.inlineThreads, EngineSettings.systemCores);
    });

    test('loadFromPrefs uses defaults for missing keys', () async {
      SharedPreferences.setMockInitialValues({});

      await settings.loadFromPrefs();

      expect(settings.depth, kDefaultDepth);
      expect(settings.multiPv, kDefaultMultiPv);
      expect(settings.workers, 1);
      expect(settings.inlineThreads, 1);
    });
  });
}
