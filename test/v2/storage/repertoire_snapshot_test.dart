import 'dart:io';

import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/recovery_gate.dart';
import 'package:chess_auto_prep/v2/workspace/repertoire_shelf.dart';
import 'package:chess_auto_prep/v2/workspace/repertoire_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/scripted_store.dart';
import 'store_fixture.dart';

void main() {
  late StoreFixture disk;
  late ChapterDirectory files;
  late DocumentRef a;

  setUp(() async {
    disk = await StoreFixture.create();
    files = ChapterDirectory(
      Directory(p.join(disk.documents.path, 'repertoires')),
      recovery: disk.store.recovery,
    );
    a = disk.ref('repertoires/A/Main.pgn');
    await disk.put(a, oneGame('1. e4'));
  });
  tearDown(() => disk.dispose());

  Future<Repertoires> capture() async => await files.list() as Repertoires;

  test(
    'snapshot revisions and membership are immutable native observations',
    () async {
      final snapshot = await capture();
      final opened = await disk.store.open(a) as Opened;
      expect(snapshot.revisions.keys, [a.path]);
      expect(snapshot.revisions[a.path]!.nativeIdentity, isNotNull);
      expect(
        await files.validate(snapshot, observed: {a.path: opened.revision}),
        isA<RepertoireCurrent>(),
      );
      expect(() => snapshot.revisions.clear(), throwsUnsupportedError);
      expect(() => snapshot.folders.clear(), throwsUnsupportedError);
      expect(
        () => snapshot.folders.single.chapters.clear(),
        throwsUnsupportedError,
      );
    },
  );

  test('related corpus changes share the complete membership fence', () async {
    final corpus = disk.ref('games_library/lichess_player.pgn');
    await disk.put(corpus, oneGame('1. c4'));
    final before = (await disk.store.open(corpus) as Opened).revision;
    final snapshot = await capture();
    expect(
      await files.validate(
        snapshot,
        observed: const {},
        additional: {corpus.path: before},
      ),
      isA<RepertoireCurrent>(),
    );
    await File(corpus.path).writeAsString(oneGame('1. d4'));
    expect(
      await files.validate(
        snapshot,
        observed: const {},
        additional: {corpus.path: before},
      ),
      isA<RepertoireChanged>(),
    );
  });

  test('a formerly absent corpus is part of the same read set', () async {
    final corpus = disk.ref('games_library/lichess_player.pgn');
    final snapshot = await capture();
    expect(
      await files.validate(
        snapshot,
        observed: const {},
        additional: {corpus.path: null},
      ),
      isA<RepertoireCurrent>(),
    );
    await disk.put(corpus, oneGame('1. c4'));
    expect(
      await files.validate(
        snapshot,
        observed: const {},
        additional: {corpus.path: null},
      ),
      isA<RepertoireChanged>(),
    );
  });

  test('unreadable related PGNs are not proof of absence', () async {
    final corpus = Directory(
      p.join(disk.documents.path, 'games_library', 'blocked.pgn'),
    );
    await corpus.create(recursive: true);
    final snapshot = await capture();
    expect(
      await files.validate(
        snapshot,
        observed: const {},
        additional: {corpus.path: null},
      ),
      isA<RepertoireValidationFailed>(),
    );
    expect(
      await files.validate(
        snapshot,
        observed: const {},
        additional: {p.join(disk.root.path, 'outside.pgn'): null},
      ),
      isA<RepertoireValidationFailed>(),
    );
  });

  test(
    'related PGNs cannot escape the held profile through a linked folder',
    () async {
      final external = await Directory(
        p.join(disk.root.path, 'external-games'),
      ).create();
      await File(
        p.join(external.path, 'player.pgn'),
      ).writeAsString(oneGame('1. c4'));
      final alias = p.join(disk.documents.path, 'games_library');
      await Link(alias).create(external.path);
      final corpus = DocumentRef(p.join(alias, 'player.pgn'));
      final revision = await disk.revisionOf(corpus);
      final snapshot = await capture();
      expect(
        await files.validate(
          snapshot,
          observed: const {},
          additional: {corpus.path: revision},
        ),
        isA<RepertoireValidationFailed>(),
      );
    },
    skip: !Platform.isLinux,
  );

  test(
    'a configured Documents alias still accepts its own related PGNs',
    () async {
      final corpus = disk.ref('games_library/player.pgn');
      await disk.put(corpus, oneGame('1. c4'));
      final alias = Directory(p.join(disk.root.path, 'Documents-alias'));
      await Link(alias.path).create(disk.documents.path);
      final aliasFiles = ChapterDirectory(
        Directory(p.join(alias.path, 'repertoires')),
        recovery: RecoveryGate(documents: alias, support: disk.support),
      );
      final corpusAlias = DocumentRef(
        p.join(alias.path, 'games_library', 'player.pgn'),
      );
      final revision = await disk.revisionOf(corpusAlias);
      final snapshot = await aliasFiles.list() as Repertoires;
      expect(
        await aliasFiles.validate(
          snapshot,
          observed: const {},
          additional: {corpusAlias.path: revision},
        ),
        isA<RepertoireCurrent>(),
      );
    },
    skip: !Platform.isLinux,
  );

  test('new and deleted membership invalidate the complete read set', () async {
    final snapshot = await capture();
    final b = disk.ref('repertoires/B/Main.pgn');
    await disk.put(b, oneGame('1. d4'));
    expect(
      await files.validate(snapshot, observed: const {}),
      isA<RepertoireChanged>(),
    );
    final withBoth = await capture();
    await File(a.path).delete();
    expect(
      await files.validate(withBoth, observed: const {}),
      isA<RepertoireChanged>(),
    );
  });

  test('identical bytes at a reused path invalidate native identity', () async {
    final snapshot = await capture();
    final original = File(a.path);
    await original.rename('${a.path}.old');
    await File('${a.path}.old').copy(a.path);
    final after = await disk.revisionOf(a);
    expect(after, snapshot.revisions[a.path]);
    expect(
      after.nativeIdentity,
      isNot(snapshot.revisions[a.path]!.nativeIdentity),
    );
    expect(
      await files.validate(snapshot, observed: const {}),
      isA<RepertoireChanged>(),
    );
  });

  test('projection read must match the captured native revision', () async {
    final snapshot = await capture();
    final before = snapshot.revisions[a.path]!;
    final other = Revision(
      before.contentHash,
      nativeIdentity: 'another-object',
    );
    expect(
      await files.validate(snapshot, observed: {a.path: other}),
      isA<RepertoireChanged>(),
    );
  });

  test('draft and section metadata remain part of the read set', () async {
    final snapshot = await capture();
    await File(
      a.path,
    ).writeAsString('// Draft\n[Event "Line"]\n[ChapterName "New"]\n\n1. e4 *');
    expect(
      await files.validate(snapshot, observed: const {}),
      isA<RepertoireChanged>(),
    );
    final updated = await capture();
    expect(updated.folders.single.chapters.single.heading.draft, isTrue);
    expect(updated.folders.single.chapters.single.section, 'New');
  });

  for (final directory in [false, true]) {
    test(
      'a visible linked ${directory ? 'folder' : 'PGN'} preserves the last good view',
      () async {
        final catalog = RepertoireCatalog(files: files, root: files.root.path);
        addTearDown(catalog.dispose);
        final shelf = RepertoireShelf(files: files, documents: disk.store);
        await catalog.refresh();
        await shelf.read(gone: () => false);
        final previous = shelf.refs.single;
        final original = directory ? p.dirname(a.path) : a.path;
        final held = p.join(
          disk.root.path,
          directory ? 'kept-folder' : 'kept.pgn',
        );
        if (directory) {
          await Directory(original).rename(held);
        } else {
          await File(original).rename(held);
        }
        await Link(original).create(held);
        await catalog.refresh();
        shelf.forget();
        await shelf.read(gone: () => false);
        expect(catalog.repertoires.single.chapters.single, previous);
        expect(catalog.stale, isTrue);
        expect(catalog.problem, isNotNull);
        expect(shelf.refs, [previous]);
        expect(shelf.stale, isTrue);
        expect(shelf.problem, isNotNull);
      },
      skip: !Platform.isLinux,
    );
  }

  test('a PGN that is not UTF-8 still lists under its file name', () async {
    await File(a.path).writeAsBytes([0xff, 0xfe, 0xff]);
    final listing = await files.list() as Repertoires;
    expect(
      listing.folders.expand((folder) => folder.chapters).map((c) => c.name),
      contains(p.basenameWithoutExtension(a.path)),
    );
  });

  test(
    'native membership changed during final open is never published',
    () async {
      final reads = ScriptedDocumentStore();
      reads.documents[a] = await disk.store.open(a);
      final shelf = RepertoireShelf(files: files, documents: reads);
      await shelf.read(gone: () => false);
      final ref = shelf.refs.single;
      final previous = shelf.indexOf(ref);
      final version = shelf.version;
      shelf.forget();
      reads.hold = true;
      final rebuilding = shelf.read(gone: () => false);
      await _until(() => reads.waiting == 1);
      await disk.put(disk.ref('repertoires/B/Main.pgn'), oneGame('1. d4'));
      reads.releaseAll();
      await rebuilding;
      expect(shelf.refs, [ref]);
      expect(shelf.indexOf(ref), same(previous));
      expect(shelf.stale, isTrue);
      expect(shelf.problem, contains('changed'));
      expect(shelf.version, version);

      // A fresh native rebuild sees the complete new membership.
      final fresh = RepertoireShelf(files: files, documents: disk.store);
      await fresh.read(gone: () => false);
      expect(fresh.refs, hasLength(2));
      expect(fresh.stale, isFalse);
    },
  );
}

Future<void> _until(bool Function() ready) async {
  for (var attempt = 0; attempt < 200 && !ready(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(
    ready(),
    isTrue,
    reason: 'The expected asynchronous boundary was reached',
  );
}
