import 'dart:async';

import 'package:chess_auto_prep/features/settings/controllers/eval_database_settings.dart';
import 'package:chess_auto_prep/features/settings/models/eval_database_configuration.dart';
import 'package:chess_auto_prep/features/settings/models/section_configuration.dart';
import 'package:chess_auto_prep/features/settings/widgets/settings_section_status.dart';
import 'package:chess_auto_prep/features/settings/repositories/settings_section_storage.dart';
import 'package:chess_auto_prep/services/eval/cdb_snapshot_download.dart';
import 'package:chess_auto_prep/services/eval/lichess_eval_controller.dart';
import 'package:chess_auto_prep/services/eval/lichess_eval_source.dart';
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
  int reads = 0;
  bool failRead = false;
  @override
  LichessEvalPhase get phase =>
      failRead ? LichessEvalPhase.failed : LichessEvalPhase.complete;
  @override
  String? get error => failRead ? 'Metadata unavailable' : null;
  @override
  int get storedPositions => 9;
  @override
  Future<void> loadSaved() async {
    reads++;
    if (failRead) throw StateError('Metadata unavailable');
    notifyListeners();
  }

  @override
  Future<void> start() async {
    starts++;
  }
}

class _PausedLichess extends _ReadyLichess {
  _PausedLichess(super.settings);
  final probe = Completer<LichessEvalSourceInfo>();
  int probes = 0;
  @override
  LichessEvalPhase get phase => LichessEvalPhase.paused;
  @override
  String? get parentDirectory => '/saved/download';
  @override
  Future<LichessEvalSourceInfo> refreshSource() {
    probes++;
    return probe.future;
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
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  SettingsSectionStatus(
                    owner: settings,
                    policy:
                        'Saved preferences apply to new builds and lookups.',
                  ),
                  const EvalDatabaseSettingsPanel(libraryAvailable: true),
                  const EvalDatabaseSettingsPanel(libraryAvailable: true),
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
      final storage = _Storage()
        ..value = EvalDatabaseConfiguration({
          'eval.cdbdirect.path': '/saved/cdb',
        });
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
        findsOneWidget,
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
      unawaited(settings.ensureLoaded().catchError((Object _) {}));
      await panels(tester, settings);
      expect(find.byType(Switch), findsNothing);
      expect(find.text('Loading saved preferences…'), findsOneWidget);
      storage.readGate!.complete();
      await tester.pumpAndSettle();
      expect(
        find.text('Saved preferences could not be loaded.'),
        findsOneWidget,
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

  testWidgets('download metadata retry reads without starting a transfer', (
    tester,
  ) async {
    final settings = EvalDatabaseSettings(_Storage());
    final download = _ReadyLichess(settings)..failRead = true;
    addTearDown(download.dispose);
    addTearDown(settings.dispose);
    await settings.ensureLoaded();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChangeNotifierProvider<LichessEvalController>.value(
            value: download,
            child: const LichessEvalCard(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(download.reads, 1);
    expect(find.text('Metadata unavailable'), findsOneWidget);
    expect(find.text('Resume'), findsNothing);
    download.failRead = false;
    await tester.tap(find.text('Reload saved download'));
    await tester.pumpAndSettle();
    expect(download.reads, 2);
    expect(download.starts, 0);
    expect(find.text('9 positions ready'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('paused download without metadata offers explicit setup', (
    tester,
  ) async {
    final settings = EvalDatabaseSettings(_Storage());
    final download = _PausedLichess(settings);
    addTearDown(download.dispose);
    addTearDown(settings.dispose);
    await settings.ensureLoaded();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChangeNotifierProvider<LichessEvalController>.value(
            value: download,
            child: const LichessEvalCard(),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Continue setup'), findsOneWidget);
    expect(find.text('Resume'), findsNothing);
    expect(download.probes, 0);
    await tester.tap(find.text('Continue setup'));
    await tester.pump();
    expect(find.text('Download the Lichess evaluations'), findsOneWidget);
    expect(download.probes, 1);
    expect(download.starts, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    download.probe.complete(LichessEvalSourceInfo.fallback);
    await tester.pump();
    expect(download.starts, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cards restore a replaced provider once and stop observing the old owner',
    (tester) async {
      final settings = EvalDatabaseSettings(_Storage());
      final first = _ReadyLichess(settings);
      final second = _ReadyLichess(settings);
      addTearDown(settings.dispose);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      Future<void> mount(LichessEvalController owner) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider<LichessEvalController>.value(
              value: owner,
              child: const LichessEvalCard(),
            ),
          ),
        ),
      );
      await mount(first);
      await tester.pump();
      expect(first.reads, 1);
      first.notifyListeners();
      await tester.pump();
      expect(first.reads, 1);
      await mount(second);
      await tester.pump();
      expect(second.reads, 1);
      first.failRead = true;
      first.notifyListeners();
      await tester.pump();
      expect(find.text('9 positions ready'), findsOneWidget);
      expect(find.text('Metadata unavailable'), findsNothing);
      expect(first.reads, 1);
      expect(second.reads, 1);
      expect(tester.takeException(), isNull);
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
          home: Scaffold(
            body: Column(
              children: [
                SettingsSectionStatus(
                  owner: settings,
                  policy: 'Saved preferences apply to new builds and lookups.',
                ),
                ChangeNotifierProvider<LichessEvalController>.value(
                  value: download,
                  child: const LichessEvalCard(),
                ),
              ],
            ),
          ),
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
