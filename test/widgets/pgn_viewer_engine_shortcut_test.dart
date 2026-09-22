import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import 'package:chess_auto_prep/app/runtime_settings.dart';
import 'package:chess_auto_prep/app/engine_runtime.dart';
import '../support/runtime_settings.dart';
import 'package:chess_auto_prep/app/viewer_dependencies.dart';
import '../support/fake_desktop_fullscreen_port.dart';
import 'dart:io';

import 'package:chess_auto_prep/infrastructure/documents/isolate_pgn_collection_filter.dart';

import 'package:chess_auto_prep/infrastructure/documents/storage_pgn_library_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/isolate_pgn_collection_decoder.dart';

import 'package:chess_auto_prep/infrastructure/documents/shared_preferences_viewer_repository.dart';
import 'package:chess_auto_prep/app/pgn_viewer_lifetime.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_workspace_snapshot.dart';
import '../support/memory_workspace_recovery_store.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/infrastructure/documents/storage_pgn_collection_repository.dart';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/screens/pgn_viewer_screen.dart';
import 'package:chess_auto_prep/widgets/engine/inline_engine_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/board_engine_fixture.dart';

RuntimeSettings? _engineFixtureSettings;
EngineRuntime get engines =>
    testEngines(_engineFixtureSettings ??= testRuntimeSettings());
void main() {
  setUp(() {
    _engineFixtureSettings = null;
    addTearDown(() => _engineFixtureSettings?.dispose());
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  late PgnViewerLifetime lifetime;
  setUp(() {
    SharedPreferences.setMockInitialValues({});

    useScriptedBoardEngine();
    const windowChannel = MethodChannel('window_manager');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (_) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowChannel, null);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return {'text': '[White "A"]\n[Black "B"]\n\n1. e4 e5 *'};
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    final directory = Directory.systemTemp.createTempSync('engine-shortcut-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => directory.path);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      directory.deleteSync(recursive: true);
    });
    lifetime = PgnViewerLifetime(
      pool: engines.pool,
      lifecycle: engines.lifecycle,
      positionIndex: createViewerPositionIndex(),
      openings: createViewerOpenings(),
      solitaireRepository: createViewerSolitaire(),
      window: FakeDesktopFullscreenPort(),
      collectionDecoder: const IsolatePgnCollectionDecoder(),
      collectionFilter: const IsolatePgnCollectionFilter(),
      library: StoragePgnLibraryRepository(
        StorageFactory.instance,
        directory: () async => '/collections',
      ),
      preferences: SharedPreferencesViewerRepository(
        SharedPreferences.getInstance,
      ),
      repository: StoragePgnCollectionRepository(
        StorageFactory.instance,
        documents: LegacyPgnDocumentStore(StorageFactory.instance),
      ),
      store: MemoryWorkspaceRecoveryStore<PgnWorkspaceSnapshot>(),
    );
    addTearDown(lifetime.shutdown);
  });

  for (final initiallyEnabled in [false, true]) {
    testWidgets(
      'E reveals the hidden engine (enabled: $initiallyEnabled), then stops without hiding',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final app = AppState()..setMode(AppMode.pgnViewer);
        addTearDown(app.dispose);
        if (initiallyEnabled) await engines.lifecycle.toggleOn();
        await pumpRuntimeWidget(
          tester,
          _engineFixtureSettings ??= testRuntimeSettings(),
          ChangeNotifierProvider.value(
            value: app,
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: PgnViewerCloseHost(
                lifetime: lifetime,
                child: PgnViewerScreen(lifetime: lifetime),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)),
        );
        await tester.pumpAndSettle();
        expect(find.byType(InlineEngineBar), findsNothing);

        await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
        await tester.pumpAndSettle();
        expect(find.byType(InlineEngineBar), findsOneWidget);
        expect(
          InlineEngineBar.isEngineEnabled(
            tester.element(find.byType(InlineEngineBar).first),
          ),
          isTrue,
        );
        expect(find.byTooltip('Toggle engine (E)'), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
        await tester.pumpAndSettle();
        expect(
          InlineEngineBar.isEngineEnabled(
            tester.element(find.byType(InlineEngineBar).first),
          ),
          isFalse,
        );
        expect(find.byType(InlineEngineBar), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
        await tester.pumpAndSettle();
        expect(
          InlineEngineBar.isEngineEnabled(
            tester.element(find.byType(InlineEngineBar).first),
          ),
          isTrue,
        );
        expect(find.byType(InlineEngineBar), findsOneWidget);
        await pumpRuntimeWidget(
          tester,
          _engineFixtureSettings ??= testRuntimeSettings(),
          const SizedBox.shrink(),
        );
        await tester.runAsync(lifetime.shutdown);
        await tester.pumpAndSettle();
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );
  }
}
