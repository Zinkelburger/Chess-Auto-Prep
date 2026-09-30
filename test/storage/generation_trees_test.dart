import 'dart:io';
import 'dart:convert';
import 'package:chess_auto_prep/chess/fen.dart';

import 'package:chess_auto_prep/storage/atomic_write.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/generation_trees.dart';
import 'package:chess_auto_prep/storage/recovery_gate.dart';
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
    'a restarted owner finds only trees starting at the requested board',
    () async {
      const fen = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';
      final text = jsonEncode({
        'tree': {'fen': fen},
      });
      await owner().keep(chapter, text, runId: 'saved');
      expect(await owner().startingAt(chapter, const Fen(fen)).toList(), [
        text,
      ]);
      expect(
        await owner().startingAt(chapter, const Fen('different')).toList(),
        isEmpty,
      );
    },
  );

  String treeAt(String fen, int run) => jsonEncode({
    'run': run,
    'tree': {'fen': fen},
  });

  File treeOf(String runId) =>
      File(p.join(artifact.parent.parent.path, 'v2-$runId', 'tree.json'));

  test('every tree at the board comes back, newest first', () async {
    const fen = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';
    const other = '4k3/8/8/8/8/8/4P3/3K4 w - - 0 1';
    final base = DateTime.now().subtract(const Duration(days: 1));
    final trees = owner();
    for (final (i, (runId, at)) in [
      ('newer', fen),
      ('elsewhere', other),
      ('older', fen),
    ].indexed) {
      await trees.keep(chapter, treeAt(at, i), runId: runId);
    }
    await treeOf('older').setLastModified(base);
    await treeOf(
      'elsewhere',
    ).setLastModified(base.add(const Duration(hours: 1)));
    await treeOf('newer').setLastModified(base.add(const Duration(hours: 2)));
    expect(await trees.startingAt(chapter, const Fen(fen)).toList(), [
      treeAt(fen, 0),
      treeAt(fen, 2),
    ]);
  });

  test('keeping a tree removes all but the newest earlier runs, and nothing '
      'that is not a v2 run', () async {
    const fen = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';
    const kept = GenerationTrees.keptRuns;
    final legacy = File(
      p.join(artifact.parent.parent.path, 'v1-legacy', 'tree.json'),
    );
    await legacy.create(recursive: true);
    await legacy.writeAsString('v1');
    final base = DateTime.now().subtract(const Duration(days: 1));
    final trees = owner();
    for (var i = 0; i < kept + 5; i++) {
      await trees.keep(chapter, treeAt(fen, i), runId: 'run$i');
      await treeOf('run$i').setLastModified(base.add(Duration(minutes: i)));
    }
    final runs = [
      await for (final entry in artifact.parent.parent.list())
        if (p.basename(entry.path).startsWith('v2-')) p.basename(entry.path),
    ];
    expect(runs.length, lessThanOrEqualTo(kept + 1));
    expect(runs, contains('v2-run${kept + 4}'));
    expect(runs, isNot(contains('v2-run0')));
    expect(await legacy.readAsString(), 'v1');
    expect(
      (await trees.startingAt(chapter, const Fen(fen)).first),
      treeAt(fen, kept + 4),
    );
  });

  test(
    'pruning leaves linked runs, runs without a tree and agent runs',
    () async {
      const fen = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';
      final runs = artifact.parent.parent.path;
      final outside = await Directory(p.join(root.path, 'outside')).create();
      final linkedTree = await File(
        p.join(outside.path, 'tree.json'),
      ).writeAsString(treeAt(fen, -1));
      await Link(
        p.join(runs, 'v2-linked'),
      ).create(outside.path, recursive: true);
      final empty = await Directory(p.join(runs, 'v2-empty')).create();
      final agent = File(p.join(runs, 'v2-agent-mcp', 'tree.json'));
      await agent.create(recursive: true);
      await agent.writeAsString(treeAt(fen, -2));
      final base = DateTime.now().subtract(const Duration(days: 2));
      await agent.setLastModified(base);
      final trees = owner();
      for (var i = 0; i < GenerationTrees.keptRuns + 3; i++) {
        await trees.keep(chapter, treeAt(fen, i), runId: 'run$i');
        await treeOf(
          'run$i',
        ).setLastModified(base.add(Duration(hours: 1, minutes: i)));
      }
      expect(await treeOf('run0').exists(), isFalse, reason: 'pruning ran');
      expect(await Link(p.join(runs, 'v2-linked')).exists(), isTrue);
      expect(await linkedTree.readAsString(), treeAt(fen, -1));
      expect(await empty.exists(), isTrue);
      expect(await agent.readAsString(), treeAt(fen, -2));
      final listed = await trees.startingAt(chapter, const Fen(fen)).toList();
      expect(listed.last, treeAt(fen, -2), reason: 'agent runs still resume');
      expect(listed, isNot(contains(treeAt(fen, -1))), reason: 'links unread');
    },
    skip: Platform.isWindows,
  );

  test('when no saved tree can be read the listing fails', () async {
    const fen = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';
    final broken = treeOf('broken');
    await broken.create(recursive: true);
    await broken.writeAsBytes([0xff, 0xfe, 0xfd]);
    await expectLater(
      owner().startingAt(chapter, const Fen(fen)).toList(),
      throwsA(isA<FileSystemException>()),
    );
    await owner().keep(chapter, treeAt('elsewhere', 0), runId: 'readable');
    expect(
      await owner().startingAt(chapter, const Fen(fen)).toList(),
      isEmpty,
      reason: 'a readable tree at another board is no failure',
    );
  });

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
      expect(await artifact.readAsString(), text, reason: 'one tree per run');
    },
  );

  test(
    'a staged copy left by a crash does not block keeping the tree',
    () async {
      await artifact.parent.create(recursive: true);
      final stage = File(temporaryPathFor(artifact.path));
      await stage.writeAsString('half a tree');
      await owner().keep(chapter, 'tree', runId: 'fixed-id');
      expect(await artifact.readAsString(), 'tree');
      expect(await stage.exists(), isFalse);
    },
  );

  test('a missing source leaves a visible retryable failure', () async {
    await File(chapter.path).delete();
    await expectLater(
      owner().keep(chapter, 'tree', runId: 'fixed-id'),
      throwsA(isA<FileSystemException>()),
    );
    expect(await artifact.exists(), isFalse);
  });

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
    await owner().keep(chapter, 'tree', runId: 'fixed-id');
    expect(await target.readAsString(), 'keep');
    expect(await artifact.readAsString(), 'tree');
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
