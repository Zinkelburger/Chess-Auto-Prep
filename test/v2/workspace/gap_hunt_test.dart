import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/engines/maia/move_policy.dart';
import 'package:chess_auto_prep/v2/storage/settings.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/workspace/gap_hunt.dart';
import 'package:chess_auto_prep/v2/workspace/gap_walk.dart';
import 'package:chess_auto_prep/v2/workspace/replies.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_files.dart';
import '../support/scripted_store.dart';
import '../support/session_fixture.dart';

/// White's chapter answers 1...e5 and stops; 1...c5 is unanswered.
const chapter = '''
// Color: White

[Event "Open"]
[Result "*"]

1. e4 e5 2. Nf3 *
''';

/// Two games of one file: a game is read, not walked.
const twoGames = '''
[Event "One"]
[Result "*"]

1. e4 e5 *

[Event "Two"]
[Result "*"]

1. d4 d5 *
''';

/// A model that plays 1. e4 for White and splits Black's replies; it has no
/// opinion anywhere else, so the walk stops after 2. Nf3.
final class TwoPositions implements MovePolicy {
  int asked = 0;

  @override
  Future<MaiaAnswer> policy(Fen fen, int elo) async {
    asked++;
    return switch (fen.value.split(' ').take(2).join(' ')) {
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w' => const MaiaPolicy({
        'e2e4': 0.9,
        'd2d4': 0.1,
      }),
      'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b' => const MaiaPolicy({
        'e7e5': 0.5,
        'c7c5': 0.4,
        'a7a6': 0.1,
      }),
      _ => const MaiaFailed('no opinion'),
    };
  }
}

void main() {
  late SessionFixture fixture;
  late SettingsStore settings;
  late TwoPositions policy;
  late GapHunt gaps;

  GapHunt hunt() => GapHunt(
    session: fixture.session,
    model: ReplyModel(policy: policy, settings: settings),
    settings: settings,
    answers: RepertoireAnswers(
      files: ScriptedFiles(),
      documents: ScriptedDocumentStore(),
    ),
  );

  setUp(() async {
    fixture = await openSession(chapter);
    policy = TwoPositions();
    settings = SettingsStore(
      initial: const Settings(opponentElo: 2000, coverOnceIn: 5),
    );
    gaps = hunt();
  });

  tearDown(() {
    gaps.dispose();
    settings.dispose();
    fixture.dispose();
  });

  test('the walk over the open chapter finds the unanswered reply', () async {
    expect(gaps.walking, isTrue);
    await pumpEventQueue();
    expect(gaps.walking, isFalse);
    final walk = gaps.walk!;
    expect(walk.gaps.whereType<MissingReply>().single.san, 'c5');
    expect(walk.elsewhere, isNotEmpty, reason: 'its own answered positions');
  });

  test('Next gap takes the board to the gap and marks it; moving on clears '
      'the mark', () async {
    await pumpEventQueue();
    gaps.nextGap();
    expect(fixture.session.cursor, NodePath.of([0]));
    expect((gaps.highlighted as MissingReply).san, 'c5');
    fixture.session.back();
    expect(gaps.highlighted, isNull);
  });

  test('a cursor move with nothing marked tells no one', () async {
    await pumpEventQueue();
    var told = 0;
    gaps.addListener(() => told++);
    fixture.session.forward();
    fixture.session.back();
    expect(told, 0);
  });

  test('another rating walks the chapter again', () async {
    await pumpEventQueue();
    final first = gaps.walk;
    await settings.update(settings.value.copyWith(opponentElo: 1500));
    expect(gaps.walking, isTrue);
    await pumpEventQueue();
    expect(gaps.walk, isNot(same(first)));
    expect(gaps.walking, isFalse);
  });

  test('a setting the walk does not read changes nothing', () async {
    await pumpEventQueue();
    final first = gaps.walk;
    final asked = policy.asked;
    await settings.update(settings.value.copyWith(engineLines: 5));
    await pumpEventQueue();
    expect(gaps.walk, same(first));
    expect(policy.asked, asked);
  });

  test('one game of a file is not walked', () async {
    gaps.dispose();
    fixture.dispose();
    fixture = await openSession(twoGames);
    await fixture.session.open(fixture.ref, game: 0);
    gaps = hunt();
    await pumpEventQueue();
    expect(gaps.walk, isNull);
    expect(gaps.walking, isFalse);
  });

  test('closing the document walks the analysis board instead', () async {
    await pumpEventQueue();
    final walked = gaps.walk;
    fixture.session.closed();
    expect(gaps.highlighted, isNull);
    await pumpEventQueue();
    expect(gaps.walk, isNot(same(walked)));
  });
}
