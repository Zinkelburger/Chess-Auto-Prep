/// What a study keeps when the app writes it back.
///
/// A study is a PGN file the reader owns, and editing anywhere in it —
/// playing a move counts — rewrites the *whole file* from [StudyDocument]
/// (`StudyController._save`). So whatever the model cannot hold is deleted
/// from every chapter on the next autosave, not just the one being edited.
///
/// Two things it could not hold: the chapter's own opening note (a Lichess
/// study chapter's introduction, which is what `PgnGame.comments` carries)
/// and a note written *before* a move rather than after it (PGN's starting
/// comment — how a variation's "why this line" is written). Both went
/// silently. These tests pin them where the reader would notice: parse,
/// serialize, and read it back.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/study_document.dart';

const _headers =
    '[Event "Chapter one"]\n'
    '[Site "https://lichess.org/study/abcd1234"]\n'
    '[Annotator "me"]\n'
    '[Result "*"]\n';

const _intro = 'This chapter is about the Benko. Read this first.';

const _chapter =
    '$_headers'
    '\n'
    '{ $_intro } '
    '1. d4 { the move } \$1 ({ prose before the variation } 1. c4 c5) '
    'Nf6 2. c4 { here [%csl Gd4] } (2. Nf3 { or this } { and a second } e6) '
    'c5 *\n';

StudyDocument _reopen(String pgn) => StudyDocument.fromPgn(pgn, name: 'study');

void main() {
  test("the chapter's own opening note survives a save", () {
    final saved = _reopen(_chapter).toPgn();
    expect(saved, contains(_intro));
    expect(_reopen(saved).chapters.single.intro, _intro);
  });

  test('a note written before a move survives a save', () {
    final saved = _reopen(_chapter).toPgn();
    expect(
      saved,
      contains('prose before the variation'),
      reason: "the variation's introduction was deleted",
    );
  });

  test('the moves, variations, NAGs and shape tokens all survive', () {
    final saved = _reopen(_chapter).toPgn();
    for (final fragment in [
      '1. d4',
      '\$1',
      'the move',
      'c4 c5',
      'Nf3',
      '[%csl Gd4]',
    ]) {
      expect(saved, contains(fragment), reason: 'lost "$fragment"');
    }
  });

  test('headers the model does not own are kept', () {
    final saved = _reopen(_chapter).toPgn();
    expect(saved, contains('[Site "https://lichess.org/study/abcd1234"]'));
    expect(saved, contains('[Annotator "me"]'));
    expect(saved, contains('[Event "Chapter one"]'));
  });

  test('saving twice is a fixed point', () {
    // The property that makes the round trip safe to repeat: an autosave that
    // keeps changing the file is one that is still losing (or inventing)
    // something, and a study is autosaved on every edit.
    final once = _reopen(_chapter).toPgn();
    expect(_reopen(once).toPgn(), once);
  });

  test('a chapter with a note but no moves keeps the note', () {
    const stub = '$_headers\n{ $_intro } *\n';
    final saved = _reopen(stub).toPgn();
    expect(saved, contains(_intro));
    expect(_reopen(saved).toPgn(), saved);
  });

  test('every chapter keeps its own note, not just the first', () {
    const two =
        '$_chapter'
        '\n'
        '[Event "Chapter two"]\n'
        '[Result "*"]\n'
        '\n'
        '{ The second note. } 1. e4 e5 *\n';
    final doc = _reopen(two);
    expect(doc.chapters.length, 2);
    expect(doc.chapters[1].intro, 'The second note.');

    final saved = doc.toPgn();
    expect(saved, contains(_intro));
    expect(saved, contains('The second note.'));
  });
}
