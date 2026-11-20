// The Player analysis column: the players to pick from before anyone is
// chosen, then the chosen player's games as positions, games and findings,
// with the filters over them, and the two ways to get games for a player
// who has none. A row opens its game. (The column inside the window, and
// the findings put aside, are in shell_players_test.dart.)
import 'package:chess_auto_prep/chess/players/download_range.dart';
import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/features/players/analysis_filters.dart';
import 'package:chess_auto_prep/features/players/analysis_panel.dart';
import 'package:chess_auto_prep/features/players/player_analysis.dart';
import 'package:chess_auto_prep/features/players/player_games.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/ui/choice_field.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_store.dart';
import '../../support/window_fixture.dart';

const _games =
    '[Event "Club"]\n[White "Alex"]\n[Black "Bob"]\n[Date "2026.09.20"]\n'
    '[ECO "C44"]\n[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 1-0\n\n'
    '[Event "Open"]\n[White "Alex"]\n[Black "Cy"]\n[Date "2026.09.21"]\n'
    '[Result "1/2-1/2"]\n\n1. e4 c5 1/2-1/2\n\n'
    '[Event "Club"]\n[White "Dee"]\n[Black "Alex"]\n[Date "2026.09.22"]\n'
    '[Result "0-1"]\n\n1. d4 d5 0-1\n';

void main() {
  late WindowFixture w;
  late Player alex;
  const ref = DocumentRef('/collections/alex.pgn');

  final opened = <(int, PlayerPosition?)>[];
  Player? chosen;
  PlayerDownloadRange? downloaded;
  var imports = 0, directories = 0;

  setUp(() async {
    opened.clear();
    chosen = null;
    downloaded = null;
    imports = directories = 0;
    w = WindowFixture();
    w.store.documents[ref] = Opened(_games, scriptedRevision(_games));
    alex = Player.create('Alex').edited({
      'lichess': 'alexk',
      'pgn_files': [ref.path],
    });
  });
  tearDown(() => w.dispose());

  PlayerAnalysis analysis() => w.parts.players.analysis;

  Future<void> save(WidgetTester tester, Player player) =>
      tester.runAsync(() => w.parts.players.directory.save(player));

  Future<void> choose(WidgetTester tester, Player player) async {
    await tester.runAsync(() => analysis().select(player));
    await tester.pump();
  }

  Future<void> show(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: AnalysisPanel(
            players: w.parts.players.directory,
            analysis: analysis(),
            hunt: w.parts.players.hunt,
            onOpen: (game, at) => opened.add((game, at)),
            onChoose: (player) => chosen = player,
            onImport: () => imports++,
            onDownload: (range) => downloaded = range,
            onDirectory: () => directories++,
            trailing: const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('before anyone is chosen', () {
    testWidgets('with nobody saved, offers to add the first player', (
      tester,
    ) async {
      await show(tester);
      expect(find.text('Player analysis'), findsOneWidget);
      expect(find.byTooltip('Add player…'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'Add player…'));
      await tester.pumpAndSettle();
      expect(find.text('Add player'), findsOneWidget);
    });

    testWidgets('lists the players saved with where their games come from, '
        'narrowed by the search, and a row chooses its player', (tester) async {
      await save(tester, alex);
      await save(tester, Player.create('Bob'));
      await show(tester);
      expect(find.byTooltip('Add player…'), findsOneWidget);
      expect(find.text('Lichess alexk · 1 PGN file'), findsOneWidget);
      expect(find.text('No games linked yet'), findsOneWidget);
      await tester.enterText(find.byType(TextField), ' BO ');
      await tester.pump();
      expect(find.text('Alex'), findsNothing);
      await tester.enterText(find.byType(TextField), 'zz');
      await tester.pump();
      expect(find.text('Nothing matches "zz".'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'bo');
      await tester.pump();
      await tester.tap(find.text('Bob'));
      expect(chosen?.name, 'Bob');
      await tester.tap(find.text('Players & prep'));
      expect(directories, 1);
    });

    testWidgets('a player with two files says so', (tester) async {
      await save(
        tester,
        Player.create('Cy').edited({
          'pgn_files': ['/a.pgn', '/b.pgn'],
        }),
      );
      await show(tester);
      expect(find.text('2 PGN files'), findsOneWidget);
    });
  });

  group('a player chosen', () {
    testWidgets('counts the games of the colour, and a position or game '
        'row opens its game', (tester) async {
      await save(tester, alex);
      await choose(tester, alex);
      await show(tester);
      expect(find.text('Alex'), findsOneWidget);
      expect(find.text('2 games'), findsOneWidget);
      await tester.tap(find.text('1.\u00A0e4 c5'));
      expect(opened.single.$1, 1);
      expect(opened.single.$2!.label, '1. e4 c5');

      await tester.tap(find.text('As Black'));
      await tester.pump();
      expect(analysis().side, Side.black);
      expect(find.text('1 game'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byType(SegmentedButton<PlayerList>),
          matching: find.text('Games'),
        ),
      );
      await tester.pump();
      expect(find.text('Dee'), findsOneWidget);
      expect(find.text('0-1'), findsOneWidget);
      expect(find.text('2026.09.22 · Club'), findsOneWidget);
      opened.clear();
      await tester.tap(find.text('Dee'));
      expect(opened.single, (2, null));
    });

    testWidgets('a game row names the opponent of either colour, and when, '
        'in which opening and where', (tester) async {
      await save(tester, alex);
      await choose(tester, alex);
      analysis().configure(list: PlayerList.games);
      await show(tester);
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('1-0'), findsOneWidget);
      expect(find.text('2026.09.20 · C44 · Club'), findsOneWidget);
      expect(find.text('Cy'), findsOneWidget);
      expect(find.text('Alex'), findsOneWidget);
    });

    testWidgets('a search that leaves no game says so, and choosing another '
        'player empties the search box', (tester) async {
      await save(tester, alex);
      await choose(tester, alex);
      analysis().configure(list: PlayerList.games);
      await show(tester);
      await tester.enterText(find.byType(TextField), 'nobody');
      await tester.pump();
      expect(find.text('0 games'), findsOneWidget);
      expect(
        find.text(
          'No games match. Try the other colour or loosen the filters.',
        ),
        findsOneWidget,
      );
      final bob = Player.create('Bob').edited({
        'pgn_files': [ref.path],
      });
      await save(tester, bob);
      await choose(tester, bob);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
    });

    testWidgets('sorted by evaluation with none, says so and offers the '
        'engine', (tester) async {
      await save(tester, alex);
      await choose(tester, alex);
      analysis().configure(order: PositionOrder.badEval);
      await show(tester);
      expect(
        find.text('No position has an engine evaluation yet.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Run engine analysis to rank evaluations'));
      await tester.pump();
      expect(analysis().list, PlayerList.weaknesses);
    });

    testWidgets('positions none of the games reach say so', (tester) async {
      await save(tester, alex);
      await choose(tester, alex);
      analysis().configure(minGames: 5);
      await show(tester);
      expect(
        find.text(
          'No positions match. Try the other colour or loosen the filters.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the filters narrow by dates and time controls, and are '
        'counted', (tester) async {
      await save(tester, alex);
      await choose(tester, alex);
      await show(tester);
      expect(find.text('Filters'), findsOneWidget);
      await tester.tap(find.text('Filters'));
      await tester.pump();
      tester.widget<ChoiceField>(find.byType(ChoiceField)).onSubmitted!(
        'Last 90 days',
      );
      await tester.pump();
      expect(analysis().recentDays, 90);
      tester.widget<ChoiceField>(find.byType(ChoiceField)).onSubmitted!(
        'Last week',
      );
      expect(analysis().recentDays, 90);
      await tester.tap(find.text(TimeClass.blitz.label));
      await tester.pump();
      expect(analysis().speeds, {TimeClass.blitz});
      expect(find.text('Filters (2)'), findsOneWidget);
      await tester.tap(find.text(TimeClass.blitz.label));
      await tester.pump();
      expect(analysis().speeds, isEmpty);
      tester.widget<ChoiceField>(find.byType(ChoiceField)).onSubmitted!(
        'All dates',
      );
      await tester.pump();
      expect(analysis().recentDays, isNull);
      expect(find.text('Filters'), findsOneWidget);
    });
  });

  test('each filter that narrows is counted once', () {
    final owner = w.parts.players.analysis;
    expect(AnalysisFilters.active(owner), 0);
    owner.minGames = 2;
    owner.minPly = 2;
    owner.recentDays = 30;
    owner.speeds = {TimeClass.rapid};
    expect(AnalysisFilters.active(owner), 4);
  });

  group('a player with no games', () {
    testWidgets('with an account, gets games or adds a PGN', (tester) async {
      const empty = DocumentRef('/collections/none.pgn');
      w.store.documents[empty] = Opened('', scriptedRevision(''));
      final player = Player.create('Zed').edited({
        'lichess': 'zed',
        'pgn_files': [empty.path],
      });
      await save(tester, player);
      await choose(tester, player);
      await show(tester);
      await tester.tap(find.text('Add PGN…'));
      expect(imports, 1);
      await tester.tap(find.widgetWithText(FilledButton, 'Get games…'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Get games'));
      await tester.pumpAndSettle();
      expect(downloaded, isNotNull);
    });

    testWidgets('without one, only adds a PGN', (tester) async {
      const empty = DocumentRef('/collections/none.pgn');
      w.store.documents[empty] = Opened('', scriptedRevision(''));
      final player = Player.create('Zed').edited({
        'pgn_files': [empty.path],
      });
      await save(tester, player);
      await choose(tester, player);
      await show(tester);
      expect(find.text('Get games…'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'Add PGN…'));
      expect(imports, 1);
    });
  });
}
