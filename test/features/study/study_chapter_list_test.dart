import 'package:chess_auto_prep/chess/pgn/study.dart';
import 'package:chess_auto_prep/features/study/study_chapter_list.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the open chapter is scrolled into view with the system text '
      'size larger', (tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    void nothing() {}
    final chapters = [
      for (var i = 0; i < 64; i++)
        StudyChapter(index: i, name: 'Chapter $i', orientation: Side.white),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        builder: (context, app) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.5)),
          child: app!,
        ),
        home: Scaffold(
          body: StudyChapterList(
            chapters: chapters,
            active: 60,
            busy: false,
            onOpen: (_) {},
            actionsFor: (_) => (
              rename: nothing,
              tags: nothing,
              root: nothing,
              clearAnnotations: nothing,
              clearVariations: nothing,
              face: (_) {},
              move: (_) {},
              copyPgn: nothing,
              remove: nothing,
              moveTo: nothing,
            ),
            onReorder: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final list = tester.getRect(find.byType(Scrollable).last);
    final row = tester.getRect(find.textContaining('Chapter 60'));
    expect(row.top, greaterThanOrEqualTo(list.top));
    expect(row.bottom, lessThanOrEqualTo(list.bottom));
  });
}
