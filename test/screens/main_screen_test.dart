import 'package:chess_auto_prep/features/repertoire/services/repertoire_outline_service.dart';
import '../support/repertoire_dependencies.dart';
import 'package:chess_auto_prep/app/builder_lifetime.dart';
import 'package:chess_auto_prep/app/generation_dependencies.dart';
import 'package:chess_auto_prep/features/generation/services/generation_artifacts.dart';
import 'package:chess_auto_prep/app/repertoire_dependencies.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_document_repository.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_decoder.dart';
import 'package:chess_auto_prep/features/training/controllers/training_settings_controller.dart';
import '../support/scripted_document_store.dart';
import '../support/training_settings.dart';
import '../support/board_engine_fixture.dart';
import 'package:flutter/material.dart';
import 'package:chess_auto_prep/app/app_dependencies.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import '../../widgetbook/repertoire_cases.dart'
    show FixtureRepertoireRepository, CatalogScenario;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/core/app_history.dart';
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/screens/main_screen.dart';
import 'package:chess_auto_prep/widgets/settings/settings_navigation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    useScriptedBoardEngine();
  });

  testWidgets(
    'analysis screen is created lazily and kept alive across mode switches',
    (tester) async {
      final appState = AppState();
      final documents = Store();
      final trainingSettings = TrainingSettingsController(
        MemoryTrainingSettings(),
      );
      await trainingSettings.ensureLoaded();
      addTearDown(trainingSettings.dispose);

      Future<void> pumpNavigation() async {
        // First visit shows a one-frame loading placeholder, then constructs
        // the screen on the next frame (see _MainScreenState.build) — hence
        // the extra pump before the navigation-animation pumps.
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
      }

      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<GenerationArtifacts>(
              create: (_) => createGenerationArtifacts(documents: documents),
            ),
            Provider<RepertoireOutlineService>(
              create: (_) => createRepertoireOutline(
                documents: documents,
                catalog: FixtureRepertoireRepository(CatalogScenario.populated),
              ),
            ),
            Provider<RepertoireDocumentRepository>(
              create: (_) => createRepertoireDocuments(documents: documents),
            ),
            Provider<RepertoireDecoder>(
              create: (_) => createRepertoireDecoder(),
            ),
            Provider<BuilderLifetime>(
              create: (ctx) => testBuilderLifetime(
                documents: ctx.read<RepertoireDocumentRepository>(),
                decoder: ctx.read<RepertoireDecoder>(),
              ),
              dispose: (_, lifetime) => lifetime.dispose(),
            ),
            ChangeNotifierProvider<AppState>.value(value: appState),
            ChangeNotifierProvider<AppHistory>(
              lazy: false,
              create: (_) => AppHistory(appState),
            ),
          ],
          child: AppDependencies(
            documentStore: documents,
            trainingSettings: trainingSettings,
            repertoireCatalog: FixtureRepertoireRepository(
              CatalogScenario.empty,
            ),
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: MainScreen(),
            ),
          ),
        ),
      );
      await pumpNavigation();

      expect(find.text('Which player?'), findsNothing);
      final registry = ViewSettingsRegistry.forApp(appState);
      registry.requestView(AppMode.repertoireTrainer);
      await pumpNavigation();
      expect(registry.entries[AppMode.repertoireTrainer]?.builder, isNotNull);
      expect(appState.currentMode, AppMode.tactics);

      appState.setMode(AppMode.positionAnalysis);
      await pumpNavigation();
      expect(find.text('Which player?'), findsOneWidget);
      // Both former primary modifiers must leave the current mode alone.
      for (final modifier in [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.metaLeft,
      ]) {
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
        await tester.sendKeyUpEvent(modifier);
        await pumpNavigation();
        expect(appState.currentMode, AppMode.positionAnalysis);
      }

      // Picking material stays inside this mode, beneath the app controls.
      expect(find.byTooltip('Settings').hitTestable(), findsOneWidget);
      expect(find.text('Actions').hitTestable(), findsOneWidget);
      expect(find.text('No player selected'), findsNothing);

      appState.setMode(AppMode.tactics);
      await pumpNavigation();
      appState.setMode(AppMode.positionAnalysis);
      await pumpNavigation();

      expect(find.text('Which player?'), findsOneWidget);
      expect(find.byTooltip('Settings').hitTestable(), findsOneWidget);
    },
  );
}
