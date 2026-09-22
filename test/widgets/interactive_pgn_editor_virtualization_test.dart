import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/widgets/interactive_pgn_editor.dart';
import 'package:chess_auto_prep/widgets/pgn/movetext_primitives.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

MoveTree course(int count) {
  final tree = MoveTree();
  for (var i = 0; i < count; i++) {
    tree.roots.add(
      MoveNode(
        san: 'Move$i',
        fen: kStandardStartFen,
        comment:
            'Note $i. ${'Wrapped prose with enough words to span several lines. ' * 4}',
      ),
    );
  }
  return tree;
}

void main() {
  testWidgets(
    '20000 nodes mount a bounded window and distant jumps remain navigable',
    (tester) async {
      final tree = course(20000);
      TreePath? jumped;
      Widget host(TreePath path) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,

        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: InteractivePgnEditor(
              tree: tree,
              currentPath: path,
              onJump: (p) => jumped = p,
            ),
          ),
        ),
      );
      await tester.pumpWidget(host(const TreePath([0])));
      expect(find.byType(MoveChip).evaluate().length, lessThan(30));
      expect(find.textContaining('Note 19999.'), findsNothing);
      await tester.pumpWidget(host(const TreePath([19999])));
      await tester.pumpAndSettle();
      final last = find.byWidgetPredicate(
        (w) => w is MoveChip && w.san == 'Move19999',
      );
      expect(last.hitTestable(), findsOneWidget);
      expect(find.byType(MoveChip).evaluate().length, lessThan(30));
      await tester.tap(last);
      expect(jumped, const TreePath([19999]));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 450));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate((w) => w is MoveChip && w.san == 'Move19998'),
        findsOneWidget,
      );
      await tester.pumpWidget(host(const TreePath([0])));
      await tester.pumpAndSettle();
      expect(
        find
            .byWidgetPredicate((w) => w is MoveChip && w.san == 'Move0')
            .hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('wrapped rows at 200 percent remain complete and selectable', (
    tester,
  ) async {
    final tree = course(30);
    TreePath? jumped;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,

        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SizedBox(
              width: 320,
              child: InteractivePgnEditor(
                tree: tree,
                currentPath: const TreePath([20]),
                onJump: (p) => jumped = p,
              ),
            ),
          ),
        ),
      ),
    );
    final move = find.byWidgetPredicate(
      (w) => w is MoveChip && w.san == 'Move20',
    );
    await tester.tap(move);
    expect(jumped, const TreePath([20]));
    final comment = tester.widget<Text>(
      find.byWidgetPredicate(
        (w) =>
            w is Text &&
            (w.textSpan?.toPlainText().startsWith('Note 20.') ?? false),
      ),
    );
    expect(comment.maxLines, isNull);
    expect(comment.textSpan!.toPlainText(), contains('several lines.'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a selected move inside a tall wrapped run scrolls into view', (
    tester,
  ) async {
    final tree = MoveTree();
    var children = tree.roots;
    for (var i = 0; i < 48; i++) {
      final node = MoveNode(san: 'Move$i', fen: kStandardStartFen);
      children.add(node);
      children = node.children;
    }
    Widget host(int ply) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,

      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: Scaffold(
          body: SizedBox(
            width: 150,
            height: 300,
            child: InteractivePgnEditor(
              tree: tree,
              currentPath: TreePath.from(List.filled(ply, 0)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(host(24));
    await tester.pumpAndSettle();
    expect(
      find
          .byWidgetPredicate((w) => w is MoveChip && w.san == 'Move23')
          .hitTestable(),
      findsOneWidget,
    );
    await tester.pumpWidget(host(45));
    await tester.pumpAndSettle();
    expect(
      find
          .byWidgetPredicate((w) => w is MoveChip && w.san == 'Move44')
          .hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('inline draft survives eviction and distant cursor navigation', (
    tester,
  ) async {
    final tree = course(200);
    var path = const TreePath([0]);
    Widget host() => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,

      home: Scaffold(
        body: SizedBox(
          width: 400,
          child: InteractivePgnEditor(
            tree: tree,
            currentPath: path,
            onCommentChanged: (p, text) => tree.setComment(p, text),
          ),
        ),
      ),
    );
    await tester.pumpWidget(host());
    await tester.tap(
      find.byWidgetPredicate((w) => w is MoveChip && w.san == 'Move0'),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit Comment'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Uncommitted draft');
    path = const TreePath([199]);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    path = const TreePath([0]);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Uncommitted draft',
    );
    await tester.tap(find.byTooltip('Save comment'));
    await tester.pumpAndSettle();
    expect(tree.commentAt(path), 'Uncommitted draft');
    expect(tester.takeException(), isNull);
  });
}
