import 'dart:io';

import 'package:chess_auto_prep/v2/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/v2/storage/book_list.dart';
import 'package:chess_auto_prep/v2/storage/compound_write.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/v2/storage/reference_change.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  const before = '[Event "Line"]\n[ChapterName "A"]\n\n1. e4 *\n';
  const after = '[Event "Line"]\n[ChapterName "B"]\n\n1. e4 *\n';
  const external = '[Event "External"]\n\n1. d4 *\n';
  late StoreFixture disk;

  setUp(() async => disk = await StoreFixture.create());
  tearDown(() => disk.dispose());

  for (final alias in [false, true]) {
    for (final change in [
      'move',
      'delete',
      'replace',
      'link',
      'parentmove',
      'parentlink',
    ]) {
      test(
        'completed retry preserves later $change (root alias: $alias)',
        () async {
          final original = disk.ref('repertoires/Course/Course.pgn');
          final expected = await disk.put(original, before);
          final books = File(p.join(disk.support.path, 'books.json'));
          await books.writeAsString(
            BookList(
              active: 'one',
              books: [
                Book(
                  id: 'one',
                  name: 'Prep',
                  chapters: {BookChapter('Course/Course.pgn', 'A')},
                ),
              ],
            ).encode(),
          );
          final documents = alias
              ? Directory(p.join(disk.root.path, 'Documents-alias'))
              : disk.documents;
          if (alias) await Link(documents.path).create(disk.documents.path);
          final ref = DocumentRef(
            p.join(documents.path, 'repertoires', 'Course', 'Course.pgn'),
          );
          var fail = true;
          final store = PgnFileStore(
            documents: documents,
            support: disk.support,
            compoundHook: (step) async {
              if (fail && step == CompoundWriteStep.completed) {
                fail = false;
                throw StateError('lost final acknowledgement');
              }
            },
          );
          final scope = GamesEdited(
            GamesWritten(rewritten: {0}),
            references: ReferenceChanges([
              SectionRename(path: ref.path, from: 'A', to: 'B'),
            ]),
          );
          expect(
            await store.save(ref, after, expected: expected, scope: scope),
            isA<IoFailure>(),
          );
          final replacement = File(p.join(disk.root.path, 'external.pgn'));
          switch (change) {
            case 'move':
              await File(original.path).rename(replacement.path);
            case 'delete':
              await File(original.path).delete();
            case 'replace':
              await File(original.path).writeAsString(external);
            case 'parentmove' || 'parentlink':
              await Directory(
                p.dirname(original.path),
              ).rename(replacement.path);
              if (change == 'parentlink') {
                await Link(p.dirname(original.path)).create(replacement.path);
              }
            case 'link':
              await File(original.path).delete();
              await replacement.writeAsString(external);
              await Link(original.path).create(replacement.path);
          }
          final externalBooks = (await books.readAsString()).replaceFirst(
            'Prep',
            'External',
          );
          await books.writeAsString(externalBooks);
          for (var retry = 0; retry < 2; retry++) {
            final result = await store.save(
              ref,
              after,
              expected: expected,
              scope: scope,
            );
            if (change == 'parentlink') {
              expect(result, isA<IoFailure>());
              expect(
                await File(
                  p.join(replacement.path, 'Course.pgn'),
                ).readAsString(),
                after,
              );
              expect(await books.readAsString(), externalBooks);
              continue;
            }
            expect(result, isA<Saved>());
            expect(
              (result as Saved).receipt.compound!.documentPath,
              original.path,
            );
            expect(await books.readAsString(), externalBooks);
            switch (change) {
              case 'parentmove' || 'parentlink':
                expect(
                  await Directory(p.dirname(original.path)).exists(),
                  isFalse,
                );
                expect(
                  await File(
                    p.join(replacement.path, 'Course.pgn'),
                  ).readAsString(),
                  after,
                );
              case 'move':
                expect(await File(original.path).exists(), isFalse);
                expect(await replacement.readAsString(), after);
              case 'delete':
                expect(await File(original.path).exists(), isFalse);
              case 'replace':
                expect(await File(original.path).readAsString(), external);
              case 'link':
                expect(await Link(original.path).target(), replacement.path);
                expect(await replacement.readAsString(), external);
            }
          }
        },
        skip:
            Platform.isWindows &&
                (alias || change == 'link' || change == 'parentlink')
            ? 'symlink privileges not assumed'
            : false,
      );
    }
  }
}
