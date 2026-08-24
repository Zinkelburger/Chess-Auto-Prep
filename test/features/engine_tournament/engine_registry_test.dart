import 'dart:io';

import 'package:chess_auto_prep/features/engine_tournament/models/engine_spec.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/engine_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late EngineRegistry registry;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('engine_registry_test');
    registry = EngineRegistry(File(p.join(temp.path, 'engines.json')));
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('the bundled engine is always there, first, with no file', () async {
    final all = await registry.loadAll();
    expect(all.length, 1);
    expect(all.first.id, EngineSpec.bundledId);
    expect(all.first.isBundled, isTrue);
  });

  test('added engines follow the bundled one', () async {
    await registry.add(
      const EngineSpec(id: 'x', name: 'Xiphos', executablePath: '/bin/xiphos'),
    );
    final all = await registry.loadAll();
    expect(all.map((e) => e.name), ['Stockfish (bundled)', 'Xiphos']);
    expect(all.last.executablePath, '/bin/xiphos');
  });

  test('bundled settings persist but its path never does', () async {
    await registry.update(
      EngineSpec.bundledStockfish.copyWith(
        name: 'Stockfish (4 threads)',
        threads: 4,
        hashMb: 1024,
        ponder: true,
        // A path here must not survive: it is resolved at launch.
        executablePath: '/somewhere/stale/stockfish',
      ),
    );

    final reloaded = await EngineRegistry(registry.file).loadAll();
    expect(reloaded.first.id, EngineSpec.bundledId);
    expect(reloaded.first.name, 'Stockfish (4 threads)');
    expect(reloaded.first.threads, 4);
    expect(reloaded.first.hashMb, 1024);
    expect(reloaded.first.ponder, isTrue);
    expect(reloaded.first.executablePath, isNull);
    expect(reloaded.first.isBundled, isTrue);
  });

  test('the bundled entry is not counted as a user engine', () async {
    await registry.update(EngineSpec.bundledStockfish.copyWith(threads: 2));
    await registry.add(
      const EngineSpec(id: 'x', name: 'Xiphos', executablePath: '/bin/xiphos'),
    );
    expect((await registry.loadUserEngines()).map((e) => e.id), ['x']);
  });

  test('updating an engine replaces it rather than duplicating it', () async {
    await registry.add(
      const EngineSpec(id: 'x', name: 'Xiphos', executablePath: '/bin/xiphos'),
    );
    await registry.update(
      const EngineSpec(id: 'x', name: 'Renamed', executablePath: '/bin/xiphos'),
    );
    final all = await registry.loadAll();
    expect(all.length, 2);
    expect(all.last.name, 'Renamed');
  });

  test('removing takes only that engine', () async {
    await registry.add(
      const EngineSpec(id: 'x', name: 'X', executablePath: '/bin/x'),
    );
    await registry.add(
      const EngineSpec(id: 'y', name: 'Y', executablePath: '/bin/y'),
    );
    final all = await registry.remove('x');
    expect(all.map((e) => e.id), [EngineSpec.bundledId, 'y']);
  });

  test('a corrupt file degrades to the bundled engine alone', () async {
    await registry.file.writeAsString('not json at all');
    expect((await registry.loadAll()).length, 1);
  });
}
