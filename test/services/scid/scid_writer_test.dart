/// [ScidWriter] end to end: write a `.si5/.sg5/.sn5` set from PGN and check
/// the three files against the ones Scid itself produced from the same input.
///
/// The index and game files must match byte for byte. The name file is
/// allowed to differ in *entry order* — Scid appends names as its importer
/// meets them and we append as ours does — so it is compared as a set of
/// (type, name) entries plus the ids the index records actually reference.
library;

import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:chess_auto_prep/services/scid/scid_index_entry.dart';
import 'package:chess_auto_prep/services/scid/scid_namebase.dart';
import 'package:chess_auto_prep/services/scid/scid_writer.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _dir = 'test/services/scid/fixtures';

List<PgnGame<PgnNodeData>> _games() =>
    PgnGame.parseMultiGamePgn(io.File('$_dir/fixture.pgn').readAsStringSync());

/// Decode a `.sn5` back into its (type, name) entries.
List<(int, String)> _parseNameBase(Uint8List bytes) {
  final out = <(int, String)>[];
  var i = 0;
  while (i < bytes.length) {
    var value = 0;
    var shift = 0;
    while (i < bytes.length) {
      final b = bytes[i++];
      value |= (b & 0x7F) << shift;
      if (b < 0x80) break;
      shift += 7;
    }
    final type = value & 0x7;
    final len = value >> 3;
    if (i + len > bytes.length) break;
    out.add((
      type,
      utf8.decode(bytes.sublist(i, i + len), allowMalformed: true),
    ));
    i += len;
  }
  return out;
}

void main() {
  late io.Directory tmp;

  setUp(() async {
    tmp = await io.Directory.systemTemp.createTemp('scid_writer_test');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<ScidWriteResult> writeFixture() => ScidWriter.write(
    directory: tmp.path,
    name: 'out',
    games: Stream.fromIterable(_games()),
  );

  test('writes the three files Scid expects', () async {
    final res = await writeFixture();
    expect(res.games, 5);
    expect(res.skipped, isEmpty);
    expect(res.truncated, isEmpty);
    for (final path in res.paths) {
      expect(await io.File(path).exists(), isTrue, reason: path);
    }
    expect(res.indexPath, endsWith('out.si5'));
    expect(res.gamePath, endsWith('out.sg5'));
    expect(res.namePath, endsWith('out.sn5'));
  });

  test('the index is exactly one 56-byte record per game', () async {
    final res = await writeFixture();
    final len = await io.File(res.indexPath).length();
    expect(len, 5 * ScidIndexEntry.recordSizeV5);
    expect(
      len,
      await io.File('$_dir/ref5.si5').length(),
      reason: 'Scid wrote the same number of records for this input',
    );
  });

  /// Every field except one: Scid classifies each game against its table of
  /// 255 stored opening lines and puts the code in the high byte of word 10.
  /// We write 0 there, which Scid reads as "unclassified — check this game
  /// properly", so its searches stay correct, just without that shortcut.
  test(
    'the index matches Scid byte for byte, bar the stored-line code',
    () async {
      final res = await writeFixture();
      final ours = await io.File(res.indexPath).readAsBytes();
      final theirs = await io.File('$_dir/ref5.si5').readAsBytes();
      expect(ours, hasLength(theirs.length));

      const storedLineByte = 43; // word 10's high byte, little-endian
      for (var rec = 0; rec * 56 < ours.length; rec++) {
        for (var i = 0; i < 56; i++) {
          final at = rec * 56 + i;
          if (i == storedLineByte) {
            expect(ours[at], 0, reason: 'we always write "unclassified"');
            continue;
          }
          expect(
            ours[at],
            theirs[at],
            reason: 'record $rec byte $i differs from Scid',
          );
        }
      }
    },
  );

  test('the game data matches Scid byte for byte', () async {
    final res = await writeFixture();
    final ours = await io.File(res.gamePath).readAsBytes();
    final theirs = await io.File('$_dir/ref5.sg5').readAsBytes();
    expect(ours, orderedEquals(theirs));
  });

  test('the namebase holds the same names Scid recorded', () async {
    final res = await writeFixture();
    final ours = _parseNameBase(
      await io.File(res.namePath).readAsBytes(),
    ).where((e) => e.$1 != ScidNameType.dbInfo).toSet();
    final theirs = _parseNameBase(
      await io.File('$_dir/ref5.sn5').readAsBytes(),
    ).where((e) => e.$1 != ScidNameType.dbInfo).toSet();
    expect(ours, theirs);
  });

  group('robustness', () {
    test('an empty stream still produces a valid empty database', () async {
      final res = await ScidWriter.write(
        directory: tmp.path,
        name: 'empty',
        games: const Stream.empty(),
      );
      expect(res.games, 0);
      expect(await io.File(res.indexPath).length(), 0);
      expect(await io.File(res.gamePath).length(), 0);
    });

    test('a game with an illegal move is written but reported', () async {
      const pgn =
          '[Event "Bad"]\n[White "A"]\n[Black "B"]\n[Result "*"]\n\n'
          '1. e4 e5 2. Qa8 *\n'; // valid SAN, unreachable square
      final res = await ScidWriter.write(
        directory: tmp.path,
        name: 'bad',
        games: Stream.fromIterable(PgnGame.parseMultiGamePgn(pgn)),
      );
      expect(res.games, 1, reason: 'the legal prefix is still worth keeping');
      expect(res.truncated, hasLength(1));
      expect(res.truncated.single, contains('Qa8'));
    });

    test(
      'the name is sanitised into something every platform accepts',
      () async {
        final res = await ScidWriter.write(
          directory: tmp.path,
          name: 'my/../weird name*?',
          games: Stream.fromIterable(_games()),
        );
        expect(res.indexPath, endsWith('myweird-name.si5'));
      },
    );

    test('an existing database is never overwritten', () async {
      final existing = <String, io.File>{
        for (final extension in ['si5', 'sg5', 'sn5'])
          extension: io.File('${tmp.path}/out.$extension')
            ..writeAsStringSync('original-$extension'),
      };

      await expectLater(writeFixture(), throwsA(isA<io.FileSystemException>()));

      for (final entry in existing.entries) {
        expect(
          entry.value.readAsStringSync(),
          'original-${entry.key}',
          reason: entry.value.path,
        );
      }
      expect(
        tmp.listSync().where((entry) => entry.path.endsWith('.tmp')),
        isEmpty,
      );
    });

    test(
      'a failed input stream leaves no partial database or temp file',
      () async {
        await expectLater(
          ScidWriter.write(
            directory: tmp.path,
            name: 'failed',
            games: Stream<PgnGame<PgnNodeData>>.error(StateError('injected')),
          ),
          throwsStateError,
        );

        expect(
          tmp.listSync().where(
            (entry) => entry.path.contains('${p.separator}failed.'),
          ),
          isEmpty,
        );
      },
    );

    test('an interrupted write leaves no database behind', () async {
      var seen = 0;
      final res = await ScidWriter.write(
        directory: tmp.path,
        name: 'partial',
        games: Stream.fromIterable(_games()),
        isCancelled: () => ++seen > 2,
      );
      // Cancellation stops adding games; what was written is still a
      // consistent database rather than a truncated one.
      expect(res.games, lessThan(5));
      expect(
        await io.File(res.indexPath).length(),
        res.games * ScidIndexEntry.recordSizeV5,
      );
    });
  });

  group('field encodings', () {
    test('dates pack as year<<9 | month<<5 | day', () {
      expect(scidDate('2021.08.17'), (2021 << 9) | (8 << 5) | 17);
      expect(scidDate('2021.??.??'), 2021 << 9);
      expect(scidDate(null), 0);
      expect(scidDate('????.??.??'), 0);
    });

    test('ECO codes follow Scid\'s 131-per-code numbering', () {
      expect(scidEco('A00'), 1);
      expect(scidEco('A01'), 132);
      expect(scidEco(null), 0);
      expect(scidEco(''), 0);
      expect(scidEco('Z99'), 0, reason: 'only A-E are ECO letters');
      expect(scidEco('a00'), 1, reason: 'case-insensitive, as Scid is');
    });

    test('results map to Scid\'s codes', () {
      expect(ScidResult.fromPgn('1-0'), ScidResult.white);
      expect(ScidResult.fromPgn('0-1'), ScidResult.black);
      expect(ScidResult.fromPgn('1/2-1/2'), ScidResult.draw);
      expect(ScidResult.fromPgn('*'), ScidResult.none);
      expect(ScidResult.fromPgn(null), ScidResult.none);
    });

    test('annotation counts round to Scid\'s 16 buckets', () {
      expect(scidCountRating(0), 0);
      expect(scidCountRating(10), 10);
      expect(scidCountRating(12), 10, reason: '12 is nearest 10');
      expect(scidCountRating(16), 11, reason: '16 rounds to the 15 bucket');
      expect(scidCountRating(26), 13, reason: '26 rounds to the 30 bucket');
      expect(scidCountRating(1000), 15, reason: 'saturates at the 50 bucket');
    });
  });
}
