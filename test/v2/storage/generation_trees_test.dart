import 'dart:io';

import 'package:chess_auto_prep/v2/storage/atomic_write.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/generation_trees.dart';
import 'package:chess_auto_prep/v2/storage/recovery_gate.dart';
import 'package:chess_auto_prep/v2/storage/relocation_notes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory documents;
  late Directory support;
  late ChapterRef chapter;
  late File artifact;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('generation-trees-');
    documents = await Directory(p.join(root.path, 'Documents')).create();
    support = await Directory(p.join(root.path, 'Support')).create();
    final folder = await Directory(
      p.join(documents.path, 'repertoires', 'Main'),
    ).create(recursive: true);
    chapter = ChapterRef.at(p.join(folder.path, 'Chapter.pgn'));
    await File(chapter.path).writeAsString('[Event "Chapter"]\n\n1. e4 *');
    artifact = File(
      p.join(
        folder.path,
        '.cap-generation',
        'Chapter.pgn',
        'v2-fixed-id',
        'tree.json',
      ),
    );
  });
  tearDown(() => root.delete(recursive: true));

  GenerationTrees owner({
    Future<void> Function()? hook,
    Directory? configured,
  }) => GenerationTrees(
    RecoveryGate(documents: configured ?? documents, support: support),
    afterPublish: hook,
  );

  test(
    'lost acknowledgement reopens exact artifact without another run',
    () async {
      const text = '{"format":"opening_tree","version":4}';
      await expectLater(
        owner(
          hook: () async => throw StateError('lost ack'),
        ).keep(chapter, text, runId: 'fixed-id'),
        throwsStateError,
      );
      expect(await artifact.readAsString(), text);
      await owner().keep(chapter, text, runId: 'fixed-id');
      expect(await artifact.parent.parent.list().length, 1);
      await expectLater(
        owner().keep(chapter, 'different', runId: 'fixed-id'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await artifact.readAsString(), text);
    },
  );

  test(
    'matching abandoned stage is reusable; different bytes are preserved',
    () async {
      await artifact.parent.create(recursive: true);
      final stage = File(temporaryPathFor(artifact.path));
      await stage.writeAsString('tree');
      await owner().keep(chapter, 'tree', runId: 'fixed-id');
      expect(await artifact.readAsString(), 'tree');
      expect(await stage.exists(), isFalse);
      await stage.writeAsString('other accepted data');
      await expectLater(
        owner().keep(chapter, 'tree', runId: 'fixed-id'),
        throwsA(isA<RecoveryRequired>()),
      );
      expect(await stage.readAsString(), 'other accepted data');
    },
  );

  test('linked artifact ancestry and stage preserve external bytes', () async {
    final outside = await Directory(p.join(root.path, 'outside')).create();
    final target = await File(
      p.join(outside.path, 'target'),
    ).writeAsString('keep');
    final generation = Directory(p.dirname(artifact.parent.parent.path));
    await Link(generation.path).create(outside.path);
    await expectLater(
      owner().keep(chapter, 'tree', runId: 'fixed-id'),
      throwsA(isA<FileSystemException>()),
    );
    await Link(generation.path).delete();
    await artifact.parent.create(recursive: true);
    await Link(temporaryPathFor(artifact.path)).create(target.path);
    await expectLater(
      owner().keep(chapter, 'tree', runId: 'fixed-id'),
      throwsA(isA<RecoveryRequired>()),
    );
    expect(await target.readAsString(), 'keep');
    expect(await artifact.exists(), isFalse);
  }, skip: Platform.isWindows);

  test(
    'configured alias works but later root retarget cannot publish',
    () async {
      final alias = Link(p.join(root.path, 'Documents-alias'));
      await alias.create(documents.path);
      final configured = Directory(alias.path);
      final trees = owner(configured: configured);
      final ref = ChapterRef.at(
        p.join(alias.path, p.relative(chapter.path, from: documents.path)),
      );
      await trees.keep(ref, 'tree', runId: 'fixed-id');
      final other = await Directory(p.join(root.path, 'Other')).create();
      await alias.delete();
      await alias.create(other.path);
      await expectLater(
        trees.keep(ref, 'other', runId: 'second'),
        throwsA(anything),
      );
      expect(await artifact.readAsString(), 'tree');
      expect(
        await other
            .list(recursive: true)
            .where((e) => e.path.endsWith('tree.json'))
            .length,
        0,
      );
    },
    skip: Platform.isWindows,
  );

  test('shared Documents and Support completes without nested lock', () async {
    final trees = GenerationTrees(
      RecoveryGate(documents: documents, support: documents),
    );
    await trees
        .keep(chapter, 'tree', runId: 'fixed-id')
        .timeout(const Duration(seconds: 5));
    expect(await artifact.readAsString(), 'tree');
  });

  test('invalid run and outside managed source are refused', () async {
    await expectLater(
      owner().keep(chapter, 'tree', runId: '../bad'),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      owner().keep(
        ChapterRef.at(p.join(root.path, 'outside.pgn')),
        'tree',
        runId: 'fixed-id',
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await artifact.exists(), isFalse);
  });
}
