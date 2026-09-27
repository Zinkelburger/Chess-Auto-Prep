// ExpectimaxDatabase: the published bundle, probe landings, and the round
// trip through the artifact store. No engine and no disk.

import 'dart:async';

import 'package:chess_auto_prep/chess_core/generation/expectimax_probe_codec.dart';
import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/core/expectimax_database.dart';
import 'package:chess_auto_prep/features/generation/services/generation_artifacts.dart';
import 'package:chess_auto_prep/chess_core/generation/build_tree_node.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/chess_core/generation/tree_serialization.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/generation_artifacts_fixture.dart';
import 'package:chess_auto_prep/features/generation/models/generation_artifacts.dart';

const _afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';
const _afterE4C5 =
    'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2';
const _afterD4 = 'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1';

BuildTree _tree(
  String rootFen, {
  String childFen = _afterE4,
  Map<String, dynamic> configSnapshot = const {},
}) {
  final root = BuildTreeNode(
    fen: rootFen,
    moveSan: '',
    moveUci: '',
    ply: 0,
    isWhiteToMove: true,
    nodeId: 1,
  )..engineEvalCp = 20;
  root.children.add(
    BuildTreeNode(
      fen: childFen,
      moveSan: 'x',
      moveUci: 'a1a1',
      ply: 1,
      isWhiteToMove: false,
      nodeId: 2,
      parent: root,
    )..engineEvalCp = 25,
  );
  return BuildTree(root: root, totalNodes: 2, configSnapshot: configSnapshot)
    ..computeMetadata();
}

const _config = TreeBuildConfig(startFen: kStandardStartFen, playAsWhite: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryGenerationArtifacts storage;
  late ExpectimaxDatabase db;
  late GenerationArtifacts artifacts;
  setUp(() {
    storage = MemoryGenerationArtifacts();
    artifacts = GenerationArtifacts(storage);
    db = ExpectimaxDatabase(readSaved: artifacts.readDatabase);
  });

  Future<void> persist(String path) async {
    final bundle = db.current;
    if (bundle == null) return;
    final run = await artifacts.repository.begin(path, {});
    await artifacts.writeDatabase(
      run,
      probeTrees: [if (db.mainTreeIsProbe) bundle.tree, ...bundle.probes],
      mainTree: db.mainTreeIsProbe ? null : bundle.tree,
      traps: bundle.traps.allTraps,
    );
    artifacts.repository.close(run);
  }

  group('publish', () {
    test('derives the bundle and reads the side from the snapshot', () {
      db.publish(
        _tree(kStandardStartFen, configSnapshot: {'play_as_white': false}),
      );

      expect(db.current!.playAsWhite, isFalse);
      expect(db.current!.fenMap.getCanonical(_afterE4), isNotNull);
      expect(db.mainTreeIsProbe, isFalse);
    });

    test('a full build keeps a probe-origin main tree as a probe', () {
      final probe = _tree(_afterE4C5, childFen: 'probe-child');
      db.publish(probe, probes: const [], mainIsProbe: true);

      db.publish(_tree(kStandardStartFen));

      expect(db.current!.tree.root.fen, kStandardStartFen);
      expect(db.probes.single, same(probe));
      expect(db.mainTreeIsProbe, isFalse);
    });

    test(
      'republishing the same tree with more probes keeps its trap index',
      () {
        final tree = _tree(kStandardStartFen);
        db.publish(tree);
        final before = db.current!;

        db.publish(
          tree,
          probes: [_tree(_afterE4C5, childFen: 'c')],
          mainTreeChanged: false,
        );

        expect(db.current!.tree, same(before.tree));
        expect(db.current!.traps, same(before.traps));
        expect(db.current!.probes.length, 1);
      },
    );

    test('starting a full build retains the probe-origin tree', () async {
      final probe = _tree(_afterD4);
      db.publish(probe, mainIsProbe: true);

      db.dropTree();
      db.publish(_tree(kStandardStartFen));
      await persist('/r/x.pgn');

      expect(db.probes, [same(probe)]);
      expect(db.mainTreeIsProbe, isFalse);
      expect(
        ExpectimaxProbeCodec.decode(
          (storage.saved['/r/x.pgn'] ??= {})[GenerationArtifactKind.probes]!,
        ).single.root.fen,
        _afterD4,
      );
    });

    test('clear drops everything and forgets the path', () async {
      (storage.saved['/r/x.pgn'] ??= {})[GenerationArtifactKind.tree] =
          serializeTree(_tree(kStandardStartFen));
      await db.load('/r/x.pgn', canApply: () => true);
      expect(db.isFor('/r/x.pgn'), isTrue);

      db.clear();

      expect(db.current, isNull);
      expect(db.probes, isEmpty);
      expect(db.path, isNull);
    });
  });

  group('load', () {
    test('a saved tree and its probes become the bundle', () async {
      (storage.saved['/r/x.pgn'] ??= {})[GenerationArtifactKind.tree] =
          serializeTree(_tree(kStandardStartFen));
      (storage.saved['/r/x.pgn'] ??=
          {})[GenerationArtifactKind.probes] = ExpectimaxProbeCodec.encode([
        _tree(_afterE4C5, childFen: 'probe-child'),
      ]);

      final outcome = await db.load('/r/x.pgn', canApply: () => true);

      expect(outcome, ExpectimaxLoadOutcome.loaded);
      expect(db.current!.tree.root.fen, kStandardStartFen);
      expect(db.current!.probes.length, 1);
      expect(db.isFor('/r/x.pgn'), isTrue);
    });

    test('with only probes saved, the first stands in as the tree', () async {
      (storage.saved['/r/x.pgn'] ??=
          {})[GenerationArtifactKind.probes] = ExpectimaxProbeCodec.encode([
        _tree(_afterE4C5, childFen: 'probe-child'),
        _tree(_afterE4, childFen: 'other-child'),
      ]);

      await db.load('/r/x.pgn', canApply: () => true);

      expect(db.current!.tree.root.fen, _afterE4C5);
      expect(db.probes.single.root.fen, _afterE4);
      expect(db.mainTreeIsProbe, isTrue);
    });

    test('switching repertoires cannot carry a previous probe along', () async {
      (storage.saved['/r/a.pgn'] ??= {})[GenerationArtifactKind.probes] =
          ExpectimaxProbeCodec.encode([_tree(_afterD4)]);
      (storage.saved['/r/b.pgn'] ??= {})[GenerationArtifactKind.tree] =
          serializeTree(_tree(kStandardStartFen));
      await db.load('/r/a.pgn', canApply: () => true);

      await db.load('/r/b.pgn', canApply: () => true);
      await persist('/r/b.pgn');

      expect(db.probes, isEmpty);
      expect(db.current!.fenMap.getCanonical(_afterD4), isNull);
      expect((await artifacts.readDatabase('/r/b.pgn')).probes, isEmpty);
    });

    test(
      'reloading a probe-only repertoire does not duplicate probes',
      () async {
        (storage.saved['/r/x.pgn'] ??= {})[GenerationArtifactKind.probes] =
            ExpectimaxProbeCodec.encode([_tree(_afterD4)]);
        await db.load('/r/x.pgn', canApply: () => true);
        await db.load('/r/x.pgn', canApply: () => true);

        expect(db.current!.allTrees, hasLength(1));
        expect(db.mainTreeIsProbe, isTrue);
      },
    );

    test(
      'a load cannot replace a full build that finished meanwhile',
      () async {
        (storage.saved['/r/x.pgn'] ??= {})[GenerationArtifactKind.tree] =
            serializeTree(_tree(_afterD4));
        final release = Completer<void>();
        storage.beforeRead = (_) => release.future;
        final loading = db.load('/r/x.pgn', canApply: () => true);
        db.dropTree();
        final built = _tree(kStandardStartFen);
        db.publish(built);
        release.complete();

        expect(await loading, ExpectimaxLoadOutcome.superseded);
        expect(db.current!.tree, same(built));
      },
    );

    test('nothing saved empties the bundle', () async {
      db.publish(_tree(kStandardStartFen));

      final outcome = await db.load('/r/none.pgn', canApply: () => true);

      expect(outcome, ExpectimaxLoadOutcome.empty);
      expect(db.current, isNull);
      expect(db.isFor('/r/none.pgn'), isTrue);
    });

    test('an older load landing after a newer one is superseded', () async {
      (storage.saved['/r/a.pgn'] ??= {})[GenerationArtifactKind.tree] =
          serializeTree(_tree(_afterD4));
      (storage.saved['/r/b.pgn'] ??= {})[GenerationArtifactKind.tree] =
          serializeTree(_tree(kStandardStartFen));
      final release = Completer<void>();
      storage.beforeRead = (path) async {
        if (path == '/r/a.pgn') await release.future;
      };

      final first = db.load('/r/a.pgn', canApply: () => true);
      final second = await db.load('/r/b.pgn', canApply: () => true);
      release.complete();

      expect(second, ExpectimaxLoadOutcome.loaded);
      expect(await first, ExpectimaxLoadOutcome.superseded);
      expect(db.current!.tree.root.fen, kStandardStartFen);
      expect(db.isFor('/r/b.pgn'), isTrue);
    });

    test('the owner can refuse to apply a finished load', () async {
      (storage.saved['/r/x.pgn'] ??= {})[GenerationArtifactKind.tree] =
          serializeTree(_tree(kStandardStartFen));

      final outcome = await db.load('/r/x.pgn', canApply: () => false);

      expect(outcome, ExpectimaxLoadOutcome.superseded);
      expect(db.current, isNull);
    });
  });

  test('engine PV scores retain White perspective for either side to move', () {
    for (final fen in [kStandardStartFen, _afterE4]) {
      for (final cp in [-31, 31]) {
        final probe = enginePvProbe(
          fen: fen,
          evalCpWhite: cp,
          pv: const [],
          startMoves: const [],
          config: _config,
        );
        expect(probe.root.evalForUs(true), cp);
        expect(probe.root.evalForUs(false), -cp);
      }
    }
  });

  group('recordEnginePv', () {
    test('a known position gets the eval and PV in place', () {
      final tree = _tree(kStandardStartFen);
      db.publish(tree);
      final probe = enginePvProbe(
        fen: _afterE4,
        evalCpWhite: 31,
        pv: ['e7e5', 'g1f3'],
        startMoves: const ['e4'],
        config: _config,
      );

      final mainTreeChanged = db.recordEnginePv(probe);

      expect(mainTreeChanged, isTrue);
      expect(tree.root.children.single.engineEvalCp, -31);
      expect(tree.root.children.single.enginePv, ['e7e5', 'g1f3']);
      expect(db.current!.fenMap.getCanonical(_afterE4)!.engineEvalCp, -31);
      expect(db.probes, isEmpty, reason: 'nothing grafted, nothing added');
    });

    test('an unknown position joins as a probe of its own', () {
      db.publish(_tree(kStandardStartFen));
      final probe = enginePvProbe(
        fen: _afterD4,
        evalCpWhite: 10,
        pv: ['d7d5'],
        startMoves: const ['d4'],
        config: _config,
      );

      expect(db.recordEnginePv(probe), isFalse);
      expect(db.probes.single, same(probe));
      expect(db.current!.fenMap.getCanonical(_afterD4), isNotNull);
    });

    test('with no bundle the PV probe becomes the main tree', () {
      final probe = enginePvProbe(
        fen: _afterD4,
        evalCpWhite: 10,
        pv: const [],
        startMoves: const ['d4'],
        config: _config,
      );
      expect(db.recordEnginePv(probe), isFalse);
      expect(db.current!.tree, same(probe));
      expect(db.mainTreeIsProbe, isTrue);
    });
  });

  group('addBoundedProbe', () {
    const bounded = {'bounded_database': true};

    test('replaces an earlier bounded probe at the same root', () {
      db.publish(_tree(kStandardStartFen));
      final old = _tree(_afterD4, childFen: 'old', configSnapshot: bounded);
      db.publish(db.current!.tree, probes: [old]);
      final fresh = _tree(_afterD4, childFen: 'new', configSnapshot: bounded);

      db.addBoundedProbe(
        fresh,
        config: _config.copyWith(boundedDatabase: true),
        prefix: const ['d4'],
      );

      expect(db.probes, [same(fresh)]);
      expect(fresh.startMoves, 'd4');
    });

    test('with no bundle the probe becomes the main tree', () {
      final probe = _tree(_afterD4, configSnapshot: bounded);
      db.addBoundedProbe(probe, config: _config, prefix: const ['d4']);
      expect(db.current!.tree, same(probe));
      expect(db.mainTreeIsProbe, isTrue);
    });
  });

  group('landProbe', () {
    test('a probe rooted outside the database is kept as its own tree', () {
      db.publish(_tree(kStandardStartFen));
      final probe = _tree(_afterD4, childFen: 'deep');

      final landing = db.landProbe(
        probe,
        config: _config,
        prefix: const ['d4'],
        repertoireFilePath: '/r/x.pgn',
      );

      expect(landing.added, probe.totalNodes);
      expect(landing.mainTreeChanged, isFalse);
      expect(db.probes.single, same(probe));
      expect(probe.startMoves, 'd4');
      expect(db.isFor('/r/x.pgn'), isTrue);
    });

    test('a probe rooted inside the main tree is grafted into it', () {
      final tree = _tree(kStandardStartFen);
      db.publish(tree);
      final probe = _tree(_afterE4, childFen: _afterE4C5);

      final landing = db.landProbe(
        probe,
        config: _config,
        prefix: const ['e4'],
        repertoireFilePath: '/r/x.pgn',
      );

      expect(landing.mainTreeChanged, isTrue);
      expect(landing.added, 1);
      expect(
        db.current!.tree.nodeIndex.values.map((node) => node.fen),
        contains(_afterE4C5),
      );
      expect(db.probes, isEmpty);
      expect(db.current!.fenMap.getCanonical(_afterE4C5), isNotNull);
    });
  });

  group('persist', () {
    test('writes the probes and the changed main tree', () async {
      db.publish(_tree(kStandardStartFen), probes: [_tree(_afterD4)]);

      await persist('/r/x.pgn');

      expect(
        storage.saved['/r/x.pgn']!.keys,
        containsAll([
          GenerationArtifactKind.tree,
          GenerationArtifactKind.probes,
        ]),
      );
      expect(
        ExpectimaxProbeCodec.decode(
          (storage.saved['/r/x.pgn'] ??= {})[GenerationArtifactKind.probes]!,
        ).single.root.fen,
        _afterD4,
      );
    });

    test('a probe-origin main tree is saved among the probes', () async {
      db.publish(_tree(_afterD4), probes: const [], mainIsProbe: true);

      await persist('/r/x.pgn');

      expect((await artifacts.readDatabase('/r/x.pgn')).tree, isNull);
      expect(
        ExpectimaxProbeCodec.decode(
          (storage.saved['/r/x.pgn'] ??= {})[GenerationArtifactKind.probes]!,
        ).single.root.fen,
        _afterD4,
      );
    });

    test('an empty bundle writes nothing', () async {
      await persist('/r/x.pgn');
      expect(storage.saved, isEmpty);
    });
  });
}
