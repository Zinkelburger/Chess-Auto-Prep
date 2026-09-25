import 'dart:async';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/engines/maia/move_policy.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
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

/// Another White chapter of the repertoire: it too leaves 1...c5 open.
const other = '''
// Color: White

[Event "Other"]
[Result "*"]

1. e4 e5 2. Nc3 *
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
  late ScriptedFiles files;
  late GapHunt gaps;

  GapHunt hunt() => GapHunt(
    session: fixture.session,
    model: ReplyModel(policy: policy, settings: settings),
    settings: settings,
    answers: RepertoireAnswers(files: files, documents: fixture.store),
  );

  setUp(() async {
    fixture = await openSession(chapter);
    policy = TwoPositions();
    files = ScriptedFiles();
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
    await gaps.nextGap();
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

  test('another chapter never shows the walk of the one before', () async {
    await pumpEventQueue();
    await gaps.nextGap();
    expect(gaps.walk, isNotNull);
    final ref = chapterRef('KID', 'Other');
    fixture.store.documents[ref] = Opened(other, scriptedRevision(other));
    // What the rest of the repertoire answers is still being read.
    files.hold = true;
    await fixture.session.open(ref);
    expect(gaps.walk, isNull);
    expect(gaps.walking, isTrue);
    expect(gaps.highlighted, isNull);
    await gaps.nextGap();
    expect(fixture.session.cursor, const NodePath.root());
    files
      ..hold = false
      ..releaseAll();
    await pumpEventQueue();
    expect(gaps.walk!.gaps.whereType<MissingReply>().single.san, 'c5');
  });

  test('the chapter left behind is read again: what it now answers is not '
      'a gap in the next one', () async {
    final main = fixture.ref;
    final ref = chapterRef('KID', 'Other');
    fixture.store.documents[ref] = Opened(other, scriptedRevision(other));
    files.listing = Repertoires([
      folder('KID', ['Main', 'Other']),
    ]);
    await pumpEventQueue();
    await fixture.session.open(ref);
    await pumpEventQueue();
    expect(gaps.walk!.gaps.whereType<MissingReply>().single.san, 'c5');
    // Back in Main, 1...c5 gets an answer.
    await fixture.session.open(main);
    fixture.session.forward();
    fixture.session.playMove('c7c5');
    fixture.session.playMove('c2c3');
    await fixture.session.open(ref);
    await pumpEventQueue();
    expect(gaps.walk!.gaps.whereType<MissingReply>(), isEmpty);
  });

  test('closing the document walks the analysis board instead', () async {
    await pumpEventQueue();
    final walked = gaps.walk;
    fixture.session.closed();
    expect(gaps.highlighted, isNull);
    await pumpEventQueue();
    expect(gaps.walk, isNot(same(walked)));
  });
  test('a pending rebuild cannot navigate using the previous walk', () async {
    await pumpEventQueue();
    expect(gaps.walk, isNotNull);
    files.hold = true;
    await settings.update(settings.value.copyWith(opponentElo: 1500));
    await gaps.nextGap();
    await pumpEventQueue();
    expect(fixture.session.cursor, const NodePath.root());
    expect(gaps.highlighted, isNull);
    files
      ..hold = false
      ..releaseAll();
    await pumpEventQueue();
  });

  test(
    'a changed complete read set cannot publish a current gap walk',
    () async {
      await pumpEventQueue();
      files.validateWith = (_, _) async => const RepertoireChanged();
      gaps.refreshAnswers();
      await pumpEventQueue();
      expect(gaps.walk, isNull);
      expect(gaps.walking, isFalse);
    },
  );
  test(
    'navigation validation cannot adopt a gap after settings changed',
    () async {
      await pumpEventQueue();
      final checked = Completer<RepertoireValidation>();
      var first = true;
      files.validateWith = (_, _) async {
        if (first) {
          first = false;
          return checked.future;
        }
        return const RepertoireCurrent();
      };
      final navigating = gaps.nextGap();
      await pumpEventQueue();
      await settings.update(settings.value.copyWith(coverOnceIn: 20));
      checked.complete(const RepertoireCurrent());
      await navigating;
      await pumpEventQueue();
      expect(fixture.session.cursor, const NodePath.root());
      expect(gaps.highlighted, isNull);
    },
  );

  test(
    'late failed validation cannot replace a newer successful walk',
    () async {
      await pumpEventQueue();
      final checked = Completer<RepertoireValidation>();
      var first = true;
      files.validateWith = (_, _) async {
        if (first) {
          first = false;
          return checked.future;
        }
        return const RepertoireCurrent();
      };
      gaps.refreshAnswers();
      await pumpEventQueue();
      await settings.update(settings.value.copyWith(coverOnceIn: 20));
      await pumpEventQueue();
      final current = gaps.currentWalk;
      expect(current, isNotNull);
      checked.complete(const RepertoireValidationFailed('old failure'));
      await pumpEventQueue();
      expect(gaps.currentWalk, same(current));
      expect(gaps.problem, isNull);
    },
  );

  test(
    'failure after last good walk removes marks and retry restores authority',
    () async {
      await pumpEventQueue();
      await gaps.nextGap();
      final prior = gaps.walk;
      files.validateWith = (_, _) async =>
          const RepertoireValidationFailed('cannot read sibling');
      await settings.update(settings.value.copyWith(coverOnceIn: 20));
      await pumpEventQueue();
      expect(gaps.walk, same(prior));
      expect(gaps.currentWalk, isNull);
      expect(gaps.canNextGap, isFalse);
      expect(gaps.highlighted, isNull);
      expect(gaps.problem, contains('cannot read sibling'));
      files.validateWith = null;
      gaps.retry();
      await pumpEventQueue();
      expect(gaps.currentWalk, isNotNull);
      expect(gaps.problem, isNull);
    },
  );
}
