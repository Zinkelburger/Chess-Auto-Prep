import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/app/generation_dependencies.dart';
import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:chess_auto_prep/features/generation/models/generation_artifacts.dart';
import 'package:chess_auto_prep/features/generation/services/generation_artifacts.dart';
import 'package:chess_auto_prep/features/generation/widgets/legacy_analysis_dialog.dart';
import 'package:chess_auto_prep/features/repertoire/widgets/repertoire_toolbar.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/generation/storage_generation_artifact_repository.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:file_picker_platform_interface/file_picker_platform_interface.dart';
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

void main() {
  testWidgets(
    'production Actions opens native recovery, navigates, exports and reopens',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'legacy-recovery-widget-',
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
                  showLegacyAnalysisRecovery(
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
      await tester.tap(find.text('Recover older analysis…'));
      await _until(tester, find.byKey(const Key('legacy-tree-0')));
      await tester.tap(find.byKey(const Key('legacy-tree-0')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('legacy-node-1')));
      await tester.pump();
      expect(find.byKey(const Key('legacy-analysis-parent')), findsOneWidget);
      await tester.tap(find.byKey(const Key('legacy-probes-0')));
      await tester.pump();
      expect(find.text('2 saved nodes · depth 1'), findsOneWidget);
      await tester.tap(find.byKey(const Key('legacy-traps-0')));
      await tester.pump();
      expect(find.textContaining('"popular_move": "f6"'), findsOneWidget);
      await tester.tap(find.byKey(const Key('legacy-partial-0')));
      await tester.pump();
      expect(
        find.textContaining('Automatic resume is unavailable'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('legacy-analysis-export')));
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
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await mount();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recover older analysis…'));
      await _until(tester, find.byKey(const Key('legacy-partial-0')));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'damaged tree remains exportable and an export failure is visible',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'legacy-recovery-failure-',
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
          home: LegacyAnalysisDialog(
            path: path,
            artifacts: artifacts,
            chooseExportDestination: (_) async => damaged.path,
          ),
        ),
      );
      await _until(tester, find.byKey(const Key('legacy-tree-0')));
      await tester.tap(find.byKey(const Key('legacy-tree-0')));
      await tester.pump();
      expect(find.text('Could not read this entry'), findsOneWidget);
      await tester.tap(find.byKey(const Key('legacy-analysis-export')));
      await _until(
        tester,
        find.textContaining('existing destination is never replaced'),
      );
      expect(damaged.readAsStringSync(), '{broken');
      expect(find.textContaining('Original file exported to'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
