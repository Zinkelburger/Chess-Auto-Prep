import 'dart:io';

import 'package:chess_auto_prep/features/databases/database_library.dart';
import 'package:chess_auto_prep/features/databases/databases_screen.dart';
import 'package:chess_auto_prep/features/databases/twic_download.dart';
import 'package:chess_auto_prep/storage/master_corpus.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';

void main() {
  late Directory support;
  late String master;
  late String leftover;
  late String repertoire;

  setUp(() async {
    support = Directory.systemTemp.createTempSync('v2-database-storage-');
    master = p.join(support.path, 'master_games.db');
    leftover = p.join(support.path, 'master_games.db.pre-v3.bak');
    repertoire = p.join(support.path, 'repertoires', 'KID.pgn');
    File(master).writeAsBytesSync(List.filled(3000, 1));
    File('$master-wal').writeAsBytesSync(List.filled(100, 1));
    File(leftover).writeAsBytesSync(List.filled(5000, 1));
    File(repertoire)
      ..createSync(recursive: true)
      ..writeAsStringSync('1. d4 *');
  });
  tearDown(() => support.deleteSync(recursive: true));

  DatabaseLibrary library({TwicDownload? download}) => DatabaseLibrary(
    path: master,
    corpus: const SqliteMasterCorpus(),
    picker: ScriptedPicker(),
    documents: ScriptedDocumentStore(),
    collections: p.join(support.path, 'collections'),
    pending: PendingWrites(),
    download: download,
    places: (
      support: support.path,
      derived: const ['master_games.db'],
      stores: [
        (name: 'Master games', path: master, removable: true),
        (name: 'Repertoires', path: p.dirname(repertoire), removable: false),
      ],
    ),
  );

  test('deleting a store frees it and measures again; user folders are '
      'never removable', () async {
    final databases = library();
    addTearDown(databases.dispose);
    await databases.measure();
    expect(
      {for (final s in databases.storage) s.name: (s.bytes, s.removable)},
      {
        'Master games': (3100, true),
        'Repertoires': (7, false),
        'Leftover master_games.db.pre-v3.bak': (5000, true),
      },
    );
    await databases.remove(databases.storage.last);
    await databases.remove(databases.storage[1]);
    expect(File(leftover).existsSync(), isFalse);
    expect(File(repertoire).existsSync(), isTrue);
    expect(databases.message, contains('freed 4.9 KB'));
    expect(databases.storage.map((s) => s.name), [
      'Master games',
      'Repertoires',
    ]);
  });

  test('a running download keeps its database from being deleted', () async {
    final download = TwicDownload(master)..running = true;
    final databases = library(download: download);
    addTearDown(databases.dispose);
    await databases.measure();
    await databases.remove(databases.storage.first);
    expect(File(master).existsSync(), isTrue);
    download.running = false;
    await databases.remove(databases.storage.first);
    expect(File(master).existsSync(), isFalse);
    expect(File('$master-wal').existsSync(), isFalse);
  });

  testWidgets(
    'Storage opens from the heading; Delete asks first and then frees the file',
    (tester) async {
      final databases = library();
      addTearDown(databases.dispose);
      await tester.runAsync(databases.measure);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DatabasesScreen(library: databases, onOpen: (_) {}),
          ),
        ),
      );
      expect(find.text('Storage · 7.9 KB'), findsOneWidget);
      expect(find.byTooltip('Delete Master games'), findsNothing);
      await tester.tap(find.text('Storage · 7.9 KB'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Delete Repertoires'), findsNothing);
      await tester.tap(find.byTooltip('Delete Master games'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(File(master).existsSync(), isTrue);
      await tester.tap(find.byTooltip('Delete Master games'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      // The delete, the measure and the recount are real disk work: let them
      // run, pumping between, instead of settling on a progress animation.
      bool busy() =>
          databases.message == null ||
          databases.measuring ||
          databases.activity != DatabaseActivity.idle;
      await tester.pump();
      for (var i = 0; i < 300 && busy(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(busy(), isFalse);
      expect(File(master).existsSync(), isFalse);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Deleted Master games'), findsOneWidget);
    },
  );
}
