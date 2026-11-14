// The Databases mode on its own: what its Actions menu offers while the
// database is busy, and a game opened from it, unless the user has moved
// on by the time it is kept.
import 'dart:async';

import 'package:chess_auto_prep/app/database_view.dart';
import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/app/mode_view.dart';
import 'package:chess_auto_prep/features/databases/database_library.dart';
import 'package:chess_auto_prep/features/databases/twic_download.dart';
import 'package:chess_auto_prep/storage/master_corpus.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/ui/app_action.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/viewer_fixture.dart';
import '../support/window_fixture.dart';

const _alice = (
  id: 1,
  white: 'Alice',
  black: 'Bob',
  event: 'Club',
  date: '2026.09.27',
  eco: 'C20',
  result: '1-0',
  whiteElo: 2400,
  blackElo: 2300,
);

/// One game, whose text comes when [held] is completed, if it is set.
class _Corpus implements MasterCorpus {
  Completer<void>? held;

  @override
  Future<CorpusResult<CorpusSize>> size(String path) async => const CorpusRead((
    games: 1,
    bytes: 100,
    firstDate: '2026.09.27',
    lastDate: '2026.09.27',
    firstIssue: 0,
    lastIssue: 0,
    imports: 0,
  ));

  @override
  Future<CorpusResult<CorpusPage>> search(
    String path,
    CorpusFilter filter,
  ) async => const CorpusRead((games: [_alice], more: false));

  @override
  Future<CorpusResult<String>> game(String path, int id) async {
    await held?.future;
    return const CorpusRead(
      '[Event "Club"]\n[White "Alice"]\n[Black "Bob"]\n[Result "1-0"]\n\n1. e4 e5 1-0\n',
    );
  }

  @override
  Future<CorpusResult<(int, int)>> importPgn(
    String source,
    String path,
  ) async => const CorpusRead((1, 0));
}

void main() {
  late WindowFixture w;
  late _Corpus corpus;
  setUp(() {
    w = WindowFixture();
    corpus = _Corpus();
  });
  tearDown(() => w.dispose());

  DatabasesView view({String? path = '/master_games.db', bool twic = false}) {
    final library = DatabaseLibrary(
      path: path,
      corpus: corpus,
      picker: ScriptedPicker(),
      documents: w.store,
      collections: w.parts.env.folders.collections,
      pending: PendingWrites(),
      download: twic
          ? TwicDownload(
              '/master_games.db',
              client: () => MockClient((_) async => http.Response('', 404)),
            )
          : null,
    );
    final view = DatabasesView(w.parts.workspace, library, w.requests);
    addTearDown(() {
      view.dispose();
      library.dispose();
    });
    return view;
  }

  group('its Actions menu', () {
    Future<List<AppAction>> actions(
      WidgetTester tester,
      DatabasesView view,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final editing = ValueNotifier(false);
      addTearDown(editing.dispose);
      void none() {}
      final ModeMenu menu = (
        editing: editing,
        board: () => const [],
        dialogs: (
          saveCopy: none,
          saveHeld: none,
          exportPgn: none,
          search: none,
          accounts: none,
          newBook: none,
          importCourse: none,
        ),
        context: tester.element(find.byType(SizedBox)),
      );
      return view.actions(menu);
    }

    bool on(List<AppAction> actions, String label) =>
        actions.singleWhere((action) => action.label == label).run != null;

    testWidgets('offers TWIC only where there is a download, and not while '
        'a file is imported', (tester) async {
      expect(
        (await actions(tester, view())).map((action) => action.label),
        isNot(contains('Download TWIC…')),
      );
      final twic = view(twic: true);
      expect(on(await actions(tester, twic), 'Download TWIC…'), isTrue);
      twic.library.activity = DatabaseActivity.importing;
      expect(on(await actions(tester, twic), 'Download TWIC…'), isFalse);
    });

    testWidgets('imports a file only into a database at rest', (tester) async {
      final databases = view();
      expect(on(await actions(tester, databases), 'Import PGN…'), isTrue);
      databases.library.activity = DatabaseActivity.reading;
      expect(on(await actions(tester, databases), 'Import PGN…'), isFalse);
      databases.library
        ..activity = DatabaseActivity.idle
        ..removing = 'TWIC';
      expect(on(await actions(tester, databases), 'Import PGN…'), isFalse);
      expect(
        on(await actions(tester, view(path: null)), 'Import PGN…'),
        isFalse,
      );
    });
  });

  group('a game opened from the list', () {
    Future<DatabasesView> listed(WidgetTester tester) async {
      final databases = view();
      w.requests.switchTo(Mode.databases);
      await tester.pumpWidget(
        MaterialApp(
          theme: darkTheme(),
          home: Scaffold(body: databases.screen(const {})),
        ),
      );
      await tester.runAsync(databases.library.refresh);
      await tester.pump();
      return databases;
    }

    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.text('Alice — Bob'));
      await tester.pump();
    }

    Future<void> kept(WidgetTester tester) async {
      corpus.held?.complete();
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    testWidgets('comes up in the viewer, and the page takes the keys', (
      tester,
    ) async {
      await listed(tester);
      expect(FocusManager.instance.primaryFocus, isNotNull);
      expect(
        FocusManager.instance.primaryFocus!.context!
            .findAncestorWidgetOfExactType<Scaffold>(),
        isNotNull,
      );
      await open(tester);
      await kept(tester);
      expect(w.requests.mode, Mode.pgnViewer);
      expect(w.session.source?.path, contains('database games'));
    });

    testWidgets('does not come up once the mode is left', (tester) async {
      final databases = await listed(tester);
      corpus.held = Completer();
      await open(tester);
      databases.left();
      await kept(tester);
      expect(w.session.source, isNull);
    });

    testWidgets('does not come up once another mode is up', (tester) async {
      await listed(tester);
      corpus.held = Completer();
      await open(tester);
      w.requests.switchTo(Mode.repertoires);
      await kept(tester);
      expect(w.session.source, isNull);
    });

    testWidgets('does not come up once the list is read again', (tester) async {
      final databases = await listed(tester);
      corpus.held = Completer();
      await open(tester);
      unawaited(databases.library.refresh());
      await kept(tester);
      expect(w.session.source, isNull);
    });
  });
}
