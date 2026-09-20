import 'package:chess_auto_prep/v2/app/shell.dart';
import 'package:chess_auto_prep/v2/features/library/library.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/scripted_files.dart';

void main() {
  final kid = ref('KID', 'Main');
  final benko = ref('benko', 'Main');
  late ScriptedFiles files;
  late Library library;
  late DocumentSession session;

  setUp(() {
    files = ScriptedFiles(
      listing: Chapters([benko, kid]),
      texts: {
        kid.path: const ChapterText(blackChapter),
        benko.path: const ChapterText('// Color: White\n'),
      },
    );
    library = Library(files);
    session = DocumentSession();
  });

  tearDown(() {
    library.dispose();
    session.dispose();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Shell(library: library, session: session),
      ),
    );
    final listing = library.refresh();
    files.releaseNext();
    await listing;
    await tester.pump();
  }

  testWidgets('opening a chapter puts it in the workspace', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Main').last);
    files.releaseNext();
    await tester.pump();
    expect(session.source, kid);
    expect(session.chapter?.gameCount, 2);
    expect(find.textContaining('Black · 2 lines'), findsOneWidget);
  });

  testWidgets('the later of two clicks wins, whichever read finishes first', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Main').last); // KID
    await tester.tap(find.text('Main').first); // benko
    expect(files.pendingCalls, 2);
    files.releaseAll(); // KID's read answers before benko's
    await tester.pump();
    expect(session.source, benko);
    // The stale KID answer must not have replaced benko.
    await tester.pump();
    expect(session.source, benko);
  });

  testWidgets('a chapter that vanished is reported, not opened', (
    tester,
  ) async {
    await pump(tester);
    files.texts = {};
    await tester.tap(find.text('Main').last);
    files.releaseNext();
    await tester.pump();
    expect(session.chapter, isNull);
    expect(find.text('Main is no longer on disk'), findsOneWidget);
  });
}
