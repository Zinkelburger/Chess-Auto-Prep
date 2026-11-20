import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/features/tactics/tactics_actions.dart';
import 'package:chess_auto_prep/storage/my_accounts.dart';
import 'package:chess_auto_prep/ui/app_action.dart';
import 'package:chess_auto_prep/workspace/analysis/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/workspace_tabs.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/window_fixture.dart';

/// The Actions menu in Tactics over the app's own owners: what each entry
/// says and whether it can be chosen follows the sitting, the answer and the
/// usernames.
void main() {
  late WindowFixture w;
  setUp(() => w = WindowFixture());
  tearDown(() => w.dispose());

  var accountsAsked = 0;
  List<AppAction> actions() => tacticsActions(
    trainer: w.trainer,
    games: w.myGames,
    session: w.session,
    analysis: w.analysis,
    tabs: puzzleTabs(),
    onAccounts: () => accountsAsked++,
  );
  AppAction? named(String label) =>
      actions().where((action) => action.label == label).firstOrNull;
  List<String> labels(String group) => [
    for (final action in actions())
      if (action.group == group) action.label,
  ];

  test('with no sitting the puzzle has no entries, and Engine on starts '
      'the engine', () async {
    expect(labels('Tactics'), isEmpty);
    named('Engine on')!.run!();
    await pumpEventQueue();
    expect(w.analysis.state, isA<EngineFailed>(), reason: 'it was asked');
  });

  test('a puzzle up offers its four entries; the engine waits for the '
      'answer, which Show solution brings', () async {
    await w.tactics.load();
    await w.trainer.start();
    expect(w.trainer.up, isNotNull);
    expect(labels('Tactics'), [
      'Show solution',
      'Skip puzzle',
      'Previous puzzle',
      'End session',
    ]);
    expect(named('Previous puzzle')!.run, isNull, reason: 'the first one');
    expect(named('Engine on')!.run, isNull, reason: 'the answer is hidden');
    expect(named('Flip board')!.run, isNotNull);

    final copied = <String>[];
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding
          .instance
          .defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    named('Copy FEN')!.run!();
    await pumpEventQueue();
    expect(copied, [w.session.cursor.fen.value]);

    final flipped = w.session.flipped;
    named('Flip board')!.run!();
    expect(w.session.flipped, isNot(flipped));

    named('Show solution')!.run!();
    expect(w.trainer.up!.finished, isTrue);
    expect(named('Show solution')!.run, isNull, reason: 'it is shown');
    expect(named('Next puzzle'), isNotNull, reason: 'Skip reads Next now');
    expect(named('Engine on')!.run, isNotNull);

    named('Next puzzle')!.run!();
    await pumpEventQueue();
    expect(named('Previous puzzle')!.run, isNotNull);
    final second = w.trainer.up!.puzzle.fen;
    named('Previous puzzle')!.run!();
    await pumpEventQueue();
    expect(w.trainer.up!.puzzle.fen, isNot(second));

    named('End session')!.run!();
    expect(w.trainer.run, isNull);
    expect(labels('Tactics'), isEmpty);
  });

  test('a sitting put down offers Resume and End session', () async {
    await w.tactics.load();
    await w.trainer.start();
    final fen = w.trainer.up!.puzzle.fen;
    w.trainer.putDown();
    expect(labels('Tactics'), ['Resume', 'End session']);
    named('Resume')!.run!();
    await pumpEventQueue();
    expect(w.trainer.up?.puzzle.fen, fen);
    w.trainer.putDown();
    actions().lastWhere((a) => a.label == 'End session').run!();
    expect(w.trainer.run, isNull);
  });

  test('with no username My games only adds accounts; with one it gets '
      'games, but not while the names are being saved', () async {
    expect(labels('My games'), ['Get games', 'Add accounts…']);
    expect(named('Get games')!.run, isNull);
    named('Add accounts…')!.run!();
    expect(accountsAsked, 1);

    final saving = w.myGames.saveUsernames(lichess: 'Me');
    expect(named('Get games')!.run, isNull, reason: 'still saving');
    await saving;
    expect(w.myGames.accounts[GameSite.lichess], isA<Account>());
    expect(labels('My games'), ['Get games', 'My accounts…']);
    expect(named('Get games')!.run, isNotNull);
    expect(named('My accounts…')!.run, isNotNull);
  });

  test('the card\'s tabs are offered under View', () {
    expect(labels('View'), contains('Close Game'));
  });
}
