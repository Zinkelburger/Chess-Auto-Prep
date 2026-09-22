import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/app/generation_dependencies.dart';
import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:chess_auto_prep/features/generation/models/generation_artifacts.dart';
import 'package:chess_auto_prep/features/generation/controllers/generation_recovery_controller.dart';
import 'package:chess_auto_prep/features/generation/services/generation_artifacts.dart';
import 'package:chess_auto_prep/features/generation/widgets/generation_recovery_dialog.dart';
import 'package:chess_auto_prep/features/repertoire/widgets/repertoire_toolbar.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/generation/storage_generation_artifact_repository.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/legacy_analysis_fixture.dart';

class _Picker extends FilePickerPlatform {
  _Picker(this.path);
  final String path;
  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => path;
}

Future<void> _until(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(finder, findsWidgets);
}

Future<void> _waitRecovery(WidgetTester tester) async {
  await _until(tester, find.byType(GenerationRecoveryDialog));
  final controller =
      tester
              .widget<ListenableBuilder>(
                find
                    .descendant(
                      of: find.byType(GenerationRecoveryDialog),
                      matching: find.byType(ListenableBuilder),
                    )
                    .first,
              )
              .listenable
          as GenerationRecoveryController;
  for (var i = 0; i < 150 && controller.loading; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(controller.loading, false);
}

void main() {
  testWidgets(
    'partial source discovery keeps healthy recovery usable and Refresh retries',
    (tester) async {
      final root = Directory.systemTemp.createTempSync(
        'recovery-partial-list-',
      );
      final healthy = Directory(
        p.join(root.path, 'Healthy', '.cap-generation', 'Deleted.pgn', 'run'),
      )..createSync(recursive: true);
      final locked = Directory(p.join(root.path, 'Locked'));
      Directory(
        p.join(locked.path, '.cap-generation', 'Other.pgn', 'run'),
      ).createSync(recursive: true);
      File(p.join(healthy.path, 'course.pgn')).writeAsStringSync('1. e4 *');
      addTearDown(() {
        Process.runSync('chmod', ['700', locked.path]);
        root.deleteSync(recursive: true);
      });
      tester.view.physicalSize = const Size(1200, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      expect(Process.runSync('chmod', ['000', locked.path]).exitCode, 0);
      final artifacts = GenerationArtifacts(
        StorageGenerationArtifactRepository(
          storage: IOStorageService(documentsRoot: root, supportRoot: root),
          documents: NativePgnDocumentStore(),
          recoveryRoot: () async => root.path,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: GenerationRecoveryDialog(
            artifacts: artifacts,
            chooseExportDestination: (_) async => null,
          ),
        ),
      );
      await _waitRecovery(tester);
      expect(find.text(locked.path), findsOneWidget);
      expect(find.textContaining('could not be inspected'), findsOneWidget);
      final healthySource = find.byKey(
        const ValueKey('recovery-source-Healthy/Deleted.pgn'),
      );
      await tester.ensureVisible(healthySource);
      await tester.tap(healthySource);
      await _waitRecovery(tester);
      await tester.ensureVisible(find.byKey(const Key('recovery-all-sources')));
      await tester.tap(find.byKey(const Key('recovery-all-sources')));
      await _waitRecovery(tester);
      expect(Process.runSync('chmod', ['700', locked.path]).exitCode, 0);
      await tester.ensureVisible(find.text('Refresh'));
      await tester.tap(find.text('Refresh'));
      await _waitRecovery(tester);
      expect(find.textContaining('could not be inspected'), findsNothing);
      expect(
        find.byKey(const ValueKey('recovery-source-Healthy/Deleted.pgn')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('recovery-source-Locked/Other.pgn')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !Platform.isLinux,
  );

  for (final compact in [false, true]) {
    testWidgets(
      'retained PGN is discoverable, readable and exportable at ${compact ? "200 percent narrow" : "desktop"}',
      (tester) async {
        final root = Directory.systemTemp.createTempSync(
          'retained-recovery-widget-',
        );
        final originalPicker = FilePickerPlatform.instance;
        FilePickerPlatform.instance = _Picker(root.path);
        addTearDown(() {
          FilePickerPlatform.instance = originalPicker;
          root.deleteSync(recursive: true);
        });
        tester.view.physicalSize = compact
            ? const Size(640, 480)
            : const Size(1200, 950);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final path = p.join(root.path, 'Main.pgn');
        File(path).writeAsStringSync('1. d4 *');
        final directory = Directory(
          p.join(root.path, '.cap-generation', 'Main.pgn', 'retained-run'),
        )..createSync(recursive: true);
        File(p.join(directory.path, 'manifest.json')).writeAsStringSync(
          jsonEncode({
            'version': 1,
            'runId': 'retained-run',
            'source': path,
            'baseline': {
              'documentId': 'old',
              'nativeIdentity': 'old',
              'sha256': 'old',
            },
            'config': {'depth': 8},
            'course': 'course.pgn',
            'modelGames': 'model_games.pgn',
          }),
        );
        const proposal =
            '[Event "Recoverable generated proposal"]\n\n1. e4 e5 *';
        File(p.join(directory.path, 'course.pgn')).writeAsStringSync(proposal);
        // Missing model-games demonstrates a failed partial staging: the course
        // remains inspectable/exportable and publication remains uncertain.
        final artifacts = GenerationArtifacts(
          StorageGenerationArtifactRepository(
            storage: IOStorageService(documentsRoot: root, supportRoot: root),
            documents: NativePgnDocumentStore(),
            recoveryRoot: () async => root.path,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(compact ? 2 : 1)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => RepertoireActionsMenu(
                  onRecoverAnalysis: () => unawaited(
                    showGenerationRecovery(context, artifacts: artifacts),
                  ),
                ),
              ),
            ),
          ),
        );
        File(path).deleteSync();
        await tester.tap(find.text('Actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Recover generated outputs…'));
        await _waitRecovery(tester);
        Finder outer() => find
            .descendant(
              of: find.byKey(const Key('generation-recovery-scroll')),
              matching: find.byType(Scrollable),
            )
            .first;
        Future<void> show(Finder finder, double direction) async {
          await tester.scrollUntilVisible(
            finder.hitTestable(),
            direction,
            scrollable: outer(),
            maxScrolls: 80,
          );
          await tester.pumpAndSettle();
          expect(finder.hitTestable(), findsWidgets);
        }

        await show(find.byKey(const ValueKey('recovery-source-Main.pgn')), 160);
        final namespace = directory.parent.parent;
        final held = namespace.renameSync('${namespace.path}-held');
        final outside = Directory(p.join(root.path, 'outside'))..createSync();
        Link(namespace.path).createSync(outside.path);
        await tester.tap(
          find.byKey(const ValueKey('recovery-source-Main.pgn')),
        );
        await _waitRecovery(tester);
        await show(
          find.textContaining('This folder could not be inspected'),
          160,
        );
        Link(namespace.path).deleteSync();
        held.renameSync(namespace.path);
        await show(find.text('Refresh'), -160);
        await tester.tap(find.text('Refresh'));
        await _waitRecovery(tester);
        await show(find.text('Choose saved output'), 160);
        await tester.tap(find.text('Choose saved output'));
        await tester.pumpAndSettle();
        await show(
          find.byKey(const ValueKey('recovery-run-retained-run')),
          160,
        );
        await tester.tap(
          find.byKey(const ValueKey('recovery-run-retained-run')),
        );
        await _waitRecovery(tester);
        await show(
          find.textContaining('The current chapter could not be read'),
          160,
        );
        expect(
          find
              .textContaining('The current chapter could not be read')
              .hitTestable(),
          findsOneWidget,
        );
        await show(
          find.textContaining('No publication receipt was found'),
          160,
        );
        expect(
          find.textContaining('The PGN write may still have succeeded'),
          findsOneWidget,
        );
        // The desktop chooser has its own scrollbar; the narrow layout has one.
        await show(find.byKey(const Key('recovery-course-0')), 160);
        await tester.tap(find.byKey(const Key('recovery-course-0')));
        await tester.pump();
        await show(find.text(proposal), 160);
        await show(find.byKey(const Key('generation-recovery-export')), -200);
        await tester.tap(find.byKey(const Key('generation-recovery-export')));
        await _until(tester, find.textContaining('Original file exported to'));
        final exported = root.listSync().whereType<File>().singleWhere(
          (f) => p.basename(f.path).startsWith('Generated-recovered-course-'),
        );
        expect(exported.path.endsWith('.pgn'), true);
        expect(
          exported.readAsBytesSync(),
          File(p.join(directory.path, 'course.pgn')).readAsBytesSync(),
        );
        expect(File(path).existsSync(), false);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'production Actions opens native recovery, navigates, exports and reopens',
    (tester) async {
      final root = Directory.systemTemp.createTempSync(
        'recovery-recovery-widget-',
      );
      final originalPicker = FilePickerPlatform.instance;
      FilePickerPlatform.instance = _Picker(root.path);
      addTearDown(() {
        FilePickerPlatform.instance = originalPicker;
        root.deleteSync(recursive: true);
      });
      tester.view.physicalSize = const Size(1200, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final path = p.join(root.path, 'Main.pgn');
      File(path).writeAsStringSync('1. d4 *');
      const suffixes = {
        GenerationArtifactKind.tree: 'tree',
        GenerationArtifactKind.probes: 'expectimax',
        GenerationArtifactKind.partial: 'partial_tree',
        GenerationArtifactKind.traps: 'traps',
      };
      for (final entry in legacyRecoveryPayloads().entries) {
        File(
          p.join(root.path, 'Main_${suffixes[entry.key]}.json'),
        ).writeAsStringSync(entry.value);
      }
      GenerationArtifacts artifacts() => GenerationArtifacts(
        StorageGenerationArtifactRepository(
          storage: IOStorageService(documentsRoot: root, supportRoot: root),
          documents: NativePgnDocumentStore(),
        ),
      );
      Future<void> mount() => tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => RepertoireActionsMenu(
                onRecoverAnalysis: () => unawaited(
                  showGenerationRecovery(
                    context,
                    path: path,
                    artifacts: artifacts(),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await mount();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recover generated outputs…'));
      await _until(tester, find.byKey(const Key('recovery-tree-0')));
      await tester.tap(find.byKey(const Key('recovery-tree-0')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('recovery-node-1')));
      await tester.pump();
      expect(
        find.byKey(const Key('generation-recovery-parent')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('recovery-probes-0')));
      await tester.pump();
      expect(find.text('2 saved nodes · depth 1'), findsOneWidget);
      await tester.tap(find.byKey(const Key('recovery-traps-0')));
      await tester.pump();
      expect(find.text('f6'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('recovery-partial-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('recovery-partial-0')));
      await tester.pump();
      expect(
        find.textContaining('Automatic resume is unavailable'),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const Key('generation-recovery-export')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('generation-recovery-export')));
      await _until(tester, find.textContaining('Original file exported to'));
      final exported = root.listSync().whereType<File>().singleWhere(
        (f) => p.basename(f.path).startsWith('Main-recovered-partial-'),
      );
      expect(
        exported.readAsBytesSync(),
        File(p.join(root.path, 'Main_partial_tree.json')).readAsBytesSync(),
      );
      expect(File(path).readAsStringSync(), '1. d4 *');
      expect(
        File(
          StorageGenerationArtifactRepository.pointerPath(path),
        ).existsSync(),
        false,
      );
      await tester.scrollUntilVisible(
        find.byTooltip('Close').hitTestable(),
        -180,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('generation-recovery-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await mount();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recover generated outputs…'));
      await _until(tester, find.byKey(const Key('recovery-partial-0')));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final size in [const Size(640, 480), const Size(800, 600)]) {
    testWidgets('recovery remains usable at $size and 200 percent text', (
      tester,
    ) async {
      final root = Directory.systemTemp.createTempSync(
        'recovery-recovery-scaled-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final path = p.join(root.path, 'Main.pgn');
      File(p.join(root.path, 'Main_tree.json')).writeAsStringSync(
        legacyRecoveryPayloads()[GenerationArtifactKind.tree]!,
      );
      final artifacts = GenerationArtifacts(
        StorageGenerationArtifactRepository(
          storage: IOStorageService(documentsRoot: root, supportRoot: root),
          documents: NativePgnDocumentStore(),
          flushRecoveryDirectory: (_) async =>
              throw StateError('flush acknowledgement unavailable'),
        ),
      );
      final destination = p.join(root.path, 'Recovered.json');
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: GenerationRecoveryDialog(
            path: path,
            artifacts: artifacts,
            chooseExportDestination: (_) async => destination,
          ),
        ),
      );
      await _until(tester, find.text('Recover generated outputs'));
      final controller =
          tester
                  .widget<ListenableBuilder>(
                    find
                        .descendant(
                          of: find.byType(GenerationRecoveryDialog),
                          matching: find.byType(ListenableBuilder),
                        )
                        .first,
                  )
                  .listenable
              as GenerationRecoveryController;
      for (var i = 0; i < 100 && controller.loading; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(controller.loading, false);
      await tester.scrollUntilVisible(
        find.byKey(const Key('recovery-tree-0')).hitTestable(),
        120,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('generation-recovery-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('recovery-tree-0')));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byKey(const Key('generation-recovery-export')),
        -200,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('generation-recovery-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const Key('generation-recovery-export'))),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('generation-recovery-export')).hitTestable(),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const Key('generation-recovery-export')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('generation-recovery-export')));
      await _until(tester, find.text('Destination: $destination'));
      await tester.ensureVisible(find.text('Destination: $destination'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('The export may have been saved'),
        findsOneWidget,
      );
      expect(
        find.text('Destination: $destination').hitTestable(),
        findsOneWidget,
      );
      expect(File(destination).existsSync(), true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'damaged tree remains exportable and an export failure is visible',
    (tester) async {
      final root = Directory.systemTemp.createTempSync(
        'recovery-recovery-failure-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final path = p.join(root.path, 'Main.pgn');
      final damaged = File(p.join(root.path, 'Main_tree.json'))
        ..writeAsStringSync('{broken');
      final artifacts = GenerationArtifacts(
        StorageGenerationArtifactRepository(
          storage: IOStorageService(documentsRoot: root, supportRoot: root),
          documents: NativePgnDocumentStore(),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: GenerationRecoveryDialog(
            path: path,
            artifacts: artifacts,
            chooseExportDestination: (_) async => damaged.path,
          ),
        ),
      );
      await _until(tester, find.byKey(const Key('recovery-tree-0')));
      await tester.tap(find.byKey(const Key('recovery-tree-0')));
      await tester.pump();
      expect(find.text('Could not read this entry'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('generation-recovery-export')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('generation-recovery-export')));
      await _until(
        tester,
        find.textContaining('A file already exists at that destination'),
      );
      expect(damaged.readAsStringSync(), '{broken');
      expect(find.textContaining('Original file exported to'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
