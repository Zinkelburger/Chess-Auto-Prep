import 'dart:io';
import 'dart:ui' as ui;

import 'package:chess_auto_prep/app/builder_lifetime.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/screens/repertoire_screen.dart';
import 'package:chess_auto_prep/services/jobs/repertoire_job.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/widgets/repertoire_generation_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'helpers/board_helpers.dart';
import 'helpers/tactics_helpers.dart';

Future<void> _ready(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 120 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsOneWidget);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _captureRejection() async {
  final view = RendererBinding.instance.renderViews.first;
  final layer = view.debugLayer;
  expect(layer, isA<OffsetLayer>());
  final ratio = view.flutterView.devicePixelRatio;
  final image = await (layer as OffsetLayer).toImage(
    Offset.zero & Size(view.size.width * ratio, view.size.height * ratio),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  expect(bytes, isNotNull);
  await File(
    '/tmp/renewal-generation-source-rejected.png',
  ).writeAsBytes(bytes!.buffer.asUint8List());
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native Build rejects changed and ABA sources without creating a job',
    (tester) async {
      final root = await AppPaths.repertoiresDirectory();
      final folder = await Directory(
        p.join(root.path, 'Admission ${DateTime.now().microsecondsSinceEpoch}'),
      ).create(recursive: true);
      addTearDown(() => folder.delete(recursive: true));
      final source = File(p.join(folder.path, 'Original.pgn'));
      final other = File(p.join(folder.path, 'Other.pgn'));
      const originalPgn =
          '// Color: White\n\n[Event "Original line"]\n[Result "*"]\n\n'
          '1. e4 e5 2. Nf3 Nc6 *\n';
      const otherPgn =
          '// Color: White\n\n[Event "Other line"]\n[Result "*"]\n\n'
          '1. d4 d5 2. c4 e6 *\n';
      await source.writeAsString(originalPgn);
      await other.writeAsString(otherPgn);
      await pumpApp(tester);
      getAppState(tester).switchToBuilder(repertoirePath: source.path);
      await _ready(tester, find.text('Original line'));
      final document = tester
          .element(find.byType(RepertoireScreen))
          .read<BuilderLifetime>()
          .workspace
          .document;
      final original = document.currentRepertoire!;

      await tester.tap(find.text('Actions'));
      await _ready(tester, find.text('Generate from here…').hitTestable());
      await tester.tap(find.text('Generate from here…'));
      final actions = find.byKey(const ValueKey('generation-actions'));
      await _ready(tester, actions.hitTestable());
      await tester.tap(actions);
      final build = find.byKey(const ValueKey('build-chessdb-repertoire'));
      await _ready(tester, build.hitTestable());
      await tester.tap(build);
      final start = find.text('Generate Repertoire').hitTestable();
      await _ready(tester, start);
      final label = AppLocalizations.of(
        tester.element(find.byType(RepertoireGenerationTab)),
      ).generationSourceChanged;
      final jobsBefore = JobManager.instance.jobs;

      // This is the real document transition a delayed chapter-creation
      // completion can make behind configuration. Controlled widget tests
      // separately exercise the delayed catalog callback itself.
      for (final target in [
        RepertoireMetadata(
          filePath: other.path,
          name: 'Other',
          lastModified: DateTime.now(),
        ),
        original,
      ]) {
        await document.setRepertoire(target);
        await tester.pump(const Duration(milliseconds: 300));
        expect(document.currentRepertoire?.filePath, target.filePath);
        expect(document.isLoading, isFalse);
        final configuration = tester.widget<RepertoireGenerationTab>(
          find.byType(RepertoireGenerationTab),
        );
        expect(configuration.currentRepertoire?.filePath, source.path);
        await tester.tap(start);
        await _ready(tester, find.text(label));
        expect(configuration.generationController.isGenerating, isFalse);
        expect(JobManager.instance.jobs, jobsBefore);
        expect(await source.readAsString(), originalPgn);
        expect(await other.readAsString(), otherPgn);
        if (target.filePath == other.path) await _captureRejection();
        // Dismiss the first message so the ABA assertion requires a new one.
        ScaffoldMessenger.of(
          tester.element(find.byType(RepertoireGenerationTab)),
        ).removeCurrentSnackBar();
        await tester.pump(const Duration(milliseconds: 300));
      }
      await tester.tap(find.byTooltip('Close'));
      await _ready(tester, actions.hitTestable());
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
