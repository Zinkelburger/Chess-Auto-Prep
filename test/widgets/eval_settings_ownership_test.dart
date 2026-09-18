import 'dart:async';

import 'package:chess_auto_prep/features/settings/controllers/eval_database_settings.dart';
import 'package:chess_auto_prep/features/settings/models/eval_database_configuration.dart';
import 'package:chess_auto_prep/features/settings/models/section_configuration.dart';
import 'package:chess_auto_prep/features/settings/repositories/settings_section_storage.dart';
import 'package:chess_auto_prep/services/eval/cdb_snapshot_download.dart';
import 'package:chess_auto_prep/services/eval/lichess_eval_controller.dart';
import 'package:chess_auto_prep/widgets/eval_database_settings_panel.dart';
import 'package:chess_auto_prep/widgets/lichess_eval_download_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Storage implements SettingsSectionStorage<EvalDatabaseConfiguration> {
  EvalDatabaseConfiguration value = EvalDatabaseConfiguration();
  Completer<void>? readGate;
  bool failRead = false;
  bool failWrite = false;
  int writes = 0;

  @override
  Future<EvalDatabaseConfiguration> read() async {
    await readGate?.future;
    if (failRead) throw StateError('offline preferences');
    return value;
  }

  @override
  Future<void> write(SettingsPatch<EvalDatabaseConfiguration> patch) async {
    writes++;
    if (failWrite) throw StateError('write rejected');
    value = patch.apply(value);
  }
}

class _ReadyLichess extends LichessEvalController {
  _ReadyLichess(EvalDatabaseSettings settings) : super(settings: settings);
  int starts = 0;
  @override
  LichessEvalPhase get phase => LichessEvalPhase.complete;
  @override
  int get storedPositions => 9;
  @override
  Future<void> loadSaved() async {}
  @override
  Future<void> start() async {
    starts++;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> panels(
    WidgetTester tester,
    EvalDatabaseSettings settings,
  ) async {
    final download = CdbSnapshotDownloadController(settings: settings);
    addTearDown(download.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<EvalDatabaseSettings>.value(value: settings),
          ChangeNotifierProvider<CdbSnapshotDownloadController>.value(
            value: download,
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  EvalDatabaseSettingsPanel(libraryAvailable: true),
                  EvalDatabaseSettingsPanel(libraryAvailable: true),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'two panels share failed draft, committed values and explicit retry',
    (tester) async {
      final storage = _Storage();
      final settings = EvalDatabaseSettings(storage);
      addTearDown(settings.dispose);
      await settings.ensureLoaded();
      await panels(tester, settings);
      storage.failWrite = true;
      // The two enabled switches are the same machine-wide preference.
      final switches = tester
          .widgetList<Switch>(find.byType(Switch))
          .where((w) => w.onChanged != null)
          .toList();
      expect(switches, hasLength(2));
      switches.first.onChanged!(true);
      await tester.pumpAndSettle();
      expect(settings.committed.enableCdbDirect, isFalse);
      expect(settings.editing.enableCdbDirect, isTrue);
      expect(
        tester.widgetList<Switch>(find.byType(Switch)).where((w) => w.value),
        hasLength(2),
      );
      expect(
        find.text(
          'Preferences were not saved. Your changes are kept for retry.',
        ),
        findsNWidgets(2),
      );
      storage.failWrite = false;
      await tester.tap(find.text('Retry').first);
      await tester.pumpAndSettle();
      expect(settings.committed.enableCdbDirect, isTrue);
      expect(storage.value.enableCdbDirect, isTrue);
      expect(find.text('Retry'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unknown and failed reads never render preferences as off; retry restores saved values',
    (tester) async {
      final storage = _Storage()
        ..value = EvalDatabaseConfiguration({'eval.cdbdirect.enabled': true})
        ..readGate = Completer<void>()
        ..failRead = true;
      final settings = EvalDatabaseSettings(storage);
      addTearDown(settings.dispose);
      await panels(tester, settings);
      expect(find.byType(Switch), findsNothing);
      expect(find.text('Loading saved preferences…'), findsNWidgets(2));
      storage.readGate!.complete();
      await tester.pumpAndSettle();
      expect(
        find.text('Saved preferences could not be loaded.'),
        findsNWidgets(2),
      );
      expect(find.byType(Switch), findsNothing);
      storage.failRead = false;
      await tester.tap(find.text('Retry').first);
      await tester.pumpAndSettle();
      expect(settings.committed.enableCdbDirect, isTrue);
      expect(
        tester.widgetList<Switch>(find.byType(Switch)).where((w) => w.value),
        hasLength(2),
      );
      expect(storage.writes, 0);
    },
  );

  testWidgets(
    'activation retry preserves ready artifact and never restarts download',
    (tester) async {
      final storage = _Storage();
      final settings = EvalDatabaseSettings(storage);
      final download = _ReadyLichess(settings);
      addTearDown(download.dispose);
      addTearDown(settings.dispose);
      await settings.ensureLoaded();
      storage.failWrite = true;
      await expectLater(
        settings.configureLichessDirectory('/saved/evals'),
        throwsStateError,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LichessEvalCard(controller: download)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('9 positions ready'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(settings.committed.enableLichessEvals, isFalse);
      storage.failWrite = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(settings.committed.enableLichessEvals, isTrue);
      expect(settings.committed.lichessEvalsPath, '/saved/evals');
      expect(find.text('9 positions ready'), findsOneWidget);
      expect(download.starts, 0);
    },
  );
}
