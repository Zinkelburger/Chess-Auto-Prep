import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/engines/maia/move_policy.dart';
import 'package:chess_auto_prep/v2/storage/settings.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/repertoire_answers.dart';
import 'package:chess_auto_prep/v2/workspace/replies.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_files.dart';
import '../support/scripted_store.dart';
import '../support/session_fixture.dart';

const chapter = '''
// Color: White

[Event "Open"]
[Result "*"]

1. e4 e5 2. Nf3 *
''';

/// A sibling chapter that answers 1. e4 c5.
const sicilianChapter = '''
// Color: White

[Event "Sicilian"]
[Result "*"]

1. e4 c5 2. Nf3 *
''';

/// A model that knows two positions and fails on every other.
final class ScriptedPolicy implements MovePolicy {
  final asked = <String>[];

  @override
  Future<MaiaAnswer> policy(Fen fen, int elo) async {
    asked.add('${fen.value.split(' ').take(2).join(' ')}@$elo');
    return switch (fen.value.split(' ').take(2).join(' ')) {
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w' => const MaiaPolicy({
        'e2e4': 0.6,
        'd2d4': 0.35,
        'a2a3': 0.005,
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
  late ScriptedPolicy policy;
  late SettingsStore settings;
  late RepertoireAnswers answers;
  late Replies replies;

  setUp(() async {
    fixture = await openSession(chapter);
    policy = ScriptedPolicy();
    settings = SettingsStore(
      initial: const Settings(opponentElo: 2000, coverOnceIn: 5),
    );
    answers = RepertoireAnswers(
      files: ScriptedFiles(
        listing: Repertoires([
          folder('KID', ['Main', 'Sicilian']),
        ]),
      ),
      documents: fixture.store,
    );
    replies = Replies(
      session: fixture.session,
      policy: policy,
      settings: settings,
      answers: answers,
    );
  });

  tearDown(() {
    replies.dispose();
    settings.dispose();
    fixture.dispose();
  });

  test('the table is the model’s moves at the board, ticked where the '
      'chapter plays them, and rare moves get no row', () async {
    await pumpEventQueue();
    final shown = replies.table as RepliesShown;
    expect(shown.ourMove, isTrue);
    expect(shown.rows.map((row) => row.san), ['e4', 'd4']);
    expect(shown.rows.first.inRepertoire, isTrue);
    expect(shown.rows.first.label, '1.');
    expect(shown.rows.last.inRepertoire, isFalse);
    expect(shown.rows.first.gap, isFalse, reason: 'our move has no gaps');
  });

  test('at their move an unanswered frequent reply is a gap, and the walk '
      'over the chapter finds it too', () async {
    await pumpEventQueue();
    fixture.session.forward();
    await pumpEventQueue();
    final shown = replies.table as RepliesShown;
    expect(shown.ourMove, isFalse);
    final byMove = {for (final row in shown.rows) row.san: row};
    expect(byMove['e5']!.inRepertoire, isTrue);
    expect(byMove['c5']!.gap, isTrue);
    expect(byMove['a6']!.gap, isFalse, reason: 'one in ten is under 1 in 5');
    final walk = replies.walk!;
    expect(walk.gaps.whereType<MissingReply>().single.san, 'c5');
    // After 2. Nf3 the model has no opinion: unanswered, not a gap.
    expect(walk.positionsUnanswered, 1);
    expect(replies.walking, isFalse);
  });

  test('Next gap takes the board to the gap and marks its row; moving on '
      'clears the mark', () async {
    await pumpEventQueue();
    replies.nextGap();
    expect(fixture.session.cursor, NodePath.of([0]));
    expect((replies.highlighted as MissingReply).san, 'c5');
    fixture.session.back();
    expect(replies.highlighted, isNull);
  });

  test('the model is asked once per position and rating', () async {
    await pumpEventQueue();
    fixture.session.forward();
    await pumpEventQueue();
    fixture.session.back();
    await pumpEventQueue();
    final start = policy.asked.where((k) => k.endsWith(' w@2000')).length;
    expect(start, 1);
    await settings.update(settings.value.copyWith(opponentElo: 1500));
    await pumpEventQueue();
    expect(policy.asked.where((k) => k.endsWith('@1500')), isNotEmpty);
  });

  test('a model with no opinion says so instead of showing nothing', () async {
    await pumpEventQueue();
    fixture.session.forward();
    fixture.session.forward();
    await pumpEventQueue();
    expect(replies.table, isA<RepliesFailed>());
    expect((replies.table as RepliesFailed).reason, 'no opinion');
  });

  test('a reply another chapter of the repertoire answers is not a gap; '
      'its row names that chapter', () async {
    // The Sicilian chapter beside Main answers 1. e4 c5, so Main's missing
    // c5 is not a gap: the answer is on another page.
    final sicilian = chapterRef('KID', 'Sicilian');
    fixture.store.documents[sicilian] = Opened(
      sicilianChapter,
      scriptedRevision(sicilianChapter),
    );
    answers.forget();
    // A settings change walks the chapter again, now with the sibling there.
    await settings.update(const Settings(opponentElo: 2000, coverOnceIn: 4));
    await pumpEventQueue();
    fixture.session.forward();
    await pumpEventQueue();
    final shown = replies.table as RepliesShown;
    final byMove = {for (final row in shown.rows) row.san: row};
    expect(byMove['c5']!.gap, isFalse);
    expect(byMove['c5']!.elsewhere, 'Sicilian');
    expect(replies.walk!.gaps, isEmpty);
  });

  test('closing the document empties the table', () async {
    await pumpEventQueue();
    fixture.session.closed();
    expect(replies.table, isA<RepliesEmpty>());
    expect(replies.walk, isNull);
  });
}
