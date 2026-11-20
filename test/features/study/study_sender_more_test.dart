// Sending a study to Lichess, in the small: 64 chapters go and 65 do not, a
// failure after chapters went and were updated says so, a fresh study or
// another study gets new chapters rather than replacing old links, a refused
// chapter stops the send, links are written even while reading holds
// edits, a send that only updated says no "0 added", and a long name is cut
// at 100 characters.
import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/chess/pgn/study_lichess.dart';
import 'package:chess_auto_prep/features/study/study_import_source.dart';
import 'package:chess_auto_prep/features/study/study_sender.dart';
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

  test('an append keeps each unclaimed remote chapter link once', () async {
    const base = 'https://lichess.org/study/wxyz9876';
    const first = '$base/oldchap0';
    const second = '$base/oldchap1';
    final (fixture, sender) = await open(_chapter('A', url: first));
    final text = [
      _chapter('B', url: second),
      _chapter('A again', url: '$first?from=export'),
      _chapter('B again', url: '$second/'),
    ].join('\n');
    final data = await fixture.studies.imports.pgn(text) as StudyImportData;
    await fixture.studies.importPreview(data, into: fixture.ref);

    expect(
      fixture.session.chapter!.lines.map(
        (line) => tagValue(line.tags, chapterUrlTag),
      ),
      [first, second, null, null],
    );
    await sender.send(into: 'wxyz9876');
    expect(lichess.replaced.map((r) => r.chapter), ['oldchap0', 'oldchap1']);
    expect(lichess.added.map((a) => a.name), ['A again', 'B again']);
  });

  test('a deliberate copy into a new local study starts unlinked', () async {
    const old = 'https://lichess.org/study/wxyz9876/oldchap0';
    final (fixture, sender) = await open(_chapter('A', url: old));
    final copy = gameDraft(fixture.session)!.named('Analysis');
    await fixture.studies.addChapters(const NewStudy('Notes'), [copy]);
    await fixture.session.open(studyRef('Notes'), game: 0);

    await sender.send(into: 'wxyz9876');
    expect(lichess.replaced, isEmpty);
    expect(lichess.added.map((a) => a.name), ['Analysis']);
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
