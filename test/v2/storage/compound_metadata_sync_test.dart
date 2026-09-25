@TestOn('linux || mac-os')
library;

import 'dart:io';

import 'package:chess_auto_prep/v2/storage/compound_commit.dart';
import 'package:chess_auto_prep/v2/storage/compound_write.dart';
import 'package:chess_auto_prep/v2/storage/relocation_notes.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'nested Support ancestry must settle before intent, including retry',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'compound-ancestry-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final root = Directory(await temporary.resolveSymbolicLinks());
      final documents = await Directory(
        p.join(root.path, 'Documents'),
      ).create();
      final support = Directory(p.join(root.path, 'new', 'nested', 'Support'));
      final document = await File(
        p.join(documents.path, 'Main.pgn'),
      ).writeAsString('1. e4 *');
      final flushed = <String>[];
      var fail = true;
      final engine = CompoundWrites(
        documents: documents,
        support: support,
        synchronize: (path) async {
          flushed.add(path);
          if (path == root.path && fail)
            throw FileSystemException('injected ancestor flush failure', path);
          await syncDirectory(path);
        },
      );
      final command = CompoundCommit(
        id: 'nested-support',
        documentPath: document.path,
        documentBefore: '1. e4 *',
        documentAfter: '1. d4 *',
        booksBefore: null,
        booksAfter: '{"version":1,"books":[]}',
      );
      final journal = File(
        p.join(support.path, 'compound-writes', '${command.id}.json'),
      );
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          engine.commit(command),
          throwsA(isA<RecoveryRequired>()),
        );
        expect(await document.readAsString(), '1. e4 *');
        expect(await journal.exists(), isFalse);
        expect(
          flushed.where((path) => path == root.path),
          hasLength(attempt + 1),
        );
      }
      fail = false;
      await engine.commit(command);
      expect(await document.readAsString(), '1. d4 *');
      expect(
        flushed,
        containsAll([
          support.path,
          support.parent.path,
          support.parent.parent.path,
          root.path,
        ]),
      );
      expect(flushed, isNot(contains(root.parent.path)));
    },
  );
}
