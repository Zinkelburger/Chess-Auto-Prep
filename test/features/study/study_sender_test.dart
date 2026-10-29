import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/chess/pgn/study_lichess.dart';
import 'package:chess_auto_prep/features/study/study_sender.dart';
import 'package:chess_auto_prep/net/lichess_study_writes.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_study_writer.dart';
import '../../support/study_fixture.dart';

const _study = '''[Event "Plane games: Round 1"]
[StudyName "Plane games"]
[ChapterName "Round 1"]
[Orientation "white"]
[White "Me"]
[Black "Club rival"]
[Result "1-0"]

1. e4 e5 2. Nf3 {Developing.} Nc6 1-0

[Event "Plane games: Round 2"]
[StudyName "Plane games"]
[ChapterName "Round 2"]
[Orientation "black"]
[Result "0-1"]

1. d4 Nf6 0-1
''';

void main() {
  late StudyFixture fixture;
  late ScriptedStudyWriter lichess;
  late StudySender sender;

  setUp(() async {
    lichess = ScriptedStudyWriter();
    fixture = await openStudy(
      _study,
      name: 'Plane games',
      lichessWriter: lichess,
    );
    sender = fixture.studies.sender!;
  });

  tearDown(() => fixture.dispose());

  String? url(int game) =>
      tagValue(fixture.session.chapter!.lines[game].tags, chapterUrlTag);

  test(
    'a new study: made private, every chapter in order with its side, '
    'the first in place of the empty one, and each one\'s link kept',
    () async {
      await sender.send();
      expect(lichess.created, ['Plane games']);
      expect(lichess.added.map((a) => (a.name, a.side, a.initial)), [
        ('Round 1', Side.white, true),
        ('Round 2', Side.black, false),
      ]);
      expect(lichess.pgns.first, contains('{Developing.}'));
      final done = sender.state as SendDone;
      expect((done.study, done.added, done.updated), ('wxyz9876', 2, 0));
      expect(url(0), 'https://lichess.org/study/wxyz9876/chap0000');
      expect(url(1), 'https://lichess.org/study/wxyz9876/chap1000');
      expect(sender.linkedStudy(fixture.session.chapter!), 'wxyz9876');
    },
  );

  test('sending again updates the chapters already there', () async {
    await sender.send();
    lichess.added.clear();
    lichess.pgns.clear();
    await sender.send(into: 'wxyz9876');
    expect(lichess.created, hasLength(1), reason: 'no second study');
    expect(lichess.added, isEmpty);
    expect(lichess.replaced.map((r) => r.chapter), ['chap0000', 'chap1000']);
    expect(lichess.replaced.first.tags, {
      'White': 'Me',
      'Black': 'Club rival',
      'Result': '1-0',
    });
    final done = sender.state as SendDone;
    expect((done.added, done.updated), (0, 2));
  });

  test('a chapter deleted on Lichess since is added again', () async {
    await sender.send();
    lichess.gone.add('chap1000');
    lichess.added.clear();
    await sender.send(into: 'wxyz9876');
    expect(lichess.replaced.map((r) => r.chapter), ['chap0000']);
    expect(lichess.added.map((a) => (a.name, a.initial)), [('Round 2', false)]);
    expect(url(1), 'https://lichess.org/study/wxyz9876/chap2000');
  });

  test('a refused chapter stops the send; what went keeps its link and the '
      'next try goes to the same study', () async {
    lichess.refuse.add('Round 2');
    await sender.send();
    final failed = sender.state as SendFailed;
    expect(failed.sentence, contains('Lichess could not read a chapter.'));
    expect(failed.sentence, contains('Invalid PGN'));
    expect(failed.sentence, contains('1 chapter added before it stopped'));
    expect(failed.study, 'wxyz9876');
    expect(url(0), isNotNull);
    expect(url(1), isNull);
  });

  test('signed out: nothing is sent and logging in is the way out', () async {
    lichess.loggedIn = false;
    await sender.send();
    final failed = sender.state as SendFailed;
    expect(failed.login, isTrue);
    expect(lichess.created, isEmpty);
  });

  test('a token without the permission says to log in again', () async {
    lichess.failing = const LichessNotWritten(LichessWriteProblem.permission);
    await sender.send();
    final failed = sender.state as SendFailed;
    expect(failed.login, isTrue);
    expect(failed.sentence, contains('Log in again'));
    expect(url(0), isNull);
  });

  test('a link names the study it is in', () {
    expect(
      StudySender.studyIn('https://lichess.org/study/abcd1234/efgh5678'),
      'abcd1234',
    );
    expect(StudySender.studyIn('lichess.org/study/abcd1234'), 'abcd1234');
    expect(StudySender.studyIn('not a link'), isNull);
  });
}
