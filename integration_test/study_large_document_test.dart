import 'dart:io';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:chess_auto_prep/features/studies/controllers/study_controller.dart';
import 'package:chess_auto_prep/screens/study_screen.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/widgets/interactive_pgn_editor.dart';
import 'package:chess_auto_prep/widgets/pgn/movetext_primitives.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'helpers/tactics_helpers.dart';

String _line(int branch, {int start = 0}) {
  final text = StringBuffer();
  const moves = ['Nf3', 'Nf6', 'Ng1', 'Ng8'];
  for (var ply = start; ply < 200; ply++) {
    if (ply.isEven || ply == start) {
      text.write('${ply ~/ 2 + 1}${ply.isEven ? '.' : '...'} ');
    }
    text.write(
      '${moves[ply % 4]} {Branch $branch move $ply. A wrapped course annotation with some explanatory prose.} ',
    );
  }
  return text.toString();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native 20000-node study opens, navigates, edits and saves', (
    tester,
  ) async {
    await pumpApp(tester);
    await switchToMode(tester, 'Study');
    final study = tester
        .element(find.byType(StudyScreen))
        .read<StudyController>();
    final directory = await Directory(
      '${(await AppPaths.supportDirectory()).path}/large-study-${DateTime.now().microsecondsSinceEpoch}',
    ).create();
    final file = File('${directory.path}/Course.pgn');
    final pgn = StringBuffer(
      '[Event "Large course"]\n\n1. Nf3 {Branch 0 move 0.} ',
    );
    for (var branch = 1; branch < 100; branch++) {
      pgn.write('(${_line(branch)}) ');
    }
    pgn.write('${_line(0, start: 1)} *');
    await file.writeAsString(pgn.toString());
    final watch = Stopwatch()..start();
    await study.openStudy(file.path);
    await tester.pumpAndSettle();
    final openedMillis = watch.elapsedMilliseconds;
    expect(study.tree.roots.length, 100);
    expect(find.byType(MoveChip).evaluate().length, lessThan(100));
    final target = TreePath.from([99, ...List.filled(199, 0)]);
    watch.reset();
    study.jump(target);
    await tester.pumpAndSettle();
    final jumpedMillis = watch.elapsedMilliseconds;
    expect(
      find.textContaining('Branch 99 move 199.').hitTestable(),
      findsWidgets,
    );
    expect(find.byType(MoveChip).evaluate().length, lessThan(100));
    final field = find.descendant(
      of: find.byType(InteractivePgnEditor),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, 'Edited distant course annotation');
    await tester.pumpAndSettle();
    expect(study.cursorComment, 'Edited distant course annotation');
    await tester.tap(find.byKey(const ValueKey('study-save-recovery')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('document-save')));
    for (var i = 0; i < 100 && study.dirty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(study.dirty, isFalse);
    final saved = await file.readAsString();
    expect(saved, contains('Edited distant course annotation'));
    expect(saved, contains('Branch 98 move 199.'));
    expect(saved, isNot(contains('Branch 99 move 199.')));
    // Includes native store read, worker decoding, adoption, projections and UI.
    // Debug diagnostic, not a profile-mode frame budget assertion.
    // ignore: avoid_print
    print(
      'native 20000-node course: open $openedMillis ms; distant jump $jumpedMillis ms; RSS ${ProcessInfo.currentRss} bytes',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
