import 'dart:io';
import 'package:chess_auto_prep/widgets/repertoire_lines_browser.dart';
import 'package:chess_auto_prep/widgets/lines/line_item_row.dart';
import 'dart:ui' as ui;
import 'package:chess_auto_prep/widgets/layout/bottom_pane.dart';
import 'package:chess_auto_prep/widgets/layout/jobs_panel.dart';
import 'package:chess_auto_prep/widgets/generation/snapshot_export_dialog.dart';
import 'package:flutter/rendering.dart';
import 'package:chess_auto_prep/features/repertoire/widgets/repertoire_board_pane.dart';
import 'package:chess_auto_prep/features/repertoire/widgets/repertoire_outline_controls.dart';
import 'package:chess_auto_prep/chess_core/moves/move_tree_snapshot.dart';
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/widgets/interactive_pgn_editor.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_annotation_panel.dart';
import 'package:chess_auto_prep/app/builder_lifetime.dart';
import 'package:provider/provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'helpers/board_helpers.dart';
import 'helpers/tactics_helpers.dart';

Future<void> ready(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 120 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsWidgets);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> captureLayout(String name) async {
  final view = RendererBinding.instance.renderViews.first;
  final ratio = view.flutterView.devicePixelRatio;
  final image = await (view.debugLayer! as OffsetLayer).toImage(
    Offset.zero & Size(view.size.width * ratio, view.size.height * ratio),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  await File(
    '/tmp/renewal-builder-$name.png',
  ).writeAsBytes(bytes!.buffer.asUint8List());
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Builder immutable annotations save, survive mode changes and reload',
    (tester) async {
      final root = await AppPaths.repertoiresDirectory();
      final folder = await Directory(
        p.join(
          root.path,
          'Builder projection ${DateTime.now().microsecondsSinceEpoch}',
        ),
      ).create(recursive: true);
      addTearDown(() => folder.delete(recursive: true));
      final file = File(p.join(folder.path, 'Main.pgn'));
      await file.writeAsString(
        '// Color: White\n\n[Event "Projection line"]\n[Result "*"]\n\n1. e4 e5 (1... c5) 2. Nf3 *',
      );
      await pumpApp(tester);
      final app = getAppState(tester);
      app.switchToBuilder(repertoirePath: file.path);
      await ready(tester, find.text('Projection line'));
      await tester.tap(find.text('Projection line').first);
      await ready(tester, find.byType(InteractivePgnEditor));
      final owner = tester
          .element(find.byType(InteractivePgnEditor))
          .read<BuilderLifetime>()
          .workspace;
      final before = owner.board.tree;
      final cursor = owner.board.path;
      expect(before, isA<MoveTreeSnapshot>());
      expect(cursor.isNotEmpty, isTrue);
      expect(PgnAnnotationPanel.focusActive(), isTrue);
      await tester.pump();
      await tester.pump();
      final field = find.descendant(
        of: find.byType(PgnAnnotationPanel),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, 'Keep this');
      await tester.pump();
      final input = find.descendant(
        of: field,
        matching: find.byType(EditableText),
      );
      final fieldState = tester.state(input);
      await tester.enterText(field, 'Keep this annotation');
      await tester.pump();
      expect(tester.state(input), same(fieldState));
      expect(tester.widget<EditableText>(input).focusNode.hasFocus, isTrue);
      expect(before.commentAt(cursor), isNull);
      expect(owner.board.tree.commentAt(cursor), 'Keep this annotation');
      await tester.tap(find.byTooltip('Good move'));
      await tester.pump();
      expect(owner.board.tree.nodeAt(cursor)!.nags, [1]);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await owner.document.flushDocumentForClose();
      final saved = await file.readAsString();
      expect(saved, contains('Keep this annotation'));
      expect(saved, contains('\$1'));
      expect(saved, contains('c5'));
      final annotated = owner.board.tree;
      app.setMode(AppMode.tactics);
      await tester.pump();
      app.setMode(AppMode.repertoire);
      await ready(tester, find.byType(InteractivePgnEditor));
      expect(owner.board.tree, same(annotated));
      expect(owner.board.path, cursor);
      await owner.document.loadRepertoire();
      await ready(tester, find.text('Projection line'));
      await tester.tap(find.text('Projection line').first);
      await tester.pump(const Duration(milliseconds: 300));
      expect(owner.board.tree.commentAt(cursor), 'Keep this annotation');
      expect(owner.board.tree.nodeAt(cursor)!.nags, [1]);
      expect(owner.board.tree.identity, isNot(same(annotated.identity)));
      final retainedTree = owner.board.tree;
      final retainedPath = owner.board.path;
      final preview = tester
          .widget<RepertoireBoardPane>(find.byType(RepertoireBoardPane))
          .boardPreview;
      await tester.tap(find.byTooltip('Hide chapters'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(RepertoireOutlineStrip), findsOneWidget);
      await tester.tap(find.byType(RepertoireOutlineStrip));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byTooltip('Hide chapters'), findsOneWidget);
      await tester.drag(
        find.byType(RepertoireOutlineResizeHandle),
        const Offset(50, 0),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('Hide analysis panel'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byTooltip('Show analysis panel'), findsOneWidget);
      await tester.tap(find.byTooltip('Show analysis panel'));
      await tester.pump(const Duration(milliseconds: 300));
      await captureLayout('wide-layout');
      await tester.tap(find.byTooltip('Chapter options'));
      await ready(tester, find.text('Line metrics').hitTestable());
      await tester.tap(find.text('Line metrics').hitTestable());
      final browser = find.byType(RepertoireLinesBrowser);
      await ready(tester, browser);
      final rows = find.descendant(
        of: browser,
        matching: find.byType(LineItemRow),
      );
      expect(rows, findsOneWidget);
      final search = find.descendant(
        of: browser,
        matching: find.byType(TextField),
      );
      await tester.enterText(search, 'no matching line');
      await tester.pump(const Duration(milliseconds: 400));
      expect(rows, findsNothing);
      expect(find.text('No lines match the current filters'), findsOneWidget);
      await tester.tap(find.text('Show all lines'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(rows, findsOneWidget);
      expect(tester.widget<TextField>(search).controller!.text, isEmpty);
      await captureLayout('line-metrics');
      await tester.tap(find.byTooltip('Back to chapters'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(owner.board.tree, same(retainedTree));
      expect(owner.board.path, retainedPath);

      // Idle jobs have no status badge. Open the existing panel owner as a
      // native fixture; actual running-job button actions are widget-tested.
      tester
          .widget<BottomPane>(find.byType(BottomPane))
          .controller
          .open(BottomPaneTab.jobs);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(JobsPanel), findsOneWidget);
      expect(find.text('No active jobs'), findsOneWidget);
      final export = showSnapshotExportDialog(
        tester.element(find.byType(JobsPanel)),
        suggestedName: 'Native snapshot',
        canVerify: true,
        verifyDepth: 18,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField).last, 'Kept until close');
      await tester.pump();
      await captureLayout('snapshot-dialog');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
      await tester.pump(const Duration(milliseconds: 400));
      expect(await export, isNull);
      expect(tester.takeException(), isNull);
      tester.widget<BottomPane>(find.byType(BottomPane)).controller.close();
      await tester.pump(const Duration(milliseconds: 300));
      tester.view.physicalSize = const Size(900, 1000);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('PGN'), findsOneWidget);
      expect(find.byType(RepertoireOutlineResizeHandle), findsNothing);
      expect(owner.board.tree, same(retainedTree));
      expect(owner.board.path, retainedPath);
      expect(
        tester
            .widget<RepertoireBoardPane>(find.byType(RepertoireBoardPane))
            .boardPreview,
        same(preview),
      );
      await captureLayout('compact-layout');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
