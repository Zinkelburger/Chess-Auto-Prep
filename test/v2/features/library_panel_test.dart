import 'package:chess_auto_prep/v2/features/library/library_panel.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import '../support/scripted_files.dart';
import '../support/scripted_store.dart';
import '../support/status_host.dart';

void main() {
  final kid = folder('KID', [
    'Classical',
    'Main',
  ], modified: DateTime.now().subtract(const Duration(hours: 4)));
  final benko = folder('benko', ['Main']);
  late LibraryFixture fixture;
  final opened = <ChapterRef>[];

  setUp(opened.clear);
  tearDown(() => fixture.dispose());

  Future<void> show(
    WidgetTester tester,
    List<RepertoireFolder> folders, {
    ChapterRef? selected,
  }) async {
    fixture = await openLibrary(folders);
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: StatusHost(
            child: LibraryPanel(
              library: fixture.library,
              selected: selected,
              onOpen: opened.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a repertoire shows its chapter count and when it changed', (
    tester,
  ) async {
    await show(tester, [kid]);
    expect(find.text('KID'), findsOneWidget);
    expect(find.text('2 chapters · Modified 4h ago'), findsOneWidget);
  });

  testWidgets('one chapter is not "1 chapters"', (tester) async {
    await show(tester, [benko]);
    expect(find.textContaining('1 chapter · Modified'), findsOneWidget);
  });

  testWidgets('a repertoire opens to its chapters, and one can be opened', (
    tester,
  ) async {
    await show(tester, [kid]);
    expect(find.text('Classical'), findsNothing);
    await tester.tap(find.text('KID'));
    await tester.pumpAndSettle();
    expect(find.text('Classical'), findsOneWidget);
    await tester.tap(find.text('Classical'));
    expect(opened.single.name, 'Classical');
  });

  testWidgets('search filters the rows and says when nothing matches', (
    tester,
  ) async {
    await show(tester, [benko, kid]);
    await tester.enterText(find.byType(TextField), 'ki');
    await tester.pumpAndSettle();
    expect(find.text('benko'), findsNothing);
    expect(find.text('KID'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('Nothing matches "zzz".'), findsOneWidget);
  });

  testWidgets('an empty library says how to start', (tester) async {
    await show(tester, []);
    expect(
      find.text('No repertoires yet\nCreate a repertoire to get started.'),
      findsOneWidget,
    );
  });

  testWidgets('a folder that cannot be read offers Retry', (tester) async {
    await show(tester, []);
    fixture.files.listing = const RepertoiresUnreadable('Permission denied');
    await fixture.library.refresh();
    await tester.pumpAndSettle();
    expect(
      find.text('Could not load repertoires. Please try again.'),
      findsOneWidget,
    );
    fixture.files.listing = Repertoires([kid]);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('KID'), findsOneWidget);
  });

  testWidgets('a repertoire that cannot be read is named, not dropped', (
    tester,
  ) async {
    await show(tester, [kid]);
    fixture.files.listing = Repertoires(
      [kid],
      unreadable: const [
        UnreadableFolder(
          name: 'Benko',
          path: '/repertoires/Benko',
          detail: 'Permission denied',
        ),
      ],
    );
    await fixture.library.refresh();
    await tester.pumpAndSettle();
    expect(find.text('KID'), findsOneWidget);
    expect(
      find.text('Benko could not be read: Permission denied'),
      findsOneWidget,
    );
  });

  testWidgets('a new repertoire asks for a name only, and opens', (
    tester,
  ) async {
    await show(tester, []);
    await tester.tap(find.byTooltip('New repertoire'));
    await tester.pumpAndSettle();
    expect(find.text('Playing side'), findsNothing);
    await tester.enterText(find.byType(TextField).last, 'Benoni');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    final text = fixture.textAt('/repertoires/Benoni/Main.pgn');
    expect(text, startsWith('// Benoni\n'));
    expect(text, isNot(contains('// Color:')), reason: 'asked on open');
    expect(opened.single.path, '/repertoires/Benoni/Main.pgn');
  });

  testWidgets('a name the filesystem would refuse never leaves the dialog', (
    tester,
  ) async {
    await show(tester, []);
    await tester.tap(find.byTooltip('New repertoire'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'a/b');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        r'Names cannot contain < > : " / \ | ? * or control characters.',
      ),
      findsOneWidget,
    );
    expect(fixture.store.documents, isEmpty);
  });

  testWidgets('renaming a chapter goes through the library', (tester) async {
    await show(tester, [benko]);
    await tester.tap(find.text('benko'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_horiz).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Mainline');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(fixture.textAt('/repertoires/benko/Mainline.pgn'), isNotNull);
  });

  testWidgets('deleting a repertoire is confirmed first', (tester) async {
    await show(tester, [benko]);
    await tester.tap(find.byIcon(Icons.more_horiz).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete…'));
    await tester.pumpAndSettle();
    expect(find.text('Delete repertoire "benko"?'), findsOneWidget);
    expect(
      find.text(
        'Its chapters can be restored from Deleted chapters under this '
        'list.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(fixture.store.documents, isNotEmpty);
    await tester.tap(find.byIcon(Icons.more_horiz).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(fixture.store.documents, isEmpty);
  });

  /// Opens the Move-to dialog on the chapter row at [row], counting the
  /// repertoire rows and chapter rows on screen from the top.
  Future<void> openMoveDialog(WidgetTester tester, int row) async {
    await tester.tap(find.byIcon(Icons.more_horiz).at(row));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to…'));
    await tester.pumpAndSettle();
  }

  testWidgets('a name already taken is said in a sentence', (tester) async {
    await show(tester, [benko, kid]);
    await tester.tap(find.text('benko'));
    await tester.pumpAndSettle();
    // benko's row, then its one chapter, then KID's row.
    await openMoveDialog(tester, 1);
    await tester.tap(find.widgetWithText(ListTile, 'KID'));
    await tester.pumpAndSettle();
    expect(find.text('A chapter named "Main" already exists.'), findsOneWidget);
  });

  testWidgets('a chapter moves into the repertoire chosen from the list', (
    tester,
  ) async {
    await show(tester, [benko, kid]);
    await tester.tap(find.text('KID'));
    await tester.pumpAndSettle();
    // KID's row, then Classical, then Main.
    await openMoveDialog(tester, 2);
    await tester.tap(find.widgetWithText(ListTile, 'benko'));
    await tester.pumpAndSettle();
    expect(fixture.textAt('/repertoires/benko/Classical.pgn'), isNotNull);
  });

  testWidgets('with nowhere to move it to, the list says so', (tester) async {
    await show(tester, [benko]);
    await tester.tap(find.text('benko'));
    await tester.pumpAndSettle();
    await openMoveDialog(tester, 1);
    expect(
      find.text('There is no other repertoire to move it to.'),
      findsOneWidget,
    );
  });

  testWidgets('the move list is searchable and enter takes the one match', (
    tester,
  ) async {
    final sidelines = folder('Sidelines', ['Odds']);
    await show(tester, [benko, kid, sidelines]);
    await tester.tap(find.text('KID'));
    await tester.pumpAndSettle();
    // KID's row, then Classical, then Main; benko and Sidelines are above it.
    await openMoveDialog(tester, 2);
    expect(
      find.widgetWithText(ListTile, 'KID'),
      findsNothing,
      reason: 'the chapter is already in KID',
    );
    await tester.enterText(find.byType(TextField).last, 'side');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'benko'), findsNothing);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(fixture.textAt('/repertoires/Sidelines/Classical.pgn'), isNotNull);
  });

  testWidgets('a course chapter’s delete does not promise a restore', (
    tester,
  ) async {
    final course = RepertoireFolder(
      name: 'Course',
      path: '/repertoires/Course',
      modified: DateTime.now(),
      chapters: [
        ChapterRef.at('/repertoires/Course/Main.pgn', section: 'Open'),
        ChapterRef.at('/repertoires/Course/Main.pgn', section: 'Closed'),
      ],
    );
    await show(tester, [course]);
    await tester.tap(find.text('Course'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_horiz).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('course file they share'), findsOneWidget);
    expect(find.textContaining('Deleted chapters under'), findsNothing);
  });

  const trashed = '/repertoires/KID/.cap-pgn-history/1-a-Main.pgn';
  final main = DeletedChapter(
    path: trashed,
    folder: '/repertoires/KID',
    name: 'Main',
    deletedAt: DateTime.now().subtract(const Duration(days: 2)),
  );

  Future<void> showDeleted(WidgetTester tester, {bool taken = false}) async {
    await show(tester, [
      folder('KID', taken ? ['Main'] : ['Classical']),
    ]);
    fixture.files.deletedListing = DeletedChapters([main]);
    fixture.store.documents[const DocumentRef(trashed)] = Opened(
      '// Main\n',
      scriptedRevision('// Main\n'),
    );
    await tester.tap(find.text('Deleted chapters'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'deleted chapters are listed with where they came from and when',
    (tester) async {
      await showDeleted(tester);
      expect(find.text('Main'), findsOneWidget);
      expect(find.text('KID'), findsOneWidget);
      expect(find.text('2d ago'), findsOneWidget);
      await tester.tap(find.byTooltip('Back to repertoires'));
      await tester.pumpAndSettle();
      expect(find.text('KID'), findsOneWidget);
    },
  );

  testWidgets('deleted chapters come back where they were', (tester) async {
    await showDeleted(tester);
    fixture.files.deletedListing = const DeletedChapters([]);
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(fixture.textAt('/repertoires/KID/Main.pgn'), '// Main\n');
    expect(fixture.textAt(trashed), isNull);
    expect(find.textContaining('Nothing deleted'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets(
    'a deleted chapter asks for another name rather than replace a chapter',
    (tester) async {
      await showDeleted(tester, taken: true);
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(find.text('"Main" is already in KID'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
      await tester.pumpAndSettle();
      expect(
        fixture.textAt('/repertoires/KID/Main (restored).pgn'),
        '// Main\n',
      );
      expect(fixture.textAt('/repertoires/KID/Main.pgn'), isNot('// Main\n'));
    },
  );

  testWidgets('no deleted chapters says so', (tester) async {
    await show(tester, [kid]);
    await tester.tap(find.text('Deleted chapters'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Nothing deleted'), findsOneWidget);
  });
}
