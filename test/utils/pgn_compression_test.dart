/// Transparent gzip: a compressed PGN must open exactly like a plain one, and
/// a plain one must be untouched.
///
/// Detection is by the file's own magic bytes rather than its extension, so
/// these pin both directions — a gzipped file named `.pgn` opens, and a plain
/// file whose contents merely look unusual does not get mangled.
library;

import 'dart:convert';
import 'dart:io' as io;

import 'package:chess_auto_prep/utils/atomic_file.dart';
import 'package:chess_auto_prep/utils/file_text_reader.dart';
import 'package:chess_auto_prep/utils/pgn_compression.dart';
import 'package:flutter_test/flutter_test.dart';

const _pgn =
    '[Event "Test"]\n'
    '[White "A"]\n'
    '[Black "B"]\n'
    '[Result "1-0"]\n'
    '\n'
    '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 1-0\n';

void main() {
  late io.Directory tmp;

  setUp(() async {
    tmp = await io.Directory.systemTemp.createTemp('pgn_compression_test');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('detection', () {
    test('recognises a gzip member by its magic bytes', () {
      expect(looksGzipped(gzipBytes(utf8.encode(_pgn))), isTrue);
    });

    test('a plain PGN is not mistaken for one', () {
      expect(looksGzipped(utf8.encode(_pgn)), isFalse);
    });

    test('short input never trips the check', () {
      expect(looksGzipped(const []), isFalse);
      expect(looksGzipped(const [0x1f]), isFalse);
    });

    test('a file starting with 0x1f but not 0x8b is left alone', () {
      final odd = [0x1f, 0x41, 0x42];
      expect(looksGzipped(odd), isFalse);
      expect(maybeGunzip(odd), odd);
    });
  });

  group('round trip', () {
    test('gzip then gunzip returns the original bytes', () {
      final raw = utf8.encode(_pgn);
      expect(maybeGunzip(gzipBytes(raw)), raw);
    });

    test('plain bytes pass through untouched', () {
      final raw = utf8.encode(_pgn);
      expect(identical(maybeGunzip(raw), raw), isTrue);
    });

    test('corrupt gzip degrades to the raw bytes rather than throwing', () {
      final broken = [...gzipBytes(utf8.encode(_pgn)).take(20)];
      expect(() => maybeGunzip(broken), returnsNormally);
    });
  });

  group('the reader handles both forms', () {
    test('a plain .pgn reads as before', () async {
      final f = io.File('${tmp.path}/plain.pgn');
      await f.writeAsString(_pgn);
      expect(await readTextFile(f), _pgn);
      expect(readTextFileSync(f), _pgn);
    });

    test('a gzipped file named .pgn reads identically', () async {
      final f = io.File('${tmp.path}/packed.pgn');
      await f.writeAsBytes(gzipBytes(utf8.encode(_pgn)));
      expect(await readTextFile(f), _pgn);
      expect(readTextFileSync(f), _pgn);
    });

    test('a .pgn.gz reads identically', () async {
      final f = io.File('${tmp.path}/packed.pgn.gz');
      await f.writeAsBytes(gzipBytes(utf8.encode(_pgn)));
      expect(await readTextFile(f), _pgn);
    });

    test('latin-1 content still falls back after decompression', () async {
      // A player name with a non-UTF-8 byte, gzipped: the encoding fallback
      // has to run on the *decompressed* bytes, not the compressed ones.
      final latin = latin1.encode('[White "Réti"]\n\n1. Nf3 1-0\n');
      final f = io.File('${tmp.path}/latin.pgn');
      await f.writeAsBytes(gzipBytes(latin));
      expect(await readTextFile(f), contains('Réti'));
    });
  });

  group('savings', () {
    test('a realistic PGN compresses substantially', () {
      // Repetition is what makes PGN compress: the same tags over and over.
      final many = List.filled(200, _pgn).join();
      final raw = utf8.encode(many);
      final saving = compressionSavingOf(raw, gzipBytes(raw));
      expect(saving, greaterThan(0.8));
    });

    test('incompressible input reports no saving', () {
      final raw = gzipBytes(utf8.encode(_pgn)); // already compressed
      expect(compressionSavingOf(raw, gzipBytes(raw)), 0);
    });

    test('empty input reports no saving', () {
      expect(compressionSavingOf(const [], gzipBytes(const [])), 0);
    });
  });

  group('compaction survives editing', () {
    test('compacting shrinks the file and keeps it readable', () async {
      final f = io.File('${tmp.path}/big.pgn');
      await f.writeAsString(List.filled(200, _pgn).join());
      final before = await f.length();

      final saving = await compactTextFile(f);

      expect(saving, greaterThan(0.8));
      expect(await f.length(), lessThan(before));
      expect(await readTextFile(f), List.filled(200, _pgn).join());
    });

    test('compacting an already-compact file is a no-op', () async {
      final f = io.File('${tmp.path}/twice.pgn');
      await f.writeAsString(List.filled(50, _pgn).join());
      await compactTextFile(f);
      final once = await f.length();
      expect(await compactTextFile(f), 0);
      expect(await f.length(), once);
    });

    test('a rewrite keeps a compacted file compacted', () async {
      final f = io.File('${tmp.path}/edited.pgn');
      await f.writeAsString(List.filled(200, _pgn).join());
      await compactTextFile(f);

      // The app edits the file the way any service would.
      await writeTextFileAtomically(f, '$_pgn\n[Event "Added"]\n\n1. d4 *\n');

      final raw = await f.readAsBytes();
      expect(
        looksGzipped(raw),
        isTrue,
        reason: 'editing must not silently undo the user\'s saving',
      );
      expect(await readTextFile(f), contains('Added'));
    });

    test('a plain file stays plain when rewritten', () async {
      final f = io.File('${tmp.path}/plain2.pgn');
      await writeTextFileAtomically(f, _pgn);
      expect(looksGzipped(await f.readAsBytes()), isFalse);
      expect(await readTextFile(f), _pgn);
    });

    test('expanding restores plain text', () async {
      final f = io.File('${tmp.path}/back.pgn');
      await f.writeAsString(List.filled(50, _pgn).join());
      await compactTextFile(f);
      expect(await expandTextFile(f), isTrue);
      expect(looksGzipped(await f.readAsBytes()), isFalse);
      expect(await expandTextFile(f), isFalse, reason: 'already plain');
    });

    test('compacting a file that would not shrink leaves it alone', () async {
      final f = io.File('${tmp.path}/tiny.pgn');
      await f.writeAsBytes(gzipBytes(utf8.encode(_pgn)));
      expect(await compactTextFile(f), 0);
    });
  });
}
