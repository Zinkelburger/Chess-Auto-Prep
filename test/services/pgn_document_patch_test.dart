import 'dart:async';

import 'package:chess_auto_prep/services/pgn_document_patch.dart';
import 'package:flutter_test/flutter_test.dart';

const _first = '[Event "First"]\r\n\r\n1. e4 {my note} e5 *';
const _second = '[Event "Second"]\n\n1. d4 (1. c4 e5) d5 *';

void main() {
  test('patches a batch in source order preserving untouched text', () {
    const source = '\uFEFF; My banner\r\n\r\n  $_first\r\n\r\n\t$_second\n  ';
    final first = _first.replaceFirst('my note', 'new note');
    final second = _second.replaceFirst('Second', 'Renamed');
    expect(
      patchPgnDocument(source, {_second: second, _first: first}),
      '\uFEFF; My banner\r\n\r\n  $first\r\n\r\n\t$second\n  ',
    );
    expect(
      patchPgnDocument(source, {_first: first}),
      '\uFEFF; My banner\r\n\r\n  $first\r\n\r\n\t$_second\n  ',
    );
  });

  test('rejects missing, changed and duplicated source games', () {
    for (final source in [
      _second,
      _first.replaceFirst('my note', 'external edit'),
      '$_first\n\n$_first',
    ]) {
      expect(
        () => patchPgnDocument(source, {_first: _second}),
        throwsStateError,
      );
    }
  });

  test('matches original ranges, without cascading replacement text', () {
    expect(
      patchPgnDocument('$_first\n\n$_second', {
        _first: _second,
        _second: _first,
      }),
      '$_second\n\n$_first',
    );
  });

  test('rejects conflicting edits with whitespace-equivalent source keys', () {
    expect(
      () => patchPgnDocument(_first, {
        _first: _second,
        ' $_first ': '$_second\n{another edit}',
      }),
      throwsStateError,
    );
  });

  test('does not replace a game-shaped substring inside another game', () {
    const short = '[Event "First"]\n1. e4 *';
    const longer = '$short {keep this trailing comment}';
    expect(
      patchPgnDocument('$longer\n\n$short', {short: _second}),
      '$longer\n\n$_second',
    );
  });

  test('no-op edits preserve the exact source including bare text', () {
    const bare = '\uFEFF  1. e4 e5 *\n';
    expect(patchPgnDocument(bare, {bare: bare.trim()}), bare);
  });

  test('large course autosave leaves the calling isolate responsive', () async {
    final note = List.filled(
      40,
      'A course note with curly quotes “like this”.',
    ).join(' ');
    final originals = [
      for (var i = 0; i < 1821; i++)
        '[Event "Chapter $i"]\r\n[Result "*"]\r\n\r\n1. d4 Nf6 {$note} *',
    ];
    final replacements = {
      for (final game in originals)
        game: game.replaceFirst('[Result', '[ECO "A45"]\r\n[Result'),
    };
    var ticks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => ticks++,
    );
    try {
      final output = await patchPgnDocumentAsync(
        originals.join('\r\n\r\n'),
        replacements,
      );
      expect(ticks, greaterThan(0), reason: 'UI timers run during the worker');
      expect(output == replacements.values.join('\r\n\r\n'), isTrue);
    } finally {
      timer.cancel();
    }
  }, timeout: const Timeout(Duration(seconds: 20)));
}
