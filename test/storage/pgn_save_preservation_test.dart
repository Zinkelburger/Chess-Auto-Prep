// What a save through the real store keeps: a note written into one game
// of a file, through the app's own edit and landing, reaches the disk with
// every other game's bytes, the preamble and the byte-order mark as they
// were, and reads back as the game it was plus the note.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_sections.dart';
import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/storage/document_text.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/gen/edit_gen.dart';
import '../support/props.dart';
import 'store_fixture.dart';

const _pgnFolder = 'test/fixtures/pgn';

String _fixture(String name) =>
    File(p.join(_pgnFolder, name)).readAsStringSync();

List<String> _fixtureNames() => [
  for (final file in Directory(_pgnFolder).listSync().whereType<File>())
    p.basename(file.path),
]..sort();

void main() {
  late StoreFixture fixture;

  setUp(() async => fixture = await StoreFixture.create());
  tearDown(() => fixture.dispose());

  for (final name in _fixtureNames()) {
    test('$name: a note saved into each game leaves the others on disk', () {
      return _noteInEveryGame(fixture, name, _fixture(name), Focus.game);
    });
  }

  test('a file with a byte-order mark and CRLF keeps both on every save', () {
    final text =
        '﻿// Color: White\r\n\r\n'
        '${_fixture('chesscom.pgn').replaceAll('\n', '\r\n')}';
    return _noteInEveryGame(fixture, 'Marked.pgn', text, Focus.game);
  });

  test('a course of every fixture: a note saved into each chapter leaves '
      'every game of the others on disk', () {
    final course = CourseFile([
      for (final name in _fixtureNames())
        if (name != 'malformed.pgn') LiteralFile(_fixture(name)),
      LiteralFile(_fixture('malformed.pgn')),
    ]);
    return _noteInEveryGame(fixture, 'Course.pgn', course.text, Focus.section);
  });
}

/// Puts [text] on disk as [name], then, one after another, writes a note
/// into each game ([Focus.game]) or each chapter ([Focus.section]) through
/// the app's own edit and landing, and saves it through the store with the
/// scope it landed with. After each save the disk holds the landed text,
/// and every game the edit did not write is there byte for byte.
Future<void> _noteInEveryGame(
  StoreFixture fixture,
  String name,
  String text,
  Focus focus,
) async {
  final ref = fixture.ref('repertoires/Saved/$name');
  await Directory(p.dirname(ref.path)).create(recursive: true);
  await File(ref.path).writeAsBytes(utf8.encode(text));
  final random = Rand(text.length);
  var current = text;
  final count = focus == Focus.game
      ? parseChapter(name: name, text: text).lines.length
      : chapterSections(parseChapter(name: name, text: text).lines).length;
  var saves = 0;
  for (var pick = 0; pick < count; pick++) {
    final opened = await fixture.store.open(ref) as Opened;
    expect(opened.text, current);
    expect(opened.readOnly, isNull);
    final step = makeEdit(
      shownOf(current, focus, pick),
      current,
      EditSpec(EditKind.comment, a: random.nextDouble(), n: 2 + pick % 2),
    );
    final outcome = step.outcome;
    final reason = '$name ${focus.name} $pick: ${step.spec}';
    if (outcome is! EditLanded) {
      // A game reading did not take whole refuses the note and is left as
      // it is, which is failing open.
      continue;
    }
    final saved = await fixture.store.save(
      ref,
      outcome.landed.text,
      expected: opened.revision,
      scope: outcome.landed.scope,
    );
    expect(saved, isA<Saved>(), reason: '$reason: $saved');
    saves++;
    final disk = _onDisk(await File(ref.path).readAsBytes());
    expect(disk, outcome.landed.text, reason: reason);
    _expectUnwrittenKept(current, disk, outcome.games.rewritten, reason);
    current = disk;
  }
  if (parseChapter(name: name, text: text).lines.any((l) => l.isWhole)) {
    expect(saves, greaterThan(0), reason: '$name took no note at all');
  } else {
    // No game was read whole, so none took a note and the file is as it was.
    expect(await File(ref.path).readAsBytes(), utf8.encode(text));
  }
}

/// [bytes] read as the store reads them: a byte-order mark is text.
String _onDisk(List<int> bytes) => (readDocumentText(bytes) as PlainText).text;

/// Every game of [before] outside [rewritten] is in [after] at its place
/// with its bytes; the preamble, byte-order mark included, is unchanged.
void _expectUnwrittenKept(
  String before,
  String after,
  Set<int> rewritten,
  String reason,
) {
  final was = splitChapterText(before);
  final now = splitChapterText(after);
  expect(now.preamble, was.preamble, reason: reason);
  expect(now.games.length, was.games.length, reason: reason);
  for (final (index, game) in was.games.indexed) {
    if (rewritten.contains(index)) continue;
    expect(now.games[index].text, game.text, reason: '$reason game $index');
  }
}
