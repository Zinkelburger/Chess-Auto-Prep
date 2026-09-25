import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/file_relocation.dart';
import 'package:chess_auto_prep/v2/storage/training_rows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  late StoreFixture fixture;
  setUp(() async => fixture = await StoreFixture.create());
  tearDown(() => fixture.dispose());

  test('file move commits explicit book selectors before returning', () async {
    final from = fixture.ref('repertoires/Course/Main.pgn');
    final to = fixture.ref('repertoires/Course/Renamed.pgn');
    final revision = await fixture.put(from, oneGame('1. e4'));
    final books = File(p.join(fixture.support.path, 'books.json'));
    await books.writeAsString(
      jsonEncode({
        'version': 1,
        'active': 'book',
        'unknown': {'keep': true},
        'books': [
          {
            'id': 'book',
            'name': 'My book',
            'repertoires': <String>[],
            'chapters': [
              {'path': 'Course/Main.pgn', 'section': null, 'annotation': 7},
            ],
          },
        ],
      }),
    );
    expect(
      await fixture.store.move(from, to, expected: revision),
      isA<Moved>(),
    );
    final actual = jsonDecode(await books.readAsString()) as Map;
    expect(actual['books'][0]['chapters'][0], {
      'path': 'Course/Renamed.pgn',
      'section': null,
      'annotation': 7,
    });
    expect(actual['unknown'], {'keep': true});
    expect(await File(from.path).exists(), isFalse);
    expect(await File(to.path).readAsString(), oneGame('1. e4'));
  });

  test(
    'malformed last training participant refuses before the PGN moves',
    () async {
      final from = fixture.ref('repertoires/Course/Main.pgn');
      final to = fixture.ref('repertoires/Course/Renamed.pgn');
      final revision = await fixture.put(from, oneGame('1. e4'));
      final attempts = File(p.join(fixture.documents.path, attemptsFile));
      await attempts.writeAsString('not an accepted attempt\n');
      expect(
        await fixture.store.move(from, to, expected: revision),
        isA<IoFailure>(),
      );
      expect(await File(from.path).readAsString(), oneGame('1. e4'));
      expect(await File(to.path).exists(), isFalse);
      expect(await attempts.readAsString(), 'not an accepted attempt\n');
    },
  );
  test(
    'aliased training keys recover alongside canonical keys after a move',
    () async {
      final alias = Directory(p.join(fixture.root.path, 'Documents-alias'));
      await Link(alias.path).create(fixture.documents.path);
      final from = fixture.ref('repertoires/Course/Main.pgn');
      final to = fixture.ref('repertoires/Course/Renamed.pgn');
      final original = await fixture.put(from, oneGame('1. e4'));
      final aliasFrom = DocumentRef(
        p.join(alias.path, 'repertoires/Course/Main.pgn'),
      );
      final aliasTo = DocumentRef(
        p.join(alias.path, 'repertoires/Course/Renamed.pgn'),
      );
      final attempts = File(p.join(fixture.documents.path, attemptsFile));
      await attempts.writeAsString(
        [from.path, aliasFrom.path]
            .map((path) => jsonEncode({'repertoireId': path, 'keep': 7}))
            .join('\n'),
      );
      final interrupted = PgnFileStore(
        documents: alias,
        support: fixture.support,
        relocationHook: (step) async {
          if (step == FileRelocationStep.document)
            throw StateError('lost acknowledgement');
        },
      );
      expect(
        await interrupted.move(
          aliasFrom,
          aliasTo,
          expected: original,
          operationId: 'alias-move',
        ),
        isA<IoFailure>(),
      );
      // A canonical-root instance recovers the spelling captured by the first app.
      for (var restart = 0; restart < 2; restart++) {
        final reopened = PgnFileStore(
          documents: fixture.documents,
          support: fixture.support,
        );
        expect(await reopened.open(to), isA<Opened>());
        expect(
          (await attempts.readAsLines()).map(
            (line) => jsonDecode(line)['repertoireId'],
          ),
          [to.path, aliasTo.path],
        );
      }
      expect(await File(from.path).exists(), isFalse);
      // A finished move leaves no record behind.
      expect(
        await File(
          p.join(fixture.support.path, 'relocation-writes', 'alias-move.json'),
        ).exists(),
        isFalse,
      );
    },
    skip: !Platform.isLinux,
  );
}
