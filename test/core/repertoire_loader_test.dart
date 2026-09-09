/// Direct tests for the repertoire load path's pure pieces —
/// [parseRepertoireHeaders], [upsertMetadataComment] — and for
/// [RepertoireLoader.build] as a value-producing function.
///
/// `repertoire_load_test.dart` covers the same code through
/// `RepertoireController`; these pin the header grammar (line endings, BOM,
/// casing, where the block may live) and what a partly broken PGN yields.
library;

import 'package:chess_auto_prep/core/repertoire_loader.dart';
import 'package:chess_auto_prep/services/pgn_parsing_service.dart' as pgn;
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStorage implements StorageService {
  final Map<String, String> files = {};

  @override
  Future<bool> fileExists(String path) async => files.containsKey(path);

  @override
  Future<String?> readFile(String path) async => files[path];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

const _game = '[Event "A"]\n[Result "*"]\n\n1. e4 e5 *\n';

void main() {
  group('parseRepertoireHeaders', () {
    test('reads the colour and root block above the first game', () {
      final h = parseRepertoireHeaders(
        '// Color: Black\n// Root: 1. d4 Nf6\n\n$_game',
      );
      expect(h.isWhite, isFalse);
      expect(h.rootMoves, '1. d4 Nf6');
      expect(h.needsColorSelection, isFalse);
    });

    test('a missing block with no hint asks for the colour', () {
      final h = parseRepertoireHeaders(_game);
      expect(h.isWhite, isTrue);
      expect(h.rootMoves, '');
      expect(h.needsColorSelection, isTrue);
    });

    test('infers the side from a "Repertoire for Black" title', () {
      final h = parseRepertoireHeaders(
        '[Event "KID: Repertoire for Black"]\n[Result "*"]\n\n1. d4 Nf6 *\n',
      );
      expect(h.isWhite, isFalse);
      expect(h.needsColorSelection, isFalse);
    });

    test('a title naming both sides is not evidence', () {
      final h = parseRepertoireHeaders(
        '[Event "Playing for White and for Black"]\n\n1. e4 *\n',
      );
      expect(h.isWhite, isTrue);
      expect(h.needsColorSelection, isTrue);
    });

    test('the explicit comment wins over the title', () {
      final h = parseRepertoireHeaders(
        '// Color: White\n[Event "Repertoire for Black"]\n\n1. e4 *\n',
      );
      expect(h.isWhite, isTrue);
      expect(h.needsColorSelection, isFalse);
    });

    test('a block below the first game is not read', () {
      // upsertMetadataComment always writes above the first [Event]; a
      // comment that drifted below it is invisible to the loader.
      final h = parseRepertoireHeaders('$_game// Color: Black\n');
      expect(h.isWhite, isTrue);
      expect(h.needsColorSelection, isTrue);
    });

    test('survives a BOM and Windows line endings', () {
      final h = parseRepertoireHeaders(
        '\uFEFF// Color: Black\r\n// Root: 1. d4\r\n\r\n'
        '[Event "A"]\r\n\r\n1. d4 *\r\n',
      );
      expect(h.isWhite, isFalse);
      expect(h.rootMoves, '1. d4', reason: 'no stray CR on the root');
      expect(h.needsColorSelection, isFalse);
    });

    test('agrees with extractRepertoireColor on a lower-case colour', () {
      // Every reader of `// Color:` outside the Builder goes through
      // extractRepertoireColor, which is case-insensitive. A hand-edited
      // `// Color: black` must not train as Black and build as White.
      const text = '// Color: black\n\n$_game';
      expect(pgn.extractRepertoireColor(text), 'black');
      final h = parseRepertoireHeaders(text);
      expect(h.isWhite, isFalse);
      expect(h.needsColorSelection, isFalse);
    });
  });

  group('upsertMetadataComment', () {
    test('replaces the existing line in place and drops duplicates', () {
      const content =
          '// Color: White\n// Root: 1. e4\n// Color: Black\n\n$_game';
      final out = upsertMetadataComment(content, '// Color:', 'Black');
      final lines = out.split('\n');
      expect(lines.where((l) => l.startsWith('// Color:')), hasLength(1));
      expect(lines[0], '// Color: Black');
      expect(lines[1], '// Root: 1. e4', reason: 'other metadata untouched');
      expect(out, endsWith(_game));
    });

    test('inserts above the first [Event], after a banner comment', () {
      const content = '// My repertoire\n// Created on 2026\n\n$_game';
      final out = upsertMetadataComment(content, '// Root:', '1. e4');
      final lines = out.split('\n');
      final rootIdx = lines.indexOf('// Root: 1. e4');
      final eventIdx = lines.indexWhere((l) => l.startsWith('[Event '));
      expect(rootIdx, 3, reason: 'directly above the first game');
      expect(eventIdx, rootIdx + 1);
      expect(lines.sublist(0, 3), [
        '// My repertoire',
        '// Created on 2026',
        '',
      ]);
    });

    test('a stray line below the first game is migrated above it', () {
      const content = '$_game// Color: Black\n';
      final out = upsertMetadataComment(content, '// Color:', 'White');
      expect(out.split('\n').where((l) => l.startsWith('// Color:')), [
        '// Color: White',
      ]);
      expect(out, startsWith('// Color: White\n[Event "A"]'));
      // What the writer wrote is what the loader reads back.
      expect(parseRepertoireHeaders(out).isWhite, isTrue);
      expect(parseRepertoireHeaders(out).needsColorSelection, isFalse);
    });

    test('round-trips through the loader on a CRLF file', () {
      const content = '[Event "A"]\r\n[Result "*"]\r\n\r\n1. e4 e5 *\r\n';
      final out = upsertMetadataComment(content, '// Root:', '1. e4 e5');
      final h = parseRepertoireHeaders(out);
      expect(h.rootMoves, '1. e4 e5');
      expect(out, contains('[Event "A"]\r\n'), reason: 'game text untouched');
    });

    test('does not treat a prefix-like word inside a tag as the line', () {
      const content = '[Event "// Color: joke"]\n\n1. e4 *\n';
      final out = upsertMetadataComment(content, '// Color:', 'Black');
      expect(out, startsWith('// Color: Black\n[Event "// Color: joke"]'));
    });
  });

  group('RepertoireLoader.read', () {
    late _MemoryStorage storage;
    setUp(() {
      storage = _MemoryStorage();
      StorageFactory.instanceForTest = storage;
    });
    tearDown(() => StorageFactory.instanceForTest = null);

    test('distinguishes a missing file from an empty one', () async {
      storage.files['/empty.pgn'] = '';
      final loader = RepertoireLoader();
      expect(await loader.read('/gone.pgn'), (exists: false, pgn: null));
      expect(await loader.read('/empty.pgn'), (exists: true, pgn: ''));
    });
  });

  group('RepertoireLoader.build', () {
    test('null and empty text yield an empty tree and no headers', () async {
      final loader = RepertoireLoader();
      for (final text in [null, '']) {
        final loaded = await loader.build(text, fallbackIsWhite: true);
        expect(loaded.pgn, text);
        expect(loaded.openingTree, isNotNull);
        expect(loaded.openingTree!.totalGames, 0);
        expect(loaded.lines, isEmpty);
        expect(loaded.headers, isNull);
      }
    });

    test(
      'a Black file parses its lines as Black and counts its games',
      () async {
        const text =
            '// Color: Black\n// Root: 1. d4 Nf6\n\n'
            '[Event "A"]\n[Result "*"]\n\n1. d4 Nf6 2. c4 g6 *\n\n'
            '[Event "B"]\n[Result "*"]\n\n1. d4 Nf6 2. c4 e6 *\n';
        final loaded = await RepertoireLoader().build(
          text,
          fallbackIsWhite: true,
        );
        expect(loaded.headers!.isWhite, isFalse);
        expect(loaded.headers!.rootMoves, '1. d4 Nf6');
        expect(loaded.openingTree!.totalGames, 2);
        expect(loaded.lines.map((l) => l.color).toSet(), {'black'});
        expect(loaded.lines.map((l) => l.moves.join(' ')), [
          'd4 Nf6 c4 g6',
          'd4 Nf6 c4 e6',
        ]);
      },
    );

    test('a BOM does not hide the colour block or the games', () async {
      const text = '\uFEFF// Color: Black\n\n$_game';
      final loaded = await RepertoireLoader().build(
        text,
        fallbackIsWhite: true,
      );
      expect(loaded.headers!.isWhite, isFalse);
      expect(loaded.headers!.needsColorSelection, isFalse);
      expect(loaded.lines, hasLength(1));
      expect(loaded.openingTree!.totalGames, 1);
    });

    test('one game with an illegal move does not sink the others', () async {
      const text =
          '// Color: White\n\n'
          '[Event "Bad"]\n[Result "*"]\n\n1. e4 e5 2. Ke2 Ke7 3. Qh5 *\n\n'
          '[Event "Good"]\n[Result "*"]\n\n1. e4 e5 2. Nf3 *\n';
      final loaded = await RepertoireLoader().build(
        text,
        fallbackIsWhite: true,
      );
      expect(loaded.headers, isNotNull);
      expect(loaded.openingTree, isNotNull);
      expect(loaded.lines.map((l) => l.moves.join(' ')), contains('e4 e5 Nf3'));
      // The illegal game is skipped by the tree builder, not the whole load.
      expect(loaded.openingTree!.totalGames, greaterThanOrEqualTo(1));
    });

    test('a game with no moves is not a line and not a tree game', () async {
      const text = '// Color: White\n\n[Event "Empty"]\n[Result "*"]\n\n*\n';
      final loaded = await RepertoireLoader().build(
        text,
        fallbackIsWhite: true,
      );
      expect(loaded.lines, isEmpty);
      expect(loaded.openingTree!.totalGames, 0);
    });
  });
}
