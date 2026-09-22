import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/features/databases/widgets/databases_screen.dart';
import 'package:chess_auto_prep/features/settings/controllers/eval_database_settings.dart';
import 'package:chess_auto_prep/services/eval/cdb_snapshot_download.dart';
import 'package:chess_auto_prep/services/eval/lichess_eval_controller.dart';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import 'package:chess_auto_prep/infrastructure/settings/fresh_desktop_preferences_store.dart';
import 'package:chess_auto_prep/features/settings/models/settings_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chess_auto_prep/main.dart';
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/features/settings/models/app_appearance.dart';
import 'package:chess_auto_prep/features/settings/widgets/appearance_settings.dart';
import 'package:chess_auto_prep/features/repertoires/widgets/repertoire_creation_screen.dart';
import 'package:chess_auto_prep/infrastructure/settings/persisted_appearance.dart';
import 'package:chess_auto_prep/infrastructure/settings/shared_preferences_app_settings_repository.dart';
import 'helpers/board_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  installFreshDesktopPreferencesStore();
  testWidgets(
    'native evaluation preferences fail visibly, retry and survive restart',
    (tester) async {
      final runtime = RuntimeSettings.preferences();
      await runtime.load();
      await runtime.engine.edit({'engine_lifecycle.toggle_on': false});
      await runtime.databases.resetToDefaults();
      await tester.pumpWidget(ChessAutoPrepApp(runtimeSettings: runtime));
      await tester.pumpAndSettle();
      getAppState(tester).setMode(AppMode.databases);
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(DatabasesScreen));
      final owner = context.read<EvalDatabaseSettings>();
      expect(owner, same(runtime.databases));
      expect(
        context.read<CdbSnapshotDownloadController>().settings,
        same(owner),
      );
      expect(context.read<LichessEvalController>().settings, same(owner));
      final file = File(
        p.join(
          (await getApplicationSupportDirectory()).path,
          'shared_preferences.json',
        ),
      );
      final before = await file.readAsString();
      expect((await Process.run('chmod', ['400', file.path])).exitCode, 0);
      try {
        await expectLater(
          owner.setChessDbApiForExpectimax(true),
          throwsStateError,
        );
        await tester.pumpAndSettle();
        expect(owner.committed.chessDbApiForExpectimax, isFalse);
        expect(owner.editing.chessDbApiForExpectimax, isTrue);
        expect(
          find.text(
            'Preferences were not saved. Your changes are kept for retry.',
          ),
          findsOneWidget,
        );
        expect(await file.readAsString(), before);
        final view = RendererBinding.instance.renderViews.first;
        final image = await (view.debugLayer! as OffsetLayer).toImage(
          Offset.zero & view.size,
        );
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await File(
          '/tmp/renewal-eval-settings-failure.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        expect((await Process.run('chmod', ['600', file.path])).exitCode, 0);
      }
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(owner.committed.chessDbApiForExpectimax, isTrue);
      expect(
        find.text(
          'Preferences were not saved. Your changes are kept for retry.',
        ),
        findsNothing,
      );
      final restarted = RuntimeSettings.preferences();
      await restarted.load();
      expect(restarted.databases.committed.chessDbApiForExpectimax, isTrue);
      restarted.dispose();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'native read-only preferences retain confirmed appearance and retry after repair',
    (tester) async {
      final repository = SharedPreferencesAppSettingsRepository().appearance;
      await repository.setAppearance(AppAppearance.dark);
      final file = File(
        p.join(
          (await getApplicationSupportDirectory()).path,
          'shared_preferences.json',
        ),
      );
      final before = await file.readAsString();
      expect((await Process.run('chmod', ['400', file.path])).exitCode, 0);
      try {
        await expectLater(
          repository.setAppearance(AppAppearance.light),
          throwsStateError,
        );
        expect(repository.state.phase, SettingsPhase.failed);
        expect(repository.state.committed, AppAppearance.dark);
        expect(repository.state.draft, AppAppearance.light);
        expect(await file.readAsString(), before);
      } finally {
        expect((await Process.run('chmod', ['600', file.path])).exitCode, 0);
      }
      await repository.retry();
      expect(repository.state.committed, AppAppearance.light);
      final restarted = SharedPreferencesAppSettingsRepository().appearance;
      await restarted.ensureLoaded();
      expect(restarted.state.committed, AppAppearance.light);
    },
    skip: !Platform.isLinux,
  );

  testWidgets(
    'native appearance preserves an open creation draft and reloads from preferences',
    (tester) async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove(SharedPreferencesAppearance.key);
      addTearDown(() async {
        await preferences.remove(SharedPreferencesAppearance.key);
      });
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repository = SharedPreferencesAppSettingsRepository();
      await tester.pumpWidget(ChessAutoPrepApp(settings: repository));
      await tester.pumpAndSettle();
      getAppState(tester).setMode(AppMode.repertoireLibrary);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create new repertoire'));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('repertoire-create-name'));
      await tester.enterText(field, 'Theme switch draft');
      final state = tester.state(find.byType(RepertoireCreationScreen));
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-nav-7')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      expect(repository.appearance.state.committed, AppAppearance.light);
      expect(
        Theme.of(tester.element(find.byType(AppearanceSettings))).brightness,
        Brightness.light,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(RepertoireCreationScreen)), same(state));
      expect(
        tester.widget<TextFormField>(field).controller!.text,
        'Theme switch draft',
      );
      expect(Theme.of(tester.element(field)).brightness, Brightness.light);
      expect(find.text('Actions').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Actions'));
      await tester.pumpAndSettle();
      expect(find.text('Back to previous view'), findsOneWidget);
      await tester.tap(find.text('Back to previous view'));
      await tester.pumpAndSettle();
      expect(find.text('Create new repertoire'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      final restarted = SharedPreferencesAppSettingsRepository();
      await tester.pumpWidget(ChessAutoPrepApp(settings: restarted));
      await tester.pumpAndSettle();
      expect(restarted.appearance.state.committed, AppAppearance.light);
      getAppState(tester).setMode(AppMode.repertoireLibrary);
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.text('Create new repertoire'))).brightness,
        Brightness.light,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
