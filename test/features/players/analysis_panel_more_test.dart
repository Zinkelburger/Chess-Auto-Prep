// More of the Player analysis column: the player's menu offers Get games
// only for a player with an account, the search box keeps what is typed, a
// position row opens the first game that reached it, and the list switch
// lights the list shown.
import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/features/players/analysis_panel.dart';
import 'package:chess_auto_prep/features/players/player_analysis.dart';
import 'package:chess_auto_prep/features/players/player_games.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/ui/choice_field.dart';
import 'package:chess_auto_prep/ui/menu_entry.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_store.dart';
import '../../support/window_fixture.dart';

const _games =
    '[Event "Club"]\n[White "Alex"]\n[Black "Bob"]\n[Date "2026.09.20"]\n'
    '[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 1-0\n\n'
    '[Event "Open"]\n[White "Alex"]\n[Black "Cy"]\n[Date "2026.09.21"]\n'
    '[Result "1/2-1/2"]\n\n1. e4 c5 1/2-1/2\n';

void main() {
  late WindowFixture w;
  const ref = DocumentRef('/collections/alex.pgn');
  final opened = <(int, PlayerPosition?)>[];

  setUp(() {
    opened.clear();
    w = WindowFixture();
    w.store.documents[ref] = Opened(_games, scriptedRevision(_games));
  });
  tearDown(() => w.dispose());

  PlayerAnalysis analysis() => w.parts.players.analysis;

  Future<void> choose(WidgetTester tester, Player player) async {
    await tester.runAsync(() async {
      await w.parts.players.directory.save(player);
      await analysis().select(player);
    });
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
            onChoose: (_) {},
            onImport: () {},
            onDownload: (_) {},
            onDirectory: () {},
            trailing: const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<List<String>> menu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Player actions'));
    await tester.pumpAndSettle();
    final labels = [
      for (final entry in tester.widgetList<MenuEntry>(find.byType(MenuEntry)))
        entry.label,
    ];
    await tester.tap(find.byTooltip('Player actions'));
    await tester.pumpAndSettle();
    return labels;
  }

  testWidgets('Get games is offered for a player with an account only', (
    tester,
  ) async {
    final files = {
      'pgn_files': [ref.path],
    };
    await choose(tester, Player.create('Alex').edited(files));
    await show(tester);
    expect(await menu(tester), [
      'Change player…',
      'Add PGN…',
      'Refresh',
      'Players & prep',
    ]);
    await choose(
      tester,
      Player.create('Alex').edited({...files, 'lichess': 'alexk'}),
    );
    await show(tester);
    expect(await menu(tester), contains('Get games…'));
  });

  testWidgets('the search box keeps what is typed', (tester) async {
    await choose(
      tester,
      Player.create('Alex').edited({
        'pgn_files': [ref.path],
      }),
    );
    await show(tester);
    await tester.enterText(find.byType(TextField), 'Cy');
    await tester.pump();
    expect(analysis().query, 'Cy');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Cy',
    );
    expect(find.text('1 game'), findsOneWidget);
  });

  testWidgets('a position reached in several games opens the first of them', (
    tester,
  ) async {
    await choose(
      tester,
      Player.create('Alex').edited({
        'pgn_files': [ref.path],
      }),
    );
    await show(tester);
    await tester.tap(find.text('1. e4'));
    expect(opened.single.$1, 0);
    expect(opened.single.$2!.count, 2);
  });

  testWidgets('each range of dates keeps the days it names, and the field '
      'says the range kept', (tester) async {
    await choose(
      tester,
      Player.create('Alex').edited({
        'pgn_files': [ref.path],
      }),
    );
    await show(tester);
    await tester.tap(find.text('Filters'));
    await tester.pump();
    ChoiceField field() => tester.widget<ChoiceField>(find.byType(ChoiceField));
    expect(field().text, 'All dates');
    for (final days in [30, 90, 180, 365]) {
      field().onSubmitted!('Last $days days');
      await tester.pump();
      expect(analysis().recentDays, days);
      expect(field().text, 'Last $days days');
    }
    field().onSubmitted!('All dates');
    await tester.pump();
    expect(field().text, 'All dates');
  });

  testWidgets('the position filters go back to listing every position', (
    tester,
  ) async {
    await choose(
      tester,
      Player.create('Alex').edited({
        'pgn_files': [ref.path],
      }),
    );
    await show(tester);
    await tester.tap(find.text('Filters'));
    await tester.pump();
    for (final label in ['Minimum games', 'From move']) {
      await tester.tap(find.byTooltip('Increase $label'));
      await tester.pump();
    }
    expect((analysis().minGames, analysis().fromMove), (2, 2));
    expect(find.text('Filters (2)'), findsOneWidget);
    for (final label in ['Minimum games', 'From move']) {
      await tester.tap(find.byTooltip('Decrease $label'));
      await tester.pump();
    }
    expect((analysis().minGames, analysis().fromMove), (1, 1));
    expect(find.text('Filters'), findsOneWidget);
  });

  testWidgets('once positions have evaluations, the table sorts by them and '
      'shows them', (tester) async {
    await choose(
      tester,
      Player.create('Alex').edited({
        'pgn_files': [ref.path],
      }),
    );
    final e4 = analysis().positions.firstWhere((p) => p.line.length == 1);
    analysis().evals[e4.key] = 35;
    analysis().configure(order: PositionOrder.badEval);
    await show(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Eval'), findsOneWidget);
    expect(find.textContaining('+0.35'), findsOneWidget);
    await tester.tap(find.byTooltip('Most played first'));
    await tester.pump();
    expect(analysis().order, PositionOrder.frequent);
  });

  testWidgets('the list switch lights the list shown', (tester) async {
    await choose(
      tester,
      Player.create('Alex').edited({
        'pgn_files': [ref.path],
      }),
    );
    await show(tester);
    Set<PlayerList> lit() => tester
        .widget<SegmentedButton<PlayerList>>(
          find.byType(SegmentedButton<PlayerList>),
        )
        .selected;
    expect(lit(), {PlayerList.openings});
    analysis().configure(list: PlayerList.games);
    await tester.pump();
    expect(lit(), {PlayerList.games});
  });
}
