import 'dart:io';

import 'package:chess_auto_prep/v2/storage/book_file.dart';
import 'package:chess_auto_prep/v2/storage/book_list.dart';
import 'package:chess_auto_prep/v2/storage/book_snapshot.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/v2/storage/training_snapshot.dart';
import 'package:chess_auto_prep/v2/storage/training_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  late StoreFixture disk;
  late ChapterDirectory files;
  late BookFile books;
  late TrainingStore progress;
  late DocumentRef source;
  late Revision revision;

  setUp(() async {
    disk = await StoreFixture.create();
    files = ChapterDirectory(
      Directory(p.join(disk.documents.path, 'repertoires')),
      recovery: disk.store.recovery,
    );
    books = BookFile(disk.support, recovery: disk.store.recovery);
    progress = TrainingStore(disk.documents, support: disk.support);
    source = disk.ref('repertoires/Course/Main.pgn');
    await disk.put(source, '[Event "Main"]\n\n1. e4 *\n');
    revision = await disk.revisionOf(source);
  });
  tearDown(() => disk.dispose());

  Future<ProgressLoaded> training() async =>
      await progress.read({source.path}, observed: {source.path: revision})
          as ProgressLoaded;

  test(
    'one final fence validates inventory, books and all training inputs',
    () async {
      final listing = await files.list() as Repertoires;
      final book = await books.snapshot();
      final rows = await training();
      expect(rows.snapshot!.files.keys, unorderedEquals(trainingParticipants));
      expect(rows.snapshot!.files.values, everyElement(isNull));
      expect(
        await files.validate(
          listing,
          observed: rows.sources,
          book: book.source,
          training: rows.snapshot,
        ),
        isA<RepertoireCurrent>(),
      );
    },
  );

  for (final name in ['books.json', ...trainingParticipants]) {
    test('absent $name becoming present invalidates the entire read', () async {
      final listing = await files.list() as Repertoires;
      final book = await books.snapshot();
      final rows = await training();
      final root = name == 'books.json' ? disk.support : disk.documents;
      await File(p.join(root.path, name)).writeAsString('');
      expect(
        await files.validate(
          listing,
          observed: rows.sources,
          book: book.source,
          training: rows.snapshot,
        ),
        isA<RepertoireChanged>(),
      );
    });
  }

  test('same-byte book replacement does not satisfy native proof', () async {
    await books.snapshot();
    final written = await books.write(BookList.empty);
    final path = p.join(disk.support.path, 'books.json');
    final replacement = File('$path.replacement');
    await replacement.writeAsBytes(await File(path).readAsBytes());
    await replacement.rename(path);
    expect(
      await files.validate(
        null,
        observed: {source.path: revision},
        book: written.source,
      ),
      isA<RepertoireChanged>(),
    );
  });

  test('a linked profile input is unavailable instead of followed', () async {
    await books.snapshot();
    final written = await books.write(BookList.empty);
    final path = p.join(disk.support.path, 'books.json');
    await File(path).rename('$path.kept');
    await Link(path).create('$path.kept');
    expect(
      await files.validate(
        null,
        observed: {source.path: revision},
        book: written.source,
      ),
      isA<RepertoireValidationFailed>(),
    );
  });

  test('a proof cannot redirect the fixed profile participant', () async {
    final outside = Directory(p.join(disk.root.path, 'unrelated'));
    await outside.create();
    final forged = BookSource(
      supportPath: outside.path,
      canonicalSupport: outside.path,
      revision: null,
    );
    expect(
      await files.validate(
        null,
        observed: {source.path: revision},
        book: forged,
      ),
      isA<RepertoireChanged>(),
    );
  });

  test(
    'single-chapter proof excludes unrelated membership but binds its source',
    () async {
      final rows = await training();
      await disk.put(
        disk.ref('repertoires/Other/Main.pgn'),
        '[Event "Other"]\n\n1. d4 *\n',
      );
      expect(
        await files.validate(
          null,
          observed: rows.sources,
          training: rows.snapshot,
        ),
        isA<RepertoireCurrent>(),
      );
      await File(source.path).writeAsString('[Event "Changed"]\n\n1. c4 *\n');
      expect(
        await files.validate(
          null,
          observed: rows.sources,
          training: rows.snapshot,
        ),
        isA<RepertoireChanged>(),
      );
    },
  );

  test(
    'shared Documents and Support roots complete without nested locking',
    () async {
      final store = PgnFileStore(
        documents: disk.documents,
        support: disk.documents,
      );
      final directory = ChapterDirectory(files.root, recovery: store.recovery);
      final book = await BookFile(
        disk.documents,
        recovery: store.recovery,
      ).snapshot();
      final rows =
          await TrainingStore(
                disk.documents,
                support: disk.documents,
              ).read({source.path}, observed: {source.path: revision})
              as ProgressLoaded;
      expect(
        await directory
            .validate(
              null,
              observed: rows.sources,
              book: book.source,
              training: rows.snapshot,
            )
            .timeout(const Duration(seconds: 5)),
        isA<RepertoireCurrent>(),
      );
    },
  );

  for (final name in trainingParticipants) {
    test('same-byte $name replacement invalidates its native proof', () async {
      final file = File(p.join(disk.documents.path, name));
      await file.writeAsString('');
      final captured = await training();
      final before = captured.snapshot!.files[name]!;
      final replacement = File('${file.path}.replacement');
      await replacement.writeAsBytes(await file.readAsBytes());
      await replacement.rename(file.path);
      final after = (await training()).snapshot!.files[name]!;
      expect(after.contentHash, before.contentHash);
      expect(after.nativeIdentity, isNot(before.nativeIdentity));
      expect(
        await files.validate(
          null,
          observed: captured.sources,
          training: captured.snapshot,
        ),
        isA<RepertoireChanged>(),
      );
    });
  }

  for (final malformed in ['missing', 'extra', 'substituted']) {
    test(
      'a $malformed participant map cannot certify a training read',
      () async {
        final captured = await training();
        final original = captured.snapshot!;
        final participants = Map<String, Revision?>.of(original.files);
        if (malformed != 'extra') {
          participants.remove(trainingParticipants.first);
        }
        if (malformed != 'missing') participants['unrelated.csv'] = null;
        final invalid = TrainingReadSet(
          documentsPath: original.documentsPath,
          canonicalDocuments: original.canonicalDocuments,
          files: participants,
        );
        expect(
          await files.validate(
            null,
            observed: captured.sources,
            training: invalid,
          ),
          isA<RepertoireChanged>(),
        );
      },
    );
  }

  Future<
    ({
      ChapterDirectory directory,
      Repertoires listing,
      BookSource book,
      ProgressLoaded rows,
      Directory documents,
      Directory support,
    })
  >
  aliasedProfile() async {
    final documents = Directory(p.join(disk.root.path, 'Documents-alias'));
    final support = Directory(p.join(disk.root.path, 'Support-alias'));
    await Link(documents.path).create(disk.documents.path);
    await Link(support.path).create(disk.support.path);
    final store = PgnFileStore(documents: documents, support: support);
    final directory = ChapterDirectory(
      Directory(p.join(documents.path, 'repertoires')),
      recovery: store.recovery,
    );
    final listing = await directory.list() as Repertoires;
    final book = await BookFile(support, recovery: store.recovery).snapshot();
    final path = p.join(documents.path, 'repertoires', 'Course', 'Main.pgn');
    final observed = await disk.revisionOf(DocumentRef(path));
    final rows =
        await TrainingStore(
              documents,
              support: support,
            ).read({path}, observed: {path: observed})
            as ProgressLoaded;
    return (
      directory: directory,
      listing: listing,
      book: book.source!,
      rows: rows,
      documents: documents,
      support: support,
    );
  }

  test('configured aliases validate the complete native profile', () async {
    final profile = await aliasedProfile();
    expect(profile.book.supportPath, profile.support.path);
    expect(profile.book.canonicalSupport, disk.support.path);
    expect(profile.rows.snapshot!.documentsPath, profile.documents.path);
    expect(profile.rows.snapshot!.canonicalDocuments, disk.documents.path);
    expect(
      await profile.directory.validate(
        profile.listing,
        observed: profile.rows.sources,
        book: profile.book,
        training: profile.rows.snapshot,
      ),
      isA<RepertoireCurrent>(),
    );
  }, skip: !Platform.isLinux);

  for (final name in ['Documents', 'Support']) {
    test('retargeted $name alias cannot certify the old profile', () async {
      final profile = await aliasedProfile();
      final alias = name == 'Documents' ? profile.documents : profile.support;
      final original = name == 'Documents' ? disk.documents : disk.support;
      final outside = await Directory(
        p.join(disk.root.path, 'Elsewhere'),
      ).create();
      await Link(alias.path).update(outside.path);
      final refused = await profile.directory.validate(
        profile.listing,
        observed: profile.rows.sources,
        book: profile.book,
        training: profile.rows.snapshot,
      );
      expect(
        refused,
        anyOf(isA<RepertoireChanged>(), isA<RepertoireValidationFailed>()),
      );
      expect(await File(p.join(outside.path, 'books.json')).exists(), isFalse);
      expect(
        await File(p.join(outside.path, trainingParticipants.first)).exists(),
        isFalse,
      );
      await Link(alias.path).update(original.path);
      expect(
        await profile.directory.validate(
          profile.listing,
          observed: profile.rows.sources,
          book: profile.book,
          training: profile.rows.snapshot,
        ),
        isA<RepertoireCurrent>(),
      );
    }, skip: !Platform.isLinux);
  }
}
