// The Download TWIC dialog while another job holds the databases: it says
// which job to wait for and offers no download, and it stays up when the
// user clicks beside it.
import 'package:chess_auto_prep/features/databases/database_library.dart';
import 'package:chess_auto_prep/features/databases/twic_download.dart';
import 'package:chess_auto_prep/features/databases/twic_download_dialog.dart';
import 'package:chess_auto_prep/storage/master_corpus.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';

void main() {
  DatabaseLibrary library() {
    final library = DatabaseLibrary(
      path: '/master_games.db',
      corpus: const SqliteMasterCorpus(),
      picker: ScriptedPicker(),
      documents: ScriptedDocumentStore(),
      collections: '/collections',
      pending: PendingWrites(),
      download: TwicDownload('/master_games.db'),
    );
    addTearDown(library.dispose);
    return library;
  }

  Future<void> open(WidgetTester tester, DatabaseLibrary library) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showTwicDownload(context, library),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  bool downloadOn(WidgetTester tester) =>
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Download'))
          .onPressed !=
      null;

  testWidgets('an import under way is waited for, and no download is '
      'offered until it ends', (tester) async {
    final databases = library()..activity = DatabaseActivity.importing;
    await open(tester, databases);
    expect(find.text('Wait for the import to finish.'), findsOneWidget);
    expect(downloadOn(tester), isFalse);
  });

  testWidgets('a deletion under way is named as the job to wait for', (
    tester,
  ) async {
    final databases = library()..removing = '/master_games.db';
    await open(tester, databases);
    expect(find.text('Wait for the deletion to finish.'), findsOneWidget);
    expect(downloadOn(tester), isFalse);
  });

  testWidgets('with nothing else running a download is offered', (
    tester,
  ) async {
    await open(tester, library());
    expect(find.textContaining('Wait for'), findsNothing);
    expect(downloadOn(tester), isTrue);
  });

  testWidgets('a click beside the dialog does not close it', (tester) async {
    await open(tester, library());
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Download TWIC'), findsOneWidget);
  });
}
