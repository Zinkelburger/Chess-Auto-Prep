import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/app/workspace_requests.dart';
import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart' as store;
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/study_fixture.dart';
import '../support/viewer_fixture.dart';
import '../support/window_fixture.dart';

/// Each mode's documents are its own: going to a mode brings up the
/// document it had, never the one the last mode left on the board.
void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  final classics = collectionRef('Classic games');
  void keepClassics() => w.store.documents[classics] = store.Opened(
    threeGameFile,
    scriptedRevision(threeGameFile),
  );

  String titleOf(Object id) => w.requests.documents.tabs.tabOf(id).title;
  String shownTitle() => titleOf(w.requests.documents.tabs.selected);

  Future<void> go(Mode mode) async {
    w.requests.switchTo(mode);
    await pumpEventQueue();
  }

  test('a mode with nothing open shows a board of its own, not the file '
      'the last mode was reading', () async {
    keepClassics();
    await w.requests.openFile(classics, game: 1);
    expect(w.requests.mode, Mode.pgnViewer);

    await go(Mode.study);

    expect(w.requests.mode, Mode.study);
    expect(w.session.source, isNull);
    expect(w.session.isScratch, isTrue);
    expect(w.session.tree!.children, isEmpty);
    expect(shownTitle(), startsWith('Study · '));
    expect(titleOf(classics), 'Viewer · Classic games');
  });

  test(
    'coming back to a mode brings back its document, game and move',
    () async {
      keepClassics();
      await w.requests.openFile(classics, game: 1);
      w.session.cursor.forward();
      w.session.cursor.forward();
      final cursor = w.session.cursor.value;

      await go(Mode.myGames);
      await go(Mode.pgnViewer);

      expect(w.session.source, classics);
      expect(w.session.game, 1);
      expect(w.session.cursor.value, cursor);
      expect(shownTitle(), 'Viewer · Classic games');
    },
  );

  test('tab titles name the mode the document is in, not the mode on '
      'screen', () async {
    await w.requests.open(kidMain);
    expect(titleOf(kidMain), 'Builder · Main');
    await go(Mode.pgnViewer);
    expect(titleOf(kidMain), 'Builder · Main');
    await go(Mode.playerAnalysis);
    expect(titleOf(kidMain), 'Builder · Main');
    await go(Mode.repertoires);
    expect(w.session.source, kidMain);
    expect(shownTitle(), 'Builder · Main');
  });

  test('visiting modes again opens no more tabs', () async {
    keepClassics();
    await w.requests.open(kidMain);
    await w.requests.openFile(classics, game: 0);
    const tour = [
      Mode.study,
      Mode.tactics,
      Mode.myGames,
      Mode.playerAnalysis,
      Mode.repertoires,
      Mode.pgnViewer,
    ];
    for (final mode in tour) {
      await go(mode);
    }
    final open = [...w.requests.documents.tabs.open];
    for (final mode in [...tour, ...tour]) {
      await go(mode);
      expect(w.requests.mode, mode);
    }
    expect(w.requests.documents.tabs.open, open);
    expect(w.session.source, classics);
    await go(Mode.repertoires);
    expect(w.session.source, kidMain);
  });

  test('an empty board goes with the user rather than multiplying', () async {
    expect(w.requests.documents.tabs.open, hasLength(1));
    for (final mode in [Mode.pgnViewer, Mode.study, Mode.tactics]) {
      await go(mode);
      expect(w.requests.documents.tabs.open, hasLength(1));
      expect(
        shownTitle(),
        startsWith(switch (mode) {
          Mode.pgnViewer => 'Viewer',
          final mode => mode.label,
        }),
      );
    }
  });

  test(
    'a mode with a screen of its own leaves the document where it is',
    () async {
      await w.requests.open(kidMain);
      await go(Mode.books);
      expect(w.session.source, kidMain);
      await go(Mode.databases);
      await go(Mode.repertoires);
      expect(w.session.source, kidMain);
      expect(shownTitle(), 'Builder · Main');
    },
  );

  test('closing the last tab of a mode stays in that mode', () async {
    keepClassics();
    await w.requests.open(kidMain);
    await go(Mode.pgnViewer);
    await w.requests.openFile(classics, game: 0);
    await w.requests.documents.close(classics);
    expect(w.requests.mode, Mode.pgnViewer);
    expect(w.session.source, isNull);
    expect(shownTitle(), startsWith('Viewer · '));
  });

  test(
    'a request that hands a document to another mode takes it along',
    () async {
      keepClassics();
      await w.requests.openFile(classics, game: 0);
      // A study opened from elsewhere is up in Study, not the viewer's file.
      final study = studyRef('Openings');
      w.store.documents[study] = store.Opened(
        threeChapterStudy,
        scriptedRevision(threeChapterStudy),
      );
      expect(await w.requests.openStudy(study, chapter: 1), isA<RequestDone>());
      expect(w.requests.mode, Mode.study);
      expect(w.session.source, study);
      expect(shownTitle(), 'Study · Openings');

      // A position set up in Tactics goes to the builder on its own board.
      await go(Mode.tactics);
      expect(
        await w.requests.openPosition(Fen.initial, side: Side.black),
        isA<RequestDone>(),
      );
      expect(w.requests.mode, Mode.repertoires);
      expect(w.session.isScratch, isTrue);
      expect(shownTitle(), startsWith('Builder · '));

      // A line read in the builder from the viewer is the builder's.
      await go(Mode.pgnViewer);
      expect(w.session.source, classics);
      expect(
        await w.requests.readInBuilder(kidMain, const []),
        isA<RequestDone>(),
      );
      expect(w.requests.mode, Mode.repertoires);
      expect(titleOf(kidMain), 'Builder · Main');
      expect(titleOf(classics), 'Viewer · Classic games');
      expect(w.session.cursor.value, const NodePath.root());
    },
  );
}
