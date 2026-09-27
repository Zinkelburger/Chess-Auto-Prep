import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/repertoires/models/repertoire_publication.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/native_repertoire_publication_store.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/repertoire_directory_mutations.dart';
import 'package:chess_auto_prep/v2/storage/foreign_recovery.dart';
import 'package:chess_auto_prep/v2/storage/relocation_notes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory profile;
  late Directory documents;
  late Directory support;
  late Directory root;
  late Directory journals;
  late Directory publications;

  setUp(() async {
    profile = await Directory.systemTemp.createTemp('v1-refusal-');
    documents = await Directory(p.join(profile.path, 'Documents')).create();
    support = await Directory(p.join(profile.path, 'Support')).create();
    root = await Directory(p.join(documents.path, 'repertoires')).create();
    journals = Directory(p.join(support.path, 'repertoire-mutations'));
    publications = Directory(p.join(root.path, '.cap-repertoire-publications'));
  });
  tearDown(() => profile.delete(recursive: true));

  Future<void> check() => refuseV1Recovery(documents, support);

  Future<Map<String, String>> snapshot() async => {
    await for (final entry in profile.list(recursive: true, followLinks: false))
      p.relative(entry.path, from: profile.path): entry is File
          ? base64Encode(await entry.readAsBytes())
          : entry is Link
          ? await entry.target()
          : 'directory',
  };

  Future<void> refused() async {
    final before = await snapshot();
    await expectLater(check(), throwsA(isA<RecoveryRequired>()));
    expect(
      await snapshot(),
      before,
      reason: 'Foreign evidence must be untouched',
    );
  }

  RepertoireDirectoryMutations mutations({RepertoireMoveStep? failAt}) =>
      RepertoireDirectoryMutations(
        root: root,
        journals: journals,
        repoint: (_, _, _) async {},
        testHook: (step) async {
          if (step == failAt) throw StateError('interrupt $step');
        },
      );

  Future<void> move({RepertoireMoveStep? failAt}) async {
    final source = await Directory(p.join(root.path, 'Before')).create();
    await File(p.join(source.path, 'Main.pgn')).writeAsString('1. e4 *');
    final work = mutations(
      failAt: failAt,
    ).move(source.path, p.join(root.path, 'After'));
    if (failAt == null) {
      await work;
    } else {
      await expectLater(work, throwsA(isA<Exception>()));
    }
  }

  Future<void> publish({RepertoirePublicationStep? failAt}) async {
    final store = NativeRepertoirePublicationStore(
      root: root,
      guardCommit: <T>(action) => action(),
      testHook: (step) async {
        if (step == failAt) throw StateError('interrupt $step');
      },
    );
    final work = store.publish(
      RepertoirePublication(
        name: 'Course',
        chapters: {'Main.pgn': '1. e4 *'},
        gameCount: 1,
        sourceContent: '1. e4 *',
      ),
    );
    if (failAt == null) {
      await work;
    } else {
      await expectLater(work, throwsA(isA<Exception>()));
    }
  }

  test('clean profile and empty metadata folders pass', () async {
    await check();
    await journals.create();
    await publications.create();
    await check();
  });

  for (final step in RepertoireMoveStep.values) {
    test(
      'v1 move interrupted at $step ${step == RepertoireMoveStep.completed ? 'passes' : 'refuses'}',
      () async {
        await move(failAt: step);
        if (step == RepertoireMoveStep.completed) {
          await check();
        } else {
          await refused();
        }
      },
    );
  }

  test(
    'retained completed move and publication pass without changes',
    () async {
      await move();
      await publish();
      final before = await snapshot();
      await check();
      expect(await snapshot(), before);
    },
  );

  test('v1 cancelled move preparation passes', () async {
    await move(failAt: RepertoireMoveStep.prepared);
    await mutations().recover();
    await check();
  });

  test('retained completed trash and restore history passes', () async {
    final trash = Directory(p.join(support.path, 'trash'));
    final store = RepertoireDirectoryMutations(
      root: root,
      journals: journals,
      trash: trash,
      trashAllowedRoot: support,
      repoint: (_, _, _) async {},
    );
    final source = await Directory(p.join(root.path, 'Deleted')).create();
    await store.delete(source.path);
    final deleted = (await store.listRecovery()).single;
    await check();
    await store.restore(deleted.id);
    final before = await snapshot();
    await check();
    expect(await snapshot(), before);
    final receipts = await journals.list().toList();
    for (final receipt in receipts.cast<File>()) {
      final record =
          jsonDecode(await receipt.readAsString()) as Map<String, Object?>;
      if (record['kind'] == 'restore') {
        record['identity'] = 'does-not-match';
        await receipt.writeAsString(jsonEncode(record));
      }
    }
    await refused();
  });

  for (final step in RepertoirePublicationStep.values) {
    test('v1 publication interrupted at $step', () async {
      await publish(failAt: step);
      if (step == RepertoirePublicationStep.prepared ||
          step == RepertoirePublicationStep.installed) {
        await refused();
      } else {
        final before = await snapshot();
        await check();
        expect(await snapshot(), before);
      }
    });
  }

  test('v1 cancelled publication passes', () async {
    await publish(failAt: RepertoirePublicationStep.prepared);
    await NativeRepertoirePublicationStore(
      root: root,
      guardCommit: <T>(action) => action(),
    ).recover();
    await check();
  });

  test('old completed move without kind remains compatible', () async {
    await move();
    final receipt = (await journals.list().toList()).single as File;
    final record =
        jsonDecode(await receipt.readAsString()) as Map<String, Object?>;
    record.remove('kind');
    await receipt.writeAsString(jsonEncode(record));
    await check();
  });

  for (final change in [
    'version',
    'state',
    'id',
    'name',
    'identity',
    'files',
    'chapter path',
    'empty chapter',
    'duplicate chapter',
    'digest',
    'extra field',
  ]) {
    test('completed publication with invalid $change refuses', () async {
      await publish();
      final batch = (await publications.list().toList()).single;
      final receipt = File(p.join(batch.path, 'publication.json'));
      final record =
          jsonDecode(await receipt.readAsString()) as Map<String, Object?>;
      final files = record['files'] as Map<String, Object?>;
      switch (change) {
        case 'version':
          record['version'] = 99;
        case 'state':
          record['state'] = 'unknown';
        case 'id':
          record['id'] = 'other';
        case 'name':
          record['name'] = '../outside';
        case 'identity':
          record['identity'] = '';
        case 'files':
          record['files'] = <String, Object?>{};
        case 'chapter path':
          record['files'] = {'../Main.pgn': files.values.single};
        case 'empty chapter':
          record['files'] = {'.pgn': files.values.single};
        case 'duplicate chapter':
          files['main.pgn'] = files.values.single;
        case 'digest':
          (files.values.single as Map<String, Object?>)['digest'] = 'invalid';
        case 'extra field':
          record['futureRecoveryIntent'] = true;
      }
      await receipt.writeAsString(jsonEncode(record));
      await refused();
    });
  }

  for (final value in [
    '{',
    '{"version":99}',
    '{"version":1,"state":"completed"}',
  ]) {
    test('invalid move metadata $value refuses', () async {
      await journals.create();
      await File(p.join(journals.path, '123-ab.json')).writeAsString(value);
      await refused();
    });
    test('invalid publication metadata $value refuses', () async {
      final batch = await Directory(
        p.join(publications.path, '123-ab'),
      ).create(recursive: true);
      await File(p.join(batch.path, 'publication.json')).writeAsString(value);
      await refused();
    });
  }

  test(
    'missing publication manifest with swap residue is not private preparation',
    () async {
      final batch = await Directory(
        p.join(publications.path, '123-ab'),
      ).create(recursive: true);
      await File(
        p.join(batch.path, '.cap-safe-write-token.json'),
      ).writeAsString('{}');
      await refused();
    },
  );

  test('unknown entry in mutation namespace refuses', () async {
    await journals.create();
    await File(p.join(journals.path, 'unknown')).writeAsString('preserve');
    await refused();
  });

  test('non-file publication receipt refuses', () async {
    await Directory(
      p.join(publications.path, '123-ab', 'publication.json'),
    ).create(recursive: true);
    await refused();
  });

  test('unreadable receipt bytes refuse', () async {
    await journals.create();
    await File(p.join(journals.path, '123-ab.json')).writeAsBytes([0xff, 0xfe]);
    await refused();
  });

  for (final namespace in ['moves', 'publications', 'receipt', 'batch']) {
    test('symlink $namespace refuses without following it', () async {
      final outside = await Directory(p.join(profile.path, 'outside')).create();
      switch (namespace) {
        case 'moves':
          await Link(journals.path).create(outside.path);
        case 'publications':
          await Link(publications.path).create(outside.path);
        case 'batch':
          await publications.create();
          await Link(p.join(publications.path, '123-ab')).create(outside.path);
        case 'receipt':
          await move();
          final receipt = (await journals.list().toList()).single as File;
          final target = await receipt.rename(
            p.join(outside.path, 'receipt.json'),
          );
          await Link(receipt.path).create(target.path);
      }
      await refused();
    });
  }
}
