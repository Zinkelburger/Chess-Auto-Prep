import 'package:chess_auto_prep/chess/book/book_check.dart';
import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/chess/repertoire_index.dart';
import 'package:chess_auto_prep/features/players/analysis_panel.dart';
import 'package:chess_auto_prep/features/players/player_analysis.dart';
import 'package:chess_auto_prep/features/players/player_book_pane.dart';
import 'package:chess_auto_prep/features/players/player_dialogs.dart';
import 'package:chess_auto_prep/features/players/player_picker.dart';
import 'package:chess_auto_prep/features/tactics/tactics_panel.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/window_fixture.dart';

const _games =
    '[Event "Club"]\n[White "Alex"]\n[Black "Bob"]\n[Date "2026.09.20"]\n'
    '[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 1-0\n\n'
    '[Event "Club"]\n[White "Alex"]\n[Black "Carl"]\n[Date "2026.09.21"]\n'
    '[Result "0-1"]\n\n1. d4 d5 0-1';

/// The two-line lists of Tactics and Player analysis with the system text
/// enlarged: each row grows with its words, and so must the list's extent.
void main() {
  late WindowFixture w;
  late Player player;
  setUp(() async {
    w = WindowFixture();
    const ref = DocumentRef('/collections/player.pgn');
    w.store.documents[ref] = Opened(_games, scriptedRevision(_games));
    player = Player.create('Alex').edited({
      'pgn_files': [ref.path],
    });
    await w.parts.players.directory.save(player);
    await w.parts.players.directory.save(Player.create('Bob'));
  });
  tearDown(() => w.dispose());

  Future<void> pumpScaled(
    WidgetTester tester,
    Widget child, {
    double scale = 1.5,
  }) async {
    await tester.binding.setSurfaceSize(const Size(480, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        // Above the navigator, so dialogs get the larger text too.
        builder: (context, app) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: app!,
        ),
        home: Scaffold(body: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the puzzle rows', (tester) async {
    await pumpScaled(
      tester,
      TacticsPanel(
        set: w.tactics,
        trainer: w.trainer,
        myGames: w.myGames,
        sources: w.parts.training.sources,
        onPlay: ({first}) {},
        onAnalyze: (_) {},
        onAddToStudy: (_) {},
      ),
    );
    expect(find.text('1... f6?'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the saved players to choose from', (tester) async {
    await pumpScaled(
      tester,
      PlayerPicker(
        players: w.parts.players.directory,
        onChoose: (_) {},
        onAdd: () {},
        onDirectory: () {},
      ),
    );
    expect(find.text('Alex'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the pasted players previewed', (tester) async {
    await pumpScaled(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => importPlayers(context, w.parts.players.directory),
          child: const Text('Paste'),
        ),
      ),
    );
    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Name\nDana\nEve');
    await tester.tap(find.text('Preview players'));
    await tester.pumpAndSettle();
    expect(find.text('Dana'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a player\'s games, and the games that left the book', (
    tester,
  ) async {
    final players = w.parts.players;
    await players.analysis.select(player);
    players.analysis.configure(list: PlayerList.games);
    await pumpScaled(
      tester,
      AnalysisPanel(
        players: players.directory,
        analysis: players.analysis,
        hunt: players.hunt,
        onOpen: (_, _) {},
        onChoose: (_) {},
        onImport: () {},
        onDownload: (_) {},
        onDirectory: () {},
        trailing: const SizedBox.shrink(),
      ),
    );
    expect(find.text('Bob'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final file = BookFile(
      path: '/book.pgn',
      name: 'Book',
      index: RepertoireIndex.of(
        const GameTree(rootFen: Fen.initial),
        Side.black,
      ),
    );
    players.book.gaps = [
      for (final game in [0, 1])
        (
          game: game,
          gap: LeftBook(
            kind: Deviation.theirs,
            ply: 0,
            played: '1.e4',
            playedUci: 'e2e4',
            book: const [],
            place: BookPlace(file, const []),
            position: Fen.initial.position,
          ),
        ),
    ];
    await pumpScaled(
      tester,
      PlayerBookPane(book: players.book, onOpen: (_) {}, onBooks: () {}),
    );
    expect(find.text('Unanswered reply'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
