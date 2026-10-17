/// Game places and line ids for generated chapters as existing training
/// progress keys them, recorded once from the reader that first wrote that
/// progress (the fixture generator remains in Git history), so P7 and P9
/// keep holding. Each entry is a chapter's text, the place in that reading
/// each game starts at, the recorded id for each game of that reading, and
/// the games whose ids are excused: those it cuts at an `[Event ` line
/// inside a comment, the one documented difference, and later games that
/// claim an id the cut left taken in only one reading.
library;

import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/chess/pgn/line_id_pins.dart';
import 'package:flutter_test/flutter_test.dart';

const _corpus = 'test/fixtures/legacy/v1_line_id_corpus.json';

void main() {
  final entries = (jsonDecode(File(_corpus).readAsStringSync()) as List)
      .cast<Map<String, Object?>>();

  test('the corpus holds the chapters it was recorded with', () {
    expect(entries, hasLength(60));
    final games = entries.fold(0, (n, e) => n + (e['places']! as List).length);
    expect(games, greaterThan(120));
    expect(entries.any((e) => (e['excused']! as List).isNotEmpty), isTrue);
    expect(
      entries.any((e) => (e['text']! as String).contains('\uFEFF')),
      isTrue,
    );
    expect(entries.any((e) => (e['text']! as String).contains('\r\n')), isTrue);
    expect(
      entries.any((e) => (e['places']! as List).first != 0),
      isTrue,
      reason: 'a chapter with a recorded game above its first',
    );
  });

  for (final (index, entry) in entries.indexed) {
    test('chapter $index: games and ids as they were recorded', () {
      final text = entry['text']! as String;
      final places = (entry['places']! as List).cast<int>();
      final oldIds = (entry['ids']! as List).cast<String?>();
      final excused = (entry['excused']! as List).cast<int>();
      final chapter = parseChapter(name: 'Corpus', text: text);
      final reason = 'text:\n$text';
      expect(chapter.lines, hasLength(places.length), reason: reason);
      final placed = oldAppGameIndexes(chapter.preamble, [
        for (final line in chapter.lines) line.text,
      ]);
      expect(placed, places, reason: reason);
      final ids = trainedIdsOf(chapter);
      for (var i = 0; i < ids.length; i++) {
        if (excused.contains(i)) continue;
        expect(ids[i], oldIds[places[i]], reason: 'game $i\n$reason');
      }
    });
  }
}
