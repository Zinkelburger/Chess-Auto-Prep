// The Databases page: the summary line of what the master games hold, the
// game rows and their pages, the filters each search carries, what the list
// says when it is empty, and the Storage button.
import 'dart:async';

import 'package:chess_auto_prep/features/databases/database_library.dart';
import 'package:chess_auto_prep/features/databases/databases_screen.dart';
import 'package:chess_auto_prep/features/databases/twic_download.dart';
import 'package:chess_auto_prep/storage/disk_usage.dart';
import 'package:chess_auto_prep/storage/master_corpus.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/ui/number_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';

CorpusGame _game(int id, {int whiteElo = 2400, int blackElo = 2300}) => (
  id: id,
  white: 'White $id',
  black: 'Black $id',
  event: 'Open',
  date: '2026.09.27',
  eco: 'B22',
  result: '1-0',
  whiteElo: whiteElo,
  blackElo: blackElo,
);

const _someGames = (
  games: 250,
  bytes: 3 << 20,
  firstDate: '',
  lastDate: '',
  firstIssue: 0,
  lastIssue: 0,
  imports: 0,
);

/// [total] games, a hundred to a page, and [answer] for the size.
final class _Corpus implements MasterCorpus {
  _Corpus({this.total = 250, this.answer = _someGames});
  final int total;
  CorpusSize answer;
  final searched = <CorpusFilter>[];

  /// While set, a game asked for is held here.
  Completer<CorpusResult<String>>? held;

  @override
  Future<CorpusResult<CorpusSize>> size(String path) async =>
      CorpusRead(answer);

  @override
  Future<CorpusResult<CorpusPage>> search(
    String path,
    CorpusFilter filter,
  ) async {
    searched.add(filter);
    final end = (filter.offset + 100).clamp(0, total);
    return CorpusRead((
      games: [
        for (var id = filter.offset; id < end; id++)
          if (id == 0) _game(0, whiteElo: 0) else _game(id),
      ],
      more: end < total,
    ));
  }

  @override
  Future<CorpusResult<String>> game(String path, int id) =>
      held?.future ?? Future.value(const CorpusRead('1. e4 *'));

  @override
  Future<CorpusResult<(int, int)>> importPgn(String source, String path) =>
      Completer<CorpusResult<(int, int)>>().future;
}

void main() {
  late List<CorpusGame> opened;

  DatabaseLibrary library(
    _Corpus corpus, {
    String? path = '/master_games.db',
    TwicDownload? download,
    StoragePlaces? places,
    Future<List<StoreUsage>> Function(StoragePlaces)? measure,
  }) {
    final library = DatabaseLibrary(
      path: path,
      corpus: corpus,
      picker: ScriptedPicker('/games.pgn'),
      documents: ScriptedDocumentStore(),
      collections: '/collections',
      pending: PendingWrites(),
      download: download,
      places: places,
      measureWith: measure ?? (_) async => const [],
    );
    addTearDown(library.dispose);
    return library;
  }

  Future<void> show(WidgetTester tester, DatabaseLibrary library) async {
    opened = [];
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DatabasesScreen(library: library, onOpen: opened.add),
        ),
      ),
    );
    await tester.runAsync(library.refresh);
    await tester.pump();
  }

  /// Lets a search typed or pressed for run and be shown.
  Future<void> searched(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }

  bool enabled(WidgetTester tester, String label) =>
      tester
          .widget<ButtonStyleButton>(
            find.ancestor(
              of: find.text(label),
              matching: find.bySubtype<ButtonStyleButton>(),
            ),
          )
          .onPressed !=
      null;

  group('the summary says what the master games hold', () {
    Future<void> expectSummary(
      WidgetTester tester,
      CorpusSize size,
      String summary,
    ) async {
      final databases = library(_Corpus(answer: size));
      await show(tester, databases);
      expect(find.text(summary), findsOneWidget);
    }

    testWidgets('everything known', (tester) async {
      await expectSummary(tester, (
        games: 1944320,
        bytes: 2147483648,
        firstDate: '2020.01.05',
        lastDate: '2026.09.28',
        firstIssue: 1340,
        lastIssue: 1612,
        imports: 2,
      ), 'Master games · 1,944,320 games · 2.0 GB · Jan 2020 – Sep 2026 · '
          'TWIC issues 1340–1612 · 2 PGN files imported');
    });

    testWidgets('one issue, one import, one gigabyte, one month', (
      tester,
    ) async {
      await expectSummary(tester, (
        games: 5,
        bytes: 1 << 30,
        firstDate: '2026.09.01',
        lastDate: '2026.09.30',
        firstIssue: 1500,
        lastIssue: 1500,
        imports: 1,
      ), 'Master games · 5 games · 1.0 GB · Sep 2026 · TWIC issue 1500 · '
          '1 PGN file imported');
    });

    testWidgets('only one readable date, in megabytes', (tester) async {
      await expectSummary(tester, (
        games: 5,
        bytes: 3 << 20,
        firstDate: '????.??.??',
        lastDate: '2026.09.30',
        firstIssue: 0,
        lastIssue: 0,
        imports: 0,
      ), 'Master games · 5 games · 3.0 MB · Sep 2026');
    });

    testWidgets('years whose months cannot be read', (tester) async {
      await expectSummary(tester, (
        games: 5,
        bytes: 3 << 20,
        firstDate: '2025.13.01',
        lastDate: '2026.00.01',
        firstIssue: 0,
        lastIssue: 0,
        imports: 0,
      ), 'Master games · 5 games · 3.0 MB · 2025 – 2026');
    });

    testWidgets('a year alone, and no date at all', (tester) async {
      await expectSummary(tester, (
        games: 5,
        bytes: 3 << 20,
        firstDate: '2024',
        lastDate: '',
        firstIssue: 0,
        lastIssue: 0,
        imports: 0,
      ), 'Master games · 5 games · 3.0 MB · 2024');
    });

    testWidgets('a month without its day', (tester) async {
      await expectSummary(tester, (
        games: 5,
        bytes: 3 << 20,
        firstDate: '2024.05',
        lastDate: '',
        firstIssue: 0,
        lastIssue: 0,
        imports: 0,
      ), 'Master games · 5 games · 3.0 MB · May 2024');
    });

    testWidgets('no readable date', (tester) async {
      await expectSummary(
        tester,
        _someGames,
        'Master games · 250 games · 3.0 MB',
      );
    });

    testWidgets('nothing yet', (tester) async {
      await expectSummary(tester, emptyCorpus, 'Master games · empty');
    });
  });

  testWidgets('a row names the players, the game and both ratings, a missing '
      'one as a dash, and opens the game', (tester) async {
    final databases = library(_Corpus());
    await show(tester, databases);
    expect(find.text('White 0 — Black 0'), findsOneWidget);
    expect(find.text('2026.09.27 · Open · B22 · — / 2300'), findsOneWidget);
    expect(find.text('2026.09.27 · Open · B22 · 2400 / 2300'), findsWidgets);
    await tester.tap(find.text('White 1 — Black 1'));
    expect(opened.single.id, 1);
  });

  testWidgets('while one game opens its row says so and no row can be '
      'opened', (tester) async {
    final corpus = _Corpus()..held = Completer();
    final databases = library(corpus);
    await show(tester, databases);
    final keeping = databases.keep(_game(1));
    await tester.pump();
    expect(find.text('Opening…'), findsOneWidget);
    await tester.tap(find.text('White 2 — Black 2'));
    expect(opened, isEmpty);
    corpus.held!.complete(const CorpusRead('1. e4 *'));
    await tester.runAsync(() => keeping);
    await tester.pump();
    expect(find.text('Opening…'), findsNothing);
    await tester.tap(find.text('White 2 — Black 2'));
    expect(opened.single.id, 2);
  });

  testWidgets('Next and Previous turn the pages and keep the filters', (
    tester,
  ) async {
    final corpus = _Corpus();
    final databases = library(corpus);
    await show(tester, databases);
    await tester.enterText(find.byKey(const ValueKey('Event')), 'Open');
    await searched(tester);
    expect(find.text('Page 1'), findsOneWidget);
    expect(enabled(tester, 'Previous'), isFalse);
    expect(enabled(tester, 'Next'), isTrue);

    await tester.tap(find.text('Next'));
    await searched(tester);
    expect(corpus.searched.last.offset, 100);
    expect(corpus.searched.last.event, 'Open');
    expect(find.text('Page 2'), findsOneWidget);
    expect(find.text('White 100 — Black 100'), findsOneWidget);
    expect(enabled(tester, 'Previous'), isTrue);

    await tester.tap(find.text('Next'));
    await searched(tester);
    expect(find.text('Page 3'), findsOneWidget);
    expect(enabled(tester, 'Next'), isFalse, reason: 'the last page');

    await tester.tap(find.text('Previous'));
    await searched(tester);
    expect(corpus.searched.last.offset, 100);
    expect(corpus.searched.last.event, 'Open');
    expect(find.text('Page 2'), findsOneWidget);
  });

  testWidgets('each filter is carried into the search, and Clear filters '
      'puts every one back', (tester) async {
    final corpus = _Corpus();
    final databases = library(corpus);
    await show(tester, databases);
    expect(find.text('From date (YYYY.MM.DD)'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('Player')), 'Carlsen');
    await tester.enterText(find.byKey(const ValueKey('ECO')), 'B2');
    await tester.enterText(find.byKey(const ValueKey('From date')), '2025');
    final elo = find.descendant(
      of: find.byType(NumberField),
      matching: find.byType(TextField),
    );
    await tester.enterText(elo, '2500');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.tap(find.text('Strongest first'));
    await searched(tester);
    final asked = corpus.searched.last;
    expect(
      (
        asked.player,
        asked.eco,
        asked.since,
        asked.minimumElo,
        asked.strongestFirst,
      ),
      ('Carlsen', 'B2', '2025', 2500, true),
    );

    await tester.tap(find.text('Clear filters'));
    await searched(tester);
    final cleared = corpus.searched.last;
    expect(
      (
        cleared.player,
        cleared.eco,
        cleared.since,
        cleared.minimumElo,
        cleared.strongestFirst,
      ),
      ('', '', '', 0, false),
    );
  });

  group('an empty list says what to do', () {
    testWidgets('with TWIC offered', (tester) async {
      final databases = library(
        _Corpus(total: 0, answer: emptyCorpus),
        download: TwicDownload('/master_games.db'),
      );
      await show(tester, databases);
      expect(
        find.text('Download TWIC or import a PGN to browse games.'),
        findsOneWidget,
      );
    });

    testWidgets('without TWIC', (tester) async {
      final databases = library(_Corpus(total: 0, answer: emptyCorpus));
      await show(tester, databases);
      expect(
        find.text('Import a PGN to add your own games here.'),
        findsOneWidget,
      );
    });

    testWidgets('when the filters match nothing', (tester) async {
      final databases = library(_Corpus(total: 0));
      await show(tester, databases);
      expect(find.text('No games match these filters.'), findsOneWidget);
    });
  });

  testWidgets('an import under way says so and holds the page still', (
    tester,
  ) async {
    final databases = library(
      _Corpus(),
      download: TwicDownload('/master_games.db'),
    );
    await show(tester, databases);
    expect(enabled(tester, 'Import PGN…'), isTrue);
    expect(enabled(tester, 'Download TWIC…'), isTrue);
    unawaited(databases.importFile());
    await tester.pump();
    expect(find.text('Importing games…'), findsOneWidget);
    expect(enabled(tester, 'Import PGN…'), isFalse);
    expect(enabled(tester, 'Download TWIC…'), isFalse);
    expect(enabled(tester, 'Next'), isFalse);
    await tester.tap(find.text('White 1 — Black 1'));
    expect(opened, isEmpty);
  });

  testWidgets('with no database to keep there is nothing to import into', (
    tester,
  ) async {
    final databases = library(_Corpus(), path: null);
    await show(tester, databases);
    expect(enabled(tester, 'Import PGN…'), isFalse);
  });

  testWidgets('Refresh reads the games and measures the storage again', (
    tester,
  ) async {
    var measured = 0;
    final corpus = _Corpus();
    final databases = library(
      corpus,
      places: (support: '/support', derived: const [], stores: const []),
      measure: (_) async {
        measured++;
        return const [];
      },
    );
    await show(tester, databases);
    expect(find.text('Storage · 0 B'), findsOneWidget);
    final searches = corpus.searched.length;
    await tester.tap(find.byTooltip('Refresh'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(corpus.searched.length, searches + 1);
    expect(measured, 1);
  });

  testWidgets('Storage says it is measuring until the first sizes come, and '
      'lists only the stores that hold something', (tester) async {
    final sizes = Completer<List<StoreUsage>>();
    final databases = library(
      _Corpus(),
      places: (support: '/support', derived: const [], stores: const []),
      measure: (_) => sizes.future,
    );
    await show(tester, databases);
    unawaited(databases.measure());
    await tester.pump();
    expect(find.text('Storage · measuring…'), findsOneWidget);
    sizes.complete(const [
      (name: 'Master games', path: '/m', bytes: 2048, removable: true),
      (name: 'Explorer', path: '/e', bytes: 0, removable: true),
      (name: 'Repertoires', path: '/r', bytes: 1, removable: false),
    ]);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(find.text('Storage · 2.0 KB'), findsOneWidget);
    await tester.tap(find.text('Storage · 2.0 KB'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('store-Master games')), findsOneWidget);
    expect(find.byKey(const ValueKey('store-Repertoires')), findsOneWidget);
    expect(find.byKey(const ValueKey('store-Explorer')), findsNothing);
  });

  testWidgets('deleting a leftover copy and deleting a database are each '
      'explained before they are done', (tester) async {
    final databases = library(
      _Corpus(),
      places: (support: '/support', derived: const [], stores: const []),
      measure: (_) async => const [
        (name: 'Master games', path: '/m', bytes: 2048, removable: true),
        (
          name: 'Leftover master_games.db.bak',
          path: '/l',
          bytes: 1024,
          removable: true,
        ),
      ],
    );
    await show(tester, databases);
    await tester.runAsync(databases.measure);
    await tester.pump();
    await tester.tap(find.text('Storage · 3.0 KB'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete Leftover master_games.db.bak…'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'A copy left beside a database the app rebuilds. '
        'Deleting it frees 1.0 KB.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete Master games…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Frees 2.0 KB. Download TWIC'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('while one store is being deleted no other can be', (
    tester,
  ) async {
    final databases = library(
      _Corpus(),
      places: (support: '/support', derived: const [], stores: const []),
      measure: (_) async => const [
        (name: 'Master games', path: '/m', bytes: 2048, removable: true),
        (name: 'Explorer', path: '/e', bytes: 1024, removable: true),
      ],
    );
    await show(tester, databases);
    await tester.runAsync(databases.measure);
    await tester.pump();
    await tester.tap(find.text('Storage · 3.0 KB'));
    await tester.pumpAndSettle();
    bool deletable(String name) =>
        tester.widget<IconButton>(
              find.ancestor(
                of: find.byTooltip('Delete $name…'),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed !=
        null;
    expect(deletable('Master games'), isTrue);
    await tester.tap(find.byTooltip('Delete Explorer…'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pump();
    expect(databases.removing, '/e');
    expect(deletable('Master games'), isFalse);
    for (var i = 0; i < 100 && databases.removing != null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(deletable('Master games'), isTrue);
  });
}
