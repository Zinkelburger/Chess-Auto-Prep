import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/compound_commit.dart';
import 'package:chess_auto_prep/v2/storage/compound_write.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/file_relocation.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/relocation_notes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  for (final relocation in [false, true]) {
    final kind = relocation ? 'relocation' : 'compound';
    for (final pair in [
      ('prepared', 'complete'),
      ('committing', 'complete'),
      ('complete', 'complete'),
      ('cancelled', 'complete'),
      ('prepared', 'committing'),
      ('cancelled', 'prepared'),
      ('prepared', 'cancelled'),
    ]) {
      test(
        '$kind retains verified ${pair.$1} copy beside ${pair.$2}',
        () async {
          final f = await _Fixture.create(relocation, pair.$2);
          addTearDown(f.disk.dispose);
          final prior = {...await f.metadata(), 'state': pair.$1};
          final copy = await f.copy(prior);
          final bytes = await copy.readAsBytes();
          await f.recover();
          await f.recover();
          expect(await copy.readAsBytes(), bytes);
          expect(
            (await f.metadata())['state'],
            pair.$2 == 'prepared'
                ? 'cancelled'
                : pair.$2 == 'committing'
                ? 'complete'
                : pair.$2,
          );
        },
      );
    }
    for (final error in [
      'missing current',
      'wrong id',
      'wrong payload',
      'unknown old phase',
      'unknown current phase',
      'backward phase',
      'malformed',
      'linked copy',
      'bad suffix',
      'invalid current',
    ]) {
      test(
        '$kind refuses $error recovery copy without changing evidence',
        () async {
          final state = error == 'backward phase' ? 'prepared' : 'complete';
          final f = await _Fixture.create(relocation, state);
          addTearDown(f.disk.dispose);
          final prior = {...await f.metadata(), 'state': 'prepared'};
          switch (error) {
            case 'wrong id':
              prior['id'] = 'another';
            case 'wrong payload':
              prior[relocation ? 'identity' : 'documentBefore'] = 'different';
            case 'unknown old phase':
              prior['state'] = 'invented';
            case 'backward phase':
              prior['state'] = 'committing';
          }
          final copy = await f.copy(
            prior,
            suffix: error == 'bad suffix' ? '0-100' : '123-100',
          );
          if (error == 'malformed') await copy.writeAsString('{');
          if (error == 'missing current') await f.note.delete();
          if (error == 'unknown current phase' || error == 'invalid current') {
            final current = await f.metadata();
            current[error == 'invalid current' ? 'version' : 'state'] =
                error == 'invalid current' ? 2 : 'invented';
            await f.note.writeAsString(jsonEncode(current));
          }
          if (error == 'linked copy') {
            final elsewhere = File(p.join(f.disk.root.path, 'linked.json'));
            await copy.rename(elsewhere.path);
            await Link(copy.path).create(elsewhere.path);
          }
          final bytes = await copy.readAsBytes();
          await expectLater(f.recover(), throwsA(isA<RecoveryRequired>()));
          expect(await copy.readAsBytes(), bytes);
        },
        skip: !Platform.isLinux,
      );
    }
  }
}

final class _Fixture {
  _Fixture(this.disk, this.relocation, this.note);
  final StoreFixture disk;
  final bool relocation;
  final File note;
  static const id = 'copy-proof';
  Future<Map<String, Object?>> metadata() async =>
      jsonDecode(await note.readAsString()) as Map<String, Object?>;
  Future<File> copy(Map<String, Object?> value, {String suffix = '123-100'}) =>
      File(
        p.join(note.parent.path, '.$id.json.v2-tmp.previous-$suffix'),
      ).writeAsString(jsonEncode(value));
  Future<void> recover() => relocation
      ? FileRelocations(
          documents: disk.documents,
          support: disk.support,
        ).recover()
      : CompoundWrites(
          documents: disk.documents,
          support: disk.support,
        ).recover();

  static Future<_Fixture> create(bool relocation, String state) async {
    final disk = await StoreFixture.create();
    final from = disk.ref('repertoires/Course.pgn');
    final revision = await disk.put(from, '1. e4 *');
    final stop = state == 'complete'
        ? null
        : state == 'committing'
        ? 'intent'
        : 'prepared';
    Future<void> hook(String step) async {
      if (step == stop) throw StateError('simulated crash');
    }

    if (relocation) {
      final result =
          await FileRelocations(
            documents: disk.documents,
            support: disk.support,
            testHook: (step) => hook(step.name),
          ).move(
            from,
            DocumentRef(p.join(p.dirname(from.path), 'Moved.pgn')),
            expected: revision,
            operationId: id,
          );
      expect(result, state == 'complete' ? isA<Moved>() : isA<IoFailure>());
    } else {
      final writing =
          CompoundWrites(
            documents: disk.documents,
            support: disk.support,
            testHook: (step) => hook(step.name),
          ).commit(
            CompoundCommit(
              id: id,
              documentPath: from.path,
              documentBefore: '1. e4 *',
              documentAfter: '1. d4 *',
              booksBefore: null,
              booksAfter: '{"version":1,"books":[]}',
            ),
          );
      if (stop == null) {
        await writing;
      } else {
        await expectLater(writing, throwsStateError);
      }
    }
    final f = _Fixture(
      disk,
      relocation,
      File(
        p.join(
          disk.support.path,
          relocation ? 'relocation-writes' : 'compound-writes',
          '$id.json',
        ),
      ),
    );
    if (state == 'cancelled') await f.recover();
    return f;
  }
}
