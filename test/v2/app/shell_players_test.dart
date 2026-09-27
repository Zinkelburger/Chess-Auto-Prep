import 'package:chess_auto_prep/v2/app/mode.dart';
import 'package:chess_auto_prep/v2/chess/players/player.dart';
import 'package:chess_auto_prep/v2/features/players/player_analysis.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import '../support/window_fixture.dart';
import '../support/scripted_store.dart';

const _games =
    '[Event "Club"]\n[White "Alex"]\n[Black "Bob"]\n[Date "2026.09.20"]\n[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 1-0\n\n[Event "Club"]\n[White "Bob"]\n[Black "Alex"]\n[Date "2026.09.21"]\n[Result "0-1"]\n\n1. d4 d5 0-1';
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
  });
  tearDown(() => w.dispose());
  testWidgets('directory to analysis, colour, game and retained mode context', (
    tester,
  ) async {
    await w.pumpShell(tester);
    w.requests.switchTo(Mode.players);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Analyze games'));
    await tester.pumpAndSettle();
    // Real isolate work is run outside the fake widget clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(w.requests.mode, Mode.playerAnalysis);
    expect(find.text('Player openings'), findsOneWidget);
    expect(find.text('2 saved games'), findsOneWidget);
    await tester.tap(find.text('As Black'));
    await tester.pumpAndSettle();
    w.parts.players.analysis.configure(list: PlayerList.games);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bob – Alex').first);
    await tester.pumpAndSettle();
    expect(w.session.game, 1);
    expect(w.session.orientation, Side.black);
    w.requests.switchTo(Mode.players);
    await tester.pumpAndSettle();
    w.requests.switchTo(Mode.playerAnalysis);
    await tester.pumpAndSettle();
    expect(w.parts.players.analysis.player!.id, player.id);
    expect(w.parts.players.analysis.side, Side.black);
    expect(tester.takeException(), isNull);
  });
  testWidgets('filters use a bounded dialog instead of overflowing the list', (
    tester,
  ) async {
    await w.pumpShell(tester);
    await tester.runAsync(() => w.parts.players.analysis.select(player));
    w.requests.switchTo(Mode.playerAnalysis);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Filters · 1 game'));
    await tester.pumpAndSettle();
    expect(find.text('Player analysis filters'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
  });
  testWidgets('group prepared state survives leaving and reopening it', (
    tester,
  ) async {
    final group = PlayerGroup.create('Club Open').member(player.id);
    await w.parts.players.directory.saveGroup(group);
    await w.pumpShell(tester);
    w.requests.switchTo(Mode.players);
    w.parts.players.directory.showGroup(group.id);
    await tester.pumpAndSettle();
    expect(find.text('Not prepared yet'), findsOneWidget);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(w.parts.players.directory.group!.prepared(player.id), true);
    await w.parts.players.directory.load();
    await tester.pumpAndSettle();
    expect(find.text('Prepared'), findsOneWidget);
  });
  testWidgets(
    'prep study has both colours and the saved board line opens in Study',
    (tester) async {
      await w.pumpShell(tester);
      await w.parts.players.analysis.select(player);
      await w.parts.players.openStudy(player);
      expect(w.requests.mode, Mode.study);
      expect(w.session.chapter!.lines, hasLength(2));
      final saved = w.parts.players.directory.players.single;
      expect(saved.text('prep_file'), isNotEmpty);
      w.requests.switchTo(Mode.playerAnalysis);
      await w.requests.analysisBoard();
      w.session.playMove('e2e4');
      w.session.playMove('c7c5');
      await w.parts.players.saveLine();
      expect(w.requests.mode, Mode.study);
      expect(w.session.chapter!.lines, hasLength(3));
      expect(w.session.tree!.children.first.san, 'e4');
      expect(w.session.tree!.children.first.children.first.san, 'c5');
      final group = PlayerGroup.create('Club Open').member(player.id);
      await w.parts.players.directory.saveGroup(group);
      await w.parts.players.openGroupStudy(group);
      expect(w.session.chapter!.lines, hasLength(1));
      expect(w.session.tree!.children.first.children.first.san, 'c5');
      final linked = w.parts.players.directory.groups.single;
      expect(linked.fields['study'], isNotNull);
      await w.parts.players.openGroupStudy(linked);
      expect(w.session.chapter!.lines, hasLength(1));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
