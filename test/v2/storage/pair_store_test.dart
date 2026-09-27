import 'dart:io';

import 'package:chess_auto_prep/v2/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/v2/storage/compound_write.dart';
import 'package:chess_auto_prep/v2/storage/compound_commit.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/document_repository.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'store_fixture.dart';

void main() {
  late StoreFixture disk;
  late DocumentEdit source;
  late DocumentEdit target;
  final before = oneGame('1. e4');
  final after = oneGame('1. d4');
  setUp(() async {
    disk = await StoreFixture.create();
    Future<DocumentEdit> edit(String name) async {
      final ref = disk.ref('repertoires/$name/Main.pgn');
      await disk.put(ref, before);
      return DocumentEdit(
        ref: ref,
        text: after,
        expected: await disk.revisionOf(ref),
        scope: GamesEdited(GamesWritten(rewritten: {0})),
      );
    }

    source = await edit('Source');
    target = await edit('Target');
  });
  tearDown(() => disk.dispose());

  test('one receipt commits and undoes both files with both backups', () async {
    final result = await disk.store.savePair(
      source,
      target,
      operationId: 'pair',
    );
    expect(result, isA<Saved>());
    for (final edit in [source, target]) {
      expect(await File(edit.ref.path).readAsString(), after);
      expect(disk.keptTexts(edit.ref), [before]);
    }
    final receipt = (result as Saved).receipt;
    expect(receipt.committed.nativeIdentity, isNotNull);
    final undone = await disk.store.save(
      source.ref,
      receipt.before,
      expected: receipt.committed,
      scope: RestoredVersion(inverse: receipt.compound),
    );
    expect(undone, isA<Saved>());
    for (final edit in [source, target]) {
      expect(await File(edit.ref.path).readAsString(), before);
      expect(disk.keptTexts(edit.ref), [before, after]);
    }
  });

  for (final second in [false, true]) {
    test(
      'stale ${second ? 'target' : 'source'} changes neither participant',
      () async {
        final changed = second ? target : source;
        await File(changed.ref.path).writeAsString(oneGame('1. c4'));
        final result = await disk.store.savePair(
          source,
          target,
          operationId: 'stale',
        );
        expect(result, isA<Conflict>());
        expect(
          await File((second ? source : target).ref.path).readAsString(),
          before,
        );
        expect(disk.keptTexts(source.ref), isEmpty);
        expect(disk.keptTexts(target.ref), isEmpty);
      },
    );
  }

  test(
    'invalid secondary scope refuses before keeping or writing either file',
    () async {
      final invalid = DocumentEdit(
        ref: target.ref,
        text: target.text,
        expected: target.expected,
        scope: GamesEdited(GamesWritten()),
      );
      expect(
        await disk.store.savePair(source, invalid, operationId: 'scope'),
        isA<SaveRefused>(),
      );
      for (final edit in [source, target]) {
        expect(await File(edit.ref.path).readAsString(), before);
        expect(disk.keptTexts(edit.ref), isEmpty);
      }
    },
  );

  test(
    'equal-content replaced target fails its captured native observation',
    () async {
      await File(target.ref.path).rename('${target.ref.path}.kept');
      await File(target.ref.path).writeAsString(before);
      expect(
        await disk.store.savePair(source, target, operationId: 'identity'),
        isA<Conflict>(),
      );
      expect(await File(source.ref.path).readAsString(), before);
    },
  );

  test('undo refuses a changed target before changing source', () async {
    final saved =
        await disk.store.savePair(source, target, operationId: 'inverse')
            as Saved;
    await File(target.ref.path).writeAsString(oneGame('1. c4'));
    final result = await disk.store.save(
      source.ref,
      saved.receipt.before,
      expected: saved.receipt.committed,
      scope: RestoredVersion(inverse: saved.receipt.compound),
    );
    expect(result, isNot(isA<Saved>()));
    expect(await File(source.ref.path).readAsString(), after);
    expect(await File(target.ref.path).readAsString(), oneGame('1. c4'));
  });

  test(
    'a lost acknowledgement retries in the same process without replacing later data',
    () async {
      final interrupted = PgnFileStore(
        documents: disk.documents,
        support: disk.support,
        compoundHook: (step) async {
          if (step == CompoundWriteStep.completed)
            throw StateError('lost acknowledgement');
        },
      );
      expect(
        await interrupted.savePair(source, target, operationId: 'retry'),
        isA<IoFailure>(),
      );
      await File(source.ref.path).delete();
      await File(target.ref.path).writeAsString(oneGame('1. c4'));
      final retry = await interrupted.savePair(
        source,
        target,
        operationId: 'retry',
      );
      expect(retry, isA<Saved>());
      expect(await File(source.ref.path).exists(), isFalse);
      expect(await File(target.ref.path).readAsString(), oneGame('1. c4'));
      final changed = DocumentEdit(
        ref: target.ref,
        text: before,
        expected: target.expected,
        scope: target.scope,
      );
      expect(
        await interrupted.savePair(source, changed, operationId: 'retry'),
        isA<SaveRefused>(),
      );

      // Another store of the same profile in this process knows the save
      // finished too, and its retry changes nothing.
      expect(
        await disk.store.savePair(source, target, operationId: 'retry'),
        isA<Saved>(),
      );
      expect(await File(source.ref.path).exists(), isFalse);
      expect(await File(target.ref.path).readAsString(), oneGame('1. c4'));
    },
  );
  test(
    'configured root alias supports paired save and inverse backup ownership',
    () async {
      final alias = Directory('${disk.root.path}/alias');
      await Link(alias.path).create(disk.documents.path);
      final store = DocumentRepository(
        PgnFileStore(documents: alias, support: disk.support),
      );
      addTearDown(store.dispose);
      final paths = <String>[];
      store.addListener(() => paths.add(store.lastChange!.path));
      DocumentEdit aliased(DocumentEdit edit) => DocumentEdit(
        ref: DocumentRef(
          edit.ref.path.replaceFirst(disk.documents.path, alias.path),
        ),
        text: edit.text,
        expected: edit.expected,
        scope: edit.scope,
      );
      final result =
          await store.savePair(
                aliased(source),
                aliased(target),
                operationId: 'alias',
              )
              as Saved;
      expect(
        await store.save(
          aliased(source).ref,
          result.receipt.before,
          expected: result.receipt.committed,
          scope: RestoredVersion(inverse: result.receipt.compound),
        ),
        isA<Saved>(),
      );
      expect(paths, [
        aliased(source).ref.path,
        aliased(target).ref.path,
        aliased(source).ref.path,
        aliased(target).ref.path,
      ]);
      expect(await File(source.ref.path).readAsString(), before);
      expect(await File(target.ref.path).readAsString(), before);
    },
  );

  test('same file through distinct spellings is refused', () async {
    final duplicate = DocumentEdit(
      ref: source.ref,
      text: target.text,
      expected: source.expected,
      scope: target.scope,
    );
    expect(
      await disk.store.savePair(source, duplicate, operationId: 'same'),
      isA<SaveRefused>(),
    );
    expect(await File(source.ref.path).readAsString(), before);
    expect(disk.keptTexts(source.ref), isEmpty);
  });

  test(
    'pair undo sends both committed resource changes to observers',
    () async {
      final repository = DocumentRepository(disk.store);
      addTearDown(repository.dispose);
      final changes = <String>[];
      repository.addListener(() => changes.add(repository.lastChange!.path));
      final result =
          await repository.savePair(source, target, operationId: 'observed')
              as Saved;
      expect(changes, [source.ref.path, target.ref.path]);
      changes.clear();
      expect(
        await repository.save(
          source.ref,
          result.receipt.before,
          expected: result.receipt.committed,
          scope: RestoredVersion(inverse: result.receipt.compound),
        ),
        isA<Saved>(),
      );
      expect(changes, [source.ref.path, target.ref.path]);
    },
  );
  test(
    'a forged secondary inverse cannot restore an unrelated kept version',
    () async {
      final saved =
          await disk.store.savePair(source, target, operationId: 'auth')
              as Saved;
      final real = saved.receipt.compound!;
      final forged = CompoundCommit.pair(
        id: real.id,
        primary: real.primary,
        secondary: CompoundDocument(
          path: real.secondary!.path,
          before: oneGame('1. c4'),
          after: real.secondary!.after,
        ),
      );
      expect(
        await disk.store.save(
          source.ref,
          saved.receipt.before,
          expected: saved.receipt.committed,
          scope: RestoredVersion(inverse: forged),
        ),
        isA<RestoreRefused>(),
      );
      expect(await File(source.ref.path).readAsString(), after);
      expect(await File(target.ref.path).readAsString(), after);
    },
  );
}
