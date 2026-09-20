import 'package:chess_auto_prep/v2/features/library/library.dart';
import 'package:chess_auto_prep/v2/features/library/library_panel.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_files.dart';

void main() {
  late ScriptedFiles files;
  late Library library;
  final opened = <ChapterRef>[];

  setUp(() {
    files = ScriptedFiles();
    library = Library(files);
    opened.clear();
  });

  tearDown(() => library.dispose());

  Future<void> pump(WidgetTester tester, {ChapterRef? selected}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: LibraryPanel(
            library: library,
            selected: selected,
            onOpen: opened.add,
          ),
        ),
      ),
    );
  }

  Future<void> ready(WidgetTester tester, ChapterListing listing) async {
    files.listing = listing;
    final done = library.refresh();
    files.releaseNext();
    await done;
    await tester.pump();
  }

  testWidgets('groups chapters under their repertoire and opens on tap', (
    tester,
  ) async {
    await pump(tester, selected: ref('KID', 'Main'));
    await ready(
      tester,
      Chapters([ref('benko', 'Main'), ref('KID', 'aux'), ref('KID', 'Main')]),
    );
    expect(find.text('benko'), findsOneWidget);
    expect(find.text('KID'), findsOneWidget);
    expect(find.text('Main'), findsNWidgets(2));
    await tester.tap(find.text('aux'));
    expect(opened, [ref('KID', 'aux')]);
    final tiles = tester.widgetList<ListTile>(find.byType(ListTile));
    expect(tiles.where((t) => t.selected).length, 1);
  });

  testWidgets('says when there is nothing, and when it could not look', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await ready(tester, const Chapters([]));
    expect(
      find.text('No repertoires in Documents/repertoires'),
      findsOneWidget,
    );
    await ready(tester, const ChaptersUnreadable('Permission denied'));
    expect(find.textContaining('Permission denied'), findsOneWidget);
  });
}
