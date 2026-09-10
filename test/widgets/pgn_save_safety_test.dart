import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/models/pgn_deletion_summary.dart';
import 'package:chess_auto_prep/widgets/interactive_pgn_editor.dart';
import 'package:chess_auto_prep/widgets/pgn/comment_editor.dart';
import 'package:chess_auto_prep/widgets/pgn/movetext_primitives.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_annotation_panel.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_save_status.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('counts nested branches, starting prose and chapter introductions', () {
    final tree = MoveTree.fromPgn(
      '{Intro} 1. e4 {Main} (1. d4 {Side} d5 (1... Nf6 {Nested})) e5 *',
    );
    tree.roots[1].startingComment = 'Before the variation';
    tree.roots[0].children[0].comment = '[%eval 0.2] [%cal Ge2e4]';
    final all = PgnDeletionSummary.tree(tree);
    expect(all.moves, 5);
    expect(all.comments, 5);
    final variations = PgnDeletionSummary.variations(tree);
    expect(variations.moves, 3);
    expect(variations.comments, 3);
  });

  for (final stale in [false, true]) {
    testWidgets(
      'branch deletion confirms counts, cancels safely; stale=$stale',
      (tester) async {
        final tree = MoveTree.fromPgn('1. e4 e5 (1... c5 {Sicilian} 2. Nf3) *');
        var deletions = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: InteractivePgnEditor(
                tree: tree,
                currentPath: TreePath.empty,
                onDelete: (path) {
                  deletions++;
                  tree.deleteAt(path);
                },
              ),
            ),
          ),
        );
        Future<void> request() async {
          await tester.tap(
            find.byWidgetPredicate((w) => w is MoveChip && w.san == 'e4'),
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Delete from Here'));
          await tester.pumpAndSettle();
        }

        await request();
        expect(find.text('Delete 4 moves and 1 comment?'), findsOneWidget);
        expect(deletions, 0);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(tree.roots, hasLength(1));
        expect(deletions, 0);
        await request();
        if (stale) {
          tree.setComment(const TreePath([0]), 'Added while dialog open');
        }
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        expect(deletions, stale ? 0 : 1);
        expect(tree.isEmpty, !stale);
      },
    );
  }

  testWidgets('single uncommented move also requires confirmation', (
    tester,
  ) async {
    final tree = MoveTree.fromMoves(['e4']);
    var deleted = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractivePgnEditor(
            tree: tree,
            currentPath: TreePath.empty,
            onDelete: (_) => deleted = true,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(MoveChip), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete from Here'));
    await tester.pumpAndSettle();
    expect(find.text('Delete 1 move and 0 comments?'), findsOneWidget);
    expect(deleted, isFalse);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  for (final delay in [Duration.zero, const Duration(milliseconds: 400)]) {
    testWidgets(
      'blank comment drafts are kept until explicit deletion ($delay)',
      (tester) async {
        var saved = 'Keep my note';
        final edits = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => PgnAnnotationPanel(
                  targetKey: 'e4',
                  moveLabel: '1. e4',
                  nags: const [],
                  comment: saved,
                  commentDebounce: delay,
                  onToggleNag: (_) {},
                  onCommentChanged: (text) {
                    edits.add(text);
                    setState(() => saved = text);
                  },
                ),
              ),
            ),
          ),
        );
        await tester.enterText(find.byType(TextField), '');
        await tester.pump(const Duration(seconds: 1));
        expect(saved, 'Keep my note');
        expect(find.byType(AlertDialog), findsNothing);
        await tester.enterText(find.byType(TextField), 'Replacement');
        await tester.pump(const Duration(seconds: 1));
        expect(saved, 'Replacement');
        expect(find.byType(AlertDialog), findsNothing);
        await tester.enterText(find.byType(TextField), '');
        await tester.tap(find.byTooltip('Delete comment'));
        await tester.pumpAndSettle();
        expect(find.text('Delete 1 comment?'), findsOneWidget);
        expect(saved, 'Replacement');
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(saved, 'Replacement');
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'Replacement',
        );
        await tester.tap(find.byTooltip('Delete comment'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        expect(saved, '');
        expect(edits.where((e) => e.isEmpty), hasLength(1));
      },
    );
  }

  testWidgets('deleting a comment flushes pending text before confirmation', (
    tester,
  ) async {
    var saved = 'Original';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => PgnAnnotationPanel(
              targetKey: 'e4',
              moveLabel: '1. e4',
              nags: const [],
              comment: saved,
              onToggleNag: (_) {},
              onCommentChanged: (text) => setState(() => saved = text),
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'Just typed');
    await tester.tap(find.byTooltip('Delete comment'));
    await tester.pumpAndSettle();
    expect(saved, 'Just typed');
    expect(find.text('Delete 1 comment?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(saved, '');
  });

  testWidgets('blank draft never flushes on panel disposal', (tester) async {
    final edits = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PgnAnnotationPanel(
            targetKey: 'e4',
            moveLabel: '1. e4',
            nags: const [],
            comment: 'Keep',
            onToggleNag: (_) {},
            onCommentChanged: edits.add,
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpWidget(const SizedBox());
    expect(edits, isEmpty);
  });

  testWidgets('empty inline save asks before invoking host', (tester) async {
    String? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PgnCommentEditor(
            initialText: 'Keep',
            onSave: (text) => saved = text,
            onCancel: () {},
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.byTooltip('Save comment'));
    await tester.pumpAndSettle();
    expect(saved, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(saved, isNull);
    await tester.tap(find.byTooltip('Save comment'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(saved, '');
  });

  testWidgets('save feedback has stable size and truthful states', (
    tester,
  ) async {
    Future<Size> status({
      String? path = '/fixture.pgn',
      bool auto = true,
      bool dirty = false,
      bool saving = false,
      String? error,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: PgnSaveStatus(
                filePath: path,
                autoSave: auto,
                dirty: dirty,
                saving: saving,
                error: error,
              ),
            ),
          ),
        ),
      );
      return tester.getSize(find.byType(PgnSaveStatus));
    }

    final idleSize = await status();
    expect(find.text('Autosave on · Saved'), findsOneWidget);
    expect(await status(dirty: true), idleSize);
    expect(find.text('Saving…'), findsOneWidget);
    expect(await status(dirty: true, error: 'Disk full'), idleSize);
    expect(find.text('Not saved'), findsOneWidget);
    expect(find.byTooltip('Disk full'), findsOneWidget);
    await status(auto: false, dirty: true);
    expect(find.text('Unsaved changes'), findsOneWidget);
    await status(auto: false);
    expect(find.text('Autosave off · Saved'), findsOneWidget);
    await status(path: null);
    expect(find.text('Not saved to a file'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
