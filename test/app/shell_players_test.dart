import 'dart:async';
import 'dart:io' show FileSystemException;

import 'package:chess_auto_prep/app/mode.dart';
import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/storage/my_accounts.dart';
import 'package:chess_auto_prep/features/players/player_analysis.dart';
import 'package:chess_auto_prep/features/players/player_hunt.dart';
import 'package:chess_auto_prep/features/trainer/trainer.dart';
import 'package:chess_auto_prep/engines/engine_line.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/player_files.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../support/window_fixture.dart';
import '../support/scripted_store.dart';
import '../support/study_fixture.dart' show studiesRoot;

const _games =
    '[Event "Club"]\n[White "Alex"]\n[Black "Bob"]\n[Date "2026.09.20"]\n[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 1-0\n\n[Event "Club"]\n[White "Bob"]\n[Black "Alex"]\n[Date "2026.09.21"]\n[Result "0-1"]\n\n1. d4 d5 0-1';

/// The directory in memory, whose next player save can be made to fail.
final class _FlakyPlayers implements PlayerStore {
  final _inner = MemoryPlayers();
  Object? throwOnSave;
  @override
  Future<PlayerDirectory> read() => _inner.read();
  @override
  Future<void> savePlayer(Player player, {Player? expected}) async {
    if (throwOnSave case final thrown?) {
      throwOnSave = null;
      throw thrown;
    }
    await _inner.savePlayer(player, expected: expected);
  }

  @override
  Future<void> saveGroup(PlayerGroup group, {PlayerGroup? expected}) =>
      _inner.saveGroup(group, expected: expected);
  @override
  Future<void> removePlayer(Player player) => _inner.removePlayer(player);
  @override
  Future<void> removeGroup(PlayerGroup group) => _inner.removeGroup(group);
}

/// Opens the `⋯` menu of the one person listed.
Future<void> openPlayerMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Player actions'));
  await tester.pumpAndSettle();
}

/// Whether that menu offers to delete the person's saved games; the menu is
/// shut again.
Future<bool> offersDeleteGames(WidgetTester tester) async {
  await openPlayerMenu(tester);
  final offered = find.text('Delete saved games…').evaluate().isNotEmpty;
  await tester.tap(find.byTooltip('Player actions'));
  await tester.pumpAndSettle();
  return offered;
}

void main() {
  late WindowFixture w;
  late _FlakyPlayers players;
  late Player player;
  setUp(() async {
    players = _FlakyPlayers();
    w = WindowFixture(players: players);
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
    expect(find.text('2 games'), findsOneWidget);
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
  testWidgets('filters open in the column, named, and scroll with the list '
      'instead of overflowing it', (tester) async {
    await w.pumpShell(tester);
    await tester.runAsync(() => w.parts.players.analysis.select(player));
    w.requests.switchTo(Mode.playerAnalysis);
    await tester.pumpAndSettle();
    expect(find.text('1 game'), findsOneWidget);
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
    expect(find.text('Minimum games'), findsOneWidget);
    expect(find.text('From move'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Increase Minimum games'));
    await tester.pumpAndSettle();
    expect(w.parts.players.analysis.minGames, 2);
    expect(find.text('Filters (1)'), findsOneWidget);
    // The two that say which positions are listed go with the games list.
    w.parts.players.analysis.configure(list: PlayerList.games);
    await tester.pumpAndSettle();
    expect(find.text('Minimum games'), findsNothing);
    expect(find.text('Time controls'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('the positions table is sorted by its column names', (
    tester,
  ) async {
    await w.pumpShell(tester);
    await tester.runAsync(() => w.parts.players.analysis.select(player));
    w.requests.switchTo(Mode.playerAnalysis);
    await tester.pumpAndSettle();
    final analysis = w.parts.players.analysis;
    expect(analysis.order, PositionOrder.frequent);
    await tester.tap(find.byTooltip('Worst score first'));
    await tester.pumpAndSettle();
    expect(analysis.order, PositionOrder.lowScore);
    await tester.tap(find.byTooltip('Best score first'));
    await tester.pumpAndSettle();
    expect(analysis.order, PositionOrder.highScore);
    await tester.tap(find.byTooltip('Most played first'));
    await tester.pumpAndSettle();
    expect(analysis.order, PositionOrder.frequent);
    // Wins, draws and losses as a crosstable writes them.
    expect(find.text('+1 =0 −0'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
  testWidgets('a board the games never reached offers their first move', (
    tester,
  ) async {
    await w.pumpShell(tester);
    await tester.runAsync(() => w.parts.players.analysis.select(player));
    w.requests.switchTo(Mode.playerAnalysis);
    await tester.pumpAndSettle();
    w.session.playMove('a2a3');
    await tester.pumpAndSettle();
    expect(
      find.text('None of these games reached the position on the board.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Go to the first move'));
    await tester.pumpAndSettle();
    expect(w.session.source?.path, '/collections/player.pgn');
    expect(find.text('Go to the first move'), findsNothing);
    expect(find.text('White / Draw / Black'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('a group is headed by what is known of the event, and what is '
      'seldom done to it is in the toolbar menu', (tester) async {
    final group = PlayerGroup.create(
      'Club Open',
    ).edited({'date': '2026-10-10', 'rounds': 5}).member(player.id);
    await w.parts.players.directory.saveGroup(group);
    await w.pumpShell(tester);
    w.requests.switchTo(Mode.players);
    w.parts.players.directory.showGroup(group.id);
    await tester.pumpAndSettle();
    expect(
      find.text('2026-10-10 · 5 rounds · 1 player · 0 prepared'),
      findsOneWidget,
    );
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.text('Add players'), findsOneWidget);
    expect(find.text('Copy prep sheet'), findsNothing);
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    expect(find.text('Edit group…'), findsOneWidget);
    expect(find.text('Copy prep sheet'), findsOneWidget);
    expect(find.text('Export prep sheet…'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
    expect(find.text('Prepared'), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(w.parts.players.directory.group!.prepared(player.id), true);
    await w.parts.players.directory.load();
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
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

  group('prep study links', () {
    const prepName = 'Prep – Alex.pgn';
    Player current() =>
        w.parts.players.directory.players.firstWhere((p) => p.id == player.id);
    Future<void> link(String path) async {
      final now = current();
      await w.parts.players.directory.save(
        now.edited({'prep_file': path}),
        expected: now,
      );
    }

    testWidgets('a prep study that is gone is made again and relinked', (
      tester,
    ) async {
      await w.pumpShell(tester);
      await link('$studiesRoot/gone.pgn');
      await w.parts.players.openStudy(player);
      expect(w.requests.mode, Mode.study);
      expect(p.basename(current().text('prep_file')), prepName);
      expect(w.session.chapter!.lines, hasLength(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('an unreadable prep study is not replaced', (tester) async {
      await w.pumpShell(tester);
      const bad = DocumentRef('$studiesRoot/bad.pgn');
      w.store.documents[bad] = const Unreadable('bytes');
      await link(bad.path);
      await w.parts.players.openStudy(player);
      expect(current().text('prep_file'), bad.path);
      expect(w.requests.mode, isNot(Mode.study));
      expect(w.requests.status, contains('could not be read'));
      expect(
        w.store.documents.keys.map((r) => p.basename(r.path)),
        isNot(contains(prepName)),
      );
    });

    testWidgets('a study made while its link could not be saved is '
        'adopted the next time', (tester) async {
      await w.pumpShell(tester);
      players.throwOnSave = const PlayerConflict(
        'This player changed in another window. Reload before editing.',
      );
      await w.parts.players.openStudy(player);
      expect(current().text('prep_file'), isEmpty);
      expect(w.parts.players.directory.needsRetry, isFalse);
      await w.parts.players.openStudy(player);
      expect(w.requests.mode, Mode.study);
      expect(p.basename(current().text('prep_file')), prepName);

      // Unlinking leaves the file; after a failed save is put aside, the
      // same study is linked again.
      expect(await w.parts.players.directory.unlinkPrep(current()), isTrue);
      expect(current().text('prep_file'), isEmpty);
      players.throwOnSave = const FileSystemException('disk busy');
      await w.parts.players.openStudy(player);
      expect(w.parts.players.directory.needsRetry, isTrue);
      await w.parts.players.directory.discardFailed();
      await w.parts.players.openStudy(player);
      expect(p.basename(current().text('prep_file')), prepName);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a group study skips a member whose prep study is gone', (
      tester,
    ) async {
      await w.pumpShell(tester);
      const bobPrep = DocumentRef('$studiesRoot/bob.pgn');
      const text =
          '[Event "Prep – Bob"]\n[ChapterName "As Black"]\n\n1. e4 c5 *';
      w.store.documents[bobPrep] = Opened(text, scriptedRevision(text));
      final bob = Player.create('Bob').edited({'prep_file': bobPrep.path});
      await w.parts.players.directory.save(bob);
      await link('$studiesRoot/gone.pgn');
      final group = PlayerGroup.create(
        'Club Open',
      ).member(player.id).member(bob.id);
      await w.parts.players.directory.saveGroup(group);
      await w.parts.players.openGroupStudy(group);
      expect(w.requests.mode, Mode.study);
      expect(w.session.chapter!.lines, hasLength(1));
      expect(w.session.tree!.children.first.children.first.san, 'c5');
      expect(w.requests.status, contains('Alex'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a group study that is gone is made again, and an unlinked '
        'one is adopted again', (tester) async {
      await w.pumpShell(tester);
      final directory = w.parts.players.directory;
      await directory.saveGroup(
        PlayerGroup.create(
          'Club Open',
        ).member(player.id).edited({'study': '$studiesRoot/gone.pgn'}),
      );
      await w.parts.players.openGroupStudy(directory.groups.single);
      expect(w.requests.mode, Mode.study);
      final made = directory.groups.single.fields['study'] as String;
      expect(p.basename(made), 'Prep – Club Open.pgn');
      expect(await directory.unlinkGroupStudy(directory.groups.single), isTrue);
      expect(directory.groups.single.fields['study'], isNull);
      await w.parts.players.openGroupStudy(directory.groups.single);
      expect(directory.groups.single.fields['study'], made);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Save line keeps the board it made when another document '
      'opens while the prep study is made', (tester) async {
    await w.pumpShell(tester);
    await w.parts.players.analysis.select(player);
    w.requests.switchTo(Mode.playerAnalysis);
    await w.requests.analysisBoard();
    w.session.playMove('e2e4');
    w.session.playMove('c7c5');
    final gate = Completer<void>();
    w.store.createGate = gate;
    final saving = w.parts.players.saveLine();
    for (var i = 0; i < 50 && w.store.createGate != null; i++) {
      await tester.pump();
    }
    expect(w.store.createGate, isNull);
    await w.requests.open(ChapterRef.at('/collections/player.pgn'), game: 0);
    expect(w.session.tree!.children.first.children.first.san, 'e5');
    gate.complete();
    await saving;
    expect(w.requests.mode, Mode.study);
    expect(w.session.chapter!.lines, hasLength(3));
    expect(w.session.tree!.children.first.san, 'e4');
    expect(w.session.tree!.children.first.children.first.san, 'c5');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('rows count saved games; downloads can be deleted on their own '
      'or with the person', (tester) async {
    const download = DocumentRef('/games_library/lichess_alex.pgn');
    w.store.documents[download] = Opened(_games, scriptedRevision(_games));
    final current = w.parts.players.directory.players.single;
    await w.parts.players.directory.save(
      current.edited({'lichess': 'alex'}),
      expected: current,
    );
    // Freshness notes are real files, read outside the fake clock.
    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
      }
    }

    await w.pumpShell(tester);
    w.requests.switchTo(Mode.players);
    await settle();
    expect(find.text('4 saved games · 1 PGN file'), findsOneWidget);

    await openPlayerMenu(tester);
    await tester.tap(find.text('Delete saved games…'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Alex’s saved games?'), findsOneWidget);
    await tester.tap(find.text('Delete games'));
    await settle();
    expect(w.store.deleted.keys, [download]);
    expect(find.text('2 saved games · 1 PGN file'), findsOneWidget);
    expect(await offersDeleteGames(tester), isFalse);

    w.store.documents[download] = Opened(_games, scriptedRevision(_games));
    unawaited(w.parts.players.saved.refresh());
    await settle();
    await openPlayerMenu(tester);
    await tester.tap(find.text('Remove player…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove and delete games'));
    await settle();
    expect(w.store.documents.containsKey(download), isFalse);
    expect(w.parts.players.directory.players, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('deleting a person\'s games keeps the download of the user\'s '
      'own account, and the confirm says so', (tester) async {
    const mine = DocumentRef('/games_library/lichess_alex.pgn');
    const theirs = DocumentRef('/games_library/chesscom_alexc.pgn');
    for (final ref in [mine, theirs]) {
      w.store.documents[ref] = Opened(_games, scriptedRevision(_games));
    }
    w.accounts.accounts[GameSite.lichess] = const Account('Alex');
    final current = w.parts.players.directory.players.single;
    await w.parts.players.directory.save(
      current.edited({'lichess': 'alex', 'chesscom': 'alexc'}),
      expected: current,
    );
    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
      }
    }

    await w.pumpShell(tester);
    w.requests.switchTo(Mode.players);
    await settle();
    await openPlayerMenu(tester);
    await tester.tap(find.text('Delete saved games…'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Moves 2 downloaded games to the recovery folder and deletes their '
        'analysis. Linked PGN files stay. Keeps Lichess alex (your account).',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Delete games'));
    await settle();
    expect(w.store.deleted.keys, [theirs]);
    expect(w.store.documents, contains(mine));
    expect(await offersDeleteGames(tester), isFalse);
    expect(tester.takeException(), isNull);
  });

  group('removing a person with downloads', () {
    const download = DocumentRef('/games_library/lichess_alex.pgn');
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
      }
    }

    Future<void> showPlayers(WidgetTester tester) async {
      w.store.documents[download] = Opened(_games, scriptedRevision(_games));
      final current = w.parts.players.directory.players.single;
      await w.parts.players.directory.save(
        current.edited({'lichess': 'alex'}),
        expected: current,
      );
      await w.pumpShell(tester);
      w.requests.switchTo(Mode.players);
      await settle(tester);
    }

    testWidgets('with the user\'s accounts unreadable, deleting games is not '
        'offered and the person goes alone', (tester) async {
      w.accounts.unavailable = true;
      await showPlayers(tester);
      expect(await offersDeleteGames(tester), isFalse);

      await openPlayerMenu(tester);
      await tester.tap(find.text('Remove player…'));
      await settle(tester);
      expect(find.text('Remove and delete games'), findsNothing);
      expect(
        find.text(
          'Saved games and studies stay on disk. Downloads can’t be deleted '
          'while your accounts can’t be read.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Remove'));
      await settle(tester);
      expect(w.parts.players.directory.players, isEmpty);
      expect(w.store.documents, contains(download));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the user\'s accounts changed since the count: the question '
        'is asked about them as they are now', (tester) async {
      await showPlayers(tester);
      expect(await offersDeleteGames(tester), isTrue);
      await w.accounts.setUsername(GameSite.lichess, 'alex');

      await openPlayerMenu(tester);
      await tester.tap(find.text('Remove player…'));
      await settle(tester);
      expect(find.text('Remove and delete games'), findsNothing);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(await offersDeleteGames(tester), isFalse);
    });

    testWidgets('a person whose downloads could not be deleted stays', (
      tester,
    ) async {
      await showPlayers(tester);
      w.store.deletes.add(const IoFailure('disk gone'));
      await openPlayerMenu(tester);
      await tester.tap(find.text('Remove player…'));
      await settle(tester);
      await tester.tap(find.text('Remove and delete games'));
      await settle(tester);
      expect(w.parts.players.directory.players, hasLength(1));
      expect(w.store.documents, contains(download));
      expect(w.requests.status, contains('Could not delete Alex’s games'));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('a dismissed finding stays aside on the person and can be '
      'restored', (tester) async {
    await w.pumpShell(tester);
    // Tall enough that the finding is on screen under the engine controls.
    await tester.binding.setSurfaceSize(const Size(1400, 1400));
    await tester.runAsync(() => w.parts.players.analysis.select(player));
    w.requests.switchTo(Mode.playerAnalysis);
    final analysis = w.parts.players.analysis;
    final hunt = w.parts.players.hunt;
    analysis.configure(list: PlayerList.weaknesses, minPly: 0);
    hunt.findings = [
      PlayerWeakness(analysis.positions.first, const Centipawns(-90), const [
        'g1f3',
      ], false),
    ];
    analysis.changed();
    await tester.pumpAndSettle();
    expect(find.text('Unfavourable position'), findsOneWidget);
    expect(find.text('-0.90'), findsOneWidget);

    await tester.tap(find.byTooltip('Dismiss finding'));
    await tester.pumpAndSettle();
    expect(find.text('Unfavourable position'), findsNothing);
    expect(
      w.parts.players.directory.players.single.strings('dismissed_findings'),
      [hunt.findings.single.key],
    );

    await tester.tap(find.text('Dismissed (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Restore finding'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Back to findings'));
    await tester.pumpAndSettle();
    expect(find.text('Unfavourable position'), findsOneWidget);
    expect(
      w.parts.players.directory.players.single.strings('dismissed_findings'),
      isEmpty,
    );
  });

  testWidgets('Train group study opens it in the trainer without asking '
      'for a side', (tester) async {
    await w.pumpShell(tester);
    await w.parts.players.openStudy(player);
    final prep = w.session.source!;
    const text =
        '[Event "Prep: White"]\n[StudyName "Prep"]\n'
        '[ChapterName "White"]\n[Orientation "white"]\n\n1. e4 e5 *\n\n'
        '[Event "Prep: Black"]\n[StudyName "Prep"]\n'
        '[ChapterName "Black"]\n[Orientation "black"]\n\n1. d4 d5 *\n';
    w.store.documents[prep] = Opened(text, scriptedRevision(text));
    final group = PlayerGroup.create('Club Open').member(player.id);
    await w.parts.players.directory.saveGroup(group);
    w.parts.training.lines.setScope(TrainScope.book);
    w.requests.switchTo(Mode.players);
    w.parts.players.directory.showGroup(group.id);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Train group study'));
    await tester.pumpAndSettle();
    expect(w.requests.mode, Mode.trainer);
    expect(w.session.source?.path, contains('Prep – Club Open'));
    expect(w.session.chapter!.game, 0);
    final trained = w.parts.training.lines.state as TrainerReady;
    expect(trained.lines.map((line) => line.moves.first.san), ['e4', 'd4']);
    expect(trained.lines.map((line) => line.side), [Side.white, Side.black]);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
