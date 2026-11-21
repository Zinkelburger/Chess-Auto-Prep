// Sending a study to Lichess, in the small: 64 chapters go and 65 do not, a
// failure after chapters went and were updated says so, a fresh study or
// another study gets new chapters rather than replacing old links, a refused
// chapter stops the send, links are written even while reading holds
// edits, a send that only updated says no "0 added", a long name is cut
// at 100 characters, and two chapters naming one Lichess chapter never write
// over each other.
import 'dart:async';

import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/chess/pgn/study_edits.dart';
import 'package:chess_auto_prep/chess/pgn/study_lichess.dart';
import 'package:chess_auto_prep/features/study/study_import_source.dart';
import 'package:chess_auto_prep/features/study/study_sender.dart';
import 'package:chess_auto_prep/net/lichess_studies.dart';
import 'package:chess_auto_prep/workspace/document/study_choice.dart';
import 'package:chess_auto_prep/workspace/document/study_drafts.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_study_writer.dart';
import '../../support/study_fixture.dart';

String _chapter(String name, {String moves = '1. e4 e5 *', String? url}) =>
    '[Event "Plane games: $name"]\n[StudyName "Plane games"]\n'
    '[ChapterName "$name"]\n${url == null ? '' : '[ChapterURL "$url"]\n'}'
    '[Result "*"]\n\n$moves\n';

void main() {
  late ScriptedStudyWriter lichess;

  Future<(StudyFixture, StudySender)> open(String text) async {
    lichess = ScriptedStudyWriter();
    final fixture = await openStudy(
      text,
      name: 'Plane games',
      lichessWriter: lichess,
    );
    addTearDown(fixture.dispose);
    return (fixture, fixture.studies.sender!);
  }

  String chapters(int count) =>
      [for (var i = 1; i <= count; i++) _chapter('Round $i')].join('\n');

  test('64 chapters go to a new study; 65 do not', () async {
    var (_, sender) = await open(chapters(64));
    await sender.send();
    expect(sender.state, isA<SendDone>());
    (_, sender) = await open(chapters(65));
    await sender.send();
    expect(
      (sender.state as SendFailed).sentence,
      startsWith('Lichess keeps at most 64 chapters'),
    );
  });

  test(
    'a failure after one chapter was updated and one added counts both',
    () async {
      const old = 'https://lichess.org/study/wxyz9876/oldchap0';
      final (_, sender) = await open(
        [
          _chapter('Round 1', url: old),
          _chapter('Round 2'),
          _chapter('Round 3'),
        ].join('\n'),
      );
      lichess.refuse.add('Round 3');
      await sender.send(into: 'wxyz9876');
      final failed = sender.state as SendFailed;
      expect(failed.sentence, contains('1 chapter added, 1 updated'));
    },
  );

  test('a fresh study gets new chapters, never replaces old links', () async {
    const old = 'https://lichess.org/study/wxyz9876/oldchap0';
    final (_, sender) = await open(_chapter('Round 1', url: old));
    await sender.send();
    expect(lichess.replaced, isEmpty);
    expect(lichess.added, hasLength(1));
  });

  test('another study gets new chapters, not the links of the first', () async {
    const old = 'https://lichess.org/study/abcd1234/oldchap0';
    final (_, sender) = await open(_chapter('Round 1', url: old));
    await sender.send(into: 'wxyz9876');
    expect(lichess.replaced, isEmpty);
    expect(lichess.added, hasLength(1));
  });

  test(
    'reimporting a chapter preserves the original annotation on send',
    () async {
      const url = 'https://lichess.org/study/wxyz9876/oldchap0';
      final exported = _chapter('Round 1', url: url);
      final (fixture, sender) = await open(exported);
      fixture.session.setComment(NodePath.of([0]), 'Control the center.');
      fixture.lichess.answer = StudyFetched(exported);
      final preview = await fixture.studies.imports.url(url) as StudyImportData;
      await fixture.studies.importPreview(preview, into: fixture.ref);
      expect(fixture.session.chapter!.lines, hasLength(2));

      await sender.send(into: 'wxyz9876');

      final lines = fixture.session.chapter!.lines;
      final original = lichess.chapterPgns[('wxyz9876', 'oldchap0')];
      expect(original, contains('Control the center.'));
      expect(tagValue(lines[0].tags, chapterUrlTag), url);
      final copy = parseStudyLink(tagValue(lines[1].tags, chapterUrlTag)!);
      expect(copy!.studyId, 'wxyz9876');
      final copyId = copy.chapterId!;
      expect(copyId, isNot('oldchap0'));
      expect(
        lichess.chapterPgns[('wxyz9876', copyId)],
        lichessChapterPgn(lines[1]),
      );
      expect((sender.state as SendDone).updated, 1);
      expect(lichess.added, hasLength(1));

      lichess.replaced.clear();
      await sender.send(into: 'wxyz9876');
      expect(
        lichess.replaced.map((r) => r.chapter),
        unorderedEquals(['oldchap0', copyId]),
      );
      expect(lichess.added, hasLength(1));
    },
  );

  test('resending updates the original and adds the edited copy', () async {
    final (fixture, sender) = await open(
      _chapter('Round 1', url: 'https://lichess.org/study/wxyz9876/oldchap0'),
    );
    final session = fixture.session;
    final copy = gameDraft(session)!.named('Round 1 analysis');
    await fixture.studies.addChapters(IntoStudy(fixture.ref), [copy]);
    expect(session.game, 1);
    session.cursor.toEnd();
    session.playMove('g1f3');

    await sender.send(into: 'wxyz9876');

    expect(lichess.replaced.map((r) => r.chapter), ['oldchap0']);
    expect(lichess.added.map((a) => (a.study, a.name)), [
      ('wxyz9876', 'Round 1 analysis'),
    ]);
    expect(lichess.pgns, [
      contains('1. e4 e5 *'),
      contains('1. e4 e5 2. Nf3 *'),
    ]);
  });

  test('a refused chapter stops the send there', () async {
    final (_, sender) = await open(chapters(3));
    lichess.refuse.add('Round 2');
    await sender.send();
    expect(lichess.added.map((a) => a.name), ['Round 1']);
  });

  test('links are written even while reading holds edits', () async {
    final (fixture, sender) = await open(chapters(1));
    fixture.session.holdsEdits = true;
    await sender.send();
    await fixture.saver.flush();
    expect(fixture.onDisk, contains(chapterUrlTag));
  });

  test('a send that only updated names no chapters added', () async {
    final (_, sender) = await open(chapters(1));
    await sender.send();
    await sender.send(into: 'wxyz9876');
    final done = sender.state as SendDone;
    expect((done.added, done.updated, done.skipped), (0, 1, 0));
  });

  test('a failure after updates only names no chapters added', () async {
    const old = 'https://lichess.org/study/wxyz9876/oldchap0';
    final (_, sender) = await open(
      [_chapter('Round 1', url: old), _chapter('Round 2')].join('\n'),
    );
    lichess.refuse.add('Round 2');
    await sender.send(into: 'wxyz9876');
    final sentence = (sender.state as SendFailed).sentence;
    expect(sentence, contains('1 updated before it stopped'));
    expect(sentence, isNot(contains('added')));
  });

  test('a long chapter name is cut at 100 characters', () async {
    final long = 'L' * 101;
    final (_, sender) = await open(_chapter(long));
    await sender.send();
    expect(lichess.added.single.name, 'L' * 100);
  });

  /// Holds the request for chapter [name] until the returned completer is
  /// completed; [reached] completes once the request is held.
  Completer<void> holdAt(String name, Completer<void> reached) {
    final release = Completer<void>();
    lichess.beforeAdd = (added) async {
      if (added != name) return;
      reached.complete();
      await release.future;
    };
    return release;
  }

  test('links reach the study after another document was opened '
      'mid-send, so the next send adds nothing twice', () async {
    final (fixture, sender) = await open(chapters(2));
    final reached = Completer<void>();
    final release = holdAt('Round 2', reached);
    final sending = sender.send();
    await reached.future;
    expect(await fixture.session.showAnalysisBoard(), isTrue);
    release.complete();
    await sending;
    expect(sender.state, isA<SendDone>());
    expect(fixture.onDisk, contains('wxyz9876/chap0000'));
    expect(fixture.onDisk, contains('wxyz9876/chap1000'));

    lichess.beforeAdd = null;
    await fixture.session.open(fixture.ref, game: 0);
    await sender.send(into: 'wxyz9876');
    final done = sender.state as SendDone;
    expect((done.added, done.updated), (0, 2));
    expect(lichess.added, hasLength(2));
  });

  test(
    'a chapter moved mid-send does not take another chapter\'s link',
    () async {
      final (fixture, sender) = await open(chapters(2));
      final reached = Completer<void>();
      final release = holdAt('Round 2', reached);
      final sending = sender.send();
      await reached.future;
      expect(
        fixture.session.apply(
          (now) => moveChapter(now, index: 0, by: 1),
          writes: true,
        ),
        isNull,
      );
      release.complete();
      await sending;
      await fixture.saver.flush();
      final rounds = fixture.onDisk.split('[Event ');
      final round1 = rounds.firstWhere((game) => game.contains('Round 1"]'));
      final round2 = rounds.firstWhere((game) => game.contains('Round 2"]'));
      expect(round1, isNot(contains('chap1000')));
      expect(round2, isNot(contains('chap0000')));
      expect(
        (sender.state as SendFailed).sentence,
        contains('could not keep their links'),
      );
    },
  );

  test('a send whose sender is taken down meanwhile says nothing', () async {
    final (fixture, _) = await open(chapters(2));
    final own = StudySender(
      lichess,
      fixture.session,
      openPage: (_) async => true,
    );
    final sending = own.send();
    own.dispose();
    await expectLater(sending, completes);
  });
}
