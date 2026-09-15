import 'dart:async';

import 'package:chess_auto_prep/features/bughouse/models/bughouse_engine_settings.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_engine.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_engine_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bughouse_engine.dart';

/// Holding the one engine: shared launches, dead processes, once-per-change
/// options, and never disposing an engine somebody else owns.
void main() {
  final infos = <BughouseInfo>[];
  var changes = 0;

  setUp(() {
    infos.clear();
    changes = 0;
  });

  BughouseEngineSession session({
    BughouseAnalysisEngine? override,
    Future<BughouseAnalysisEngine> Function()? launch,
  }) => BughouseEngineSession(
    engineOverride: override,
    onInfo: infos.add,
    onChanged: () => changes++,
    launch: launch ?? () async => throw StateError('no launch expected'),
  );

  BughouseInfo line(int cp) => BughouseInfo(
    depth: 1,
    scoreCp: cp,
    nodes: 10,
    nps: 1,
    timeMs: 1,
    pv: const [],
  );

  test('an injected engine is adopted and its info lines forwarded', () async {
    final fake = FakeBughouseEngine();
    final s = session(override: fake);
    expect(s.isReady, isFalse);

    final acquired = await s.acquire();
    expect(identical(acquired, fake), isTrue);
    expect(s.engine, same(fake));
    expect(s.isReady, isTrue);
    expect(s.isStarting, isFalse);
    expect(changes, 0, reason: 'nothing was launched');

    fake.emit(line(5));
    await Future<void>.delayed(Duration.zero);
    expect(infos.map((i) => i.scoreCp), [5]);

    s.dispose();
    expect(fake.disposals, 0, reason: 'an injected engine is never disposed');
  });

  test(
    'a dead engine is replaced by one launch shared by every caller',
    () async {
      final dead = FakeBughouseEngine()..die();
      final fresh = FakeBughouseEngine();
      var launches = 0;
      final gate = Completer<void>();
      final s = session(
        override: dead,
        launch: () async {
          launches++;
          await gate.future;
          return fresh;
        },
      );

      final first = s.acquire();
      final second = s.acquire();
      expect(s.isStarting, isTrue);
      expect(changes, 1);
      gate.complete();
      expect(identical(await first, fresh), isTrue);
      expect(identical(await second, fresh), isTrue);
      expect(launches, 1);
      expect(s.isStarting, isFalse);
      expect(changes, 2);

      // The launched engine is ours: shutting down disposes it.
      await s.shutDown();
      expect(fresh.disposals, 1);
      expect(s.engine, isNull);
      expect(changes, 3);
    },
  );

  test('a failed launch can be retried', () async {
    var attempts = 0;
    final fresh = FakeBughouseEngine();
    final s = session(
      launch: () async {
        attempts++;
        if (attempts == 1) throw BughouseEngineFailure('no network');
        return fresh;
      },
    );
    await expectLater(s.acquire(), throwsA(isA<BughouseEngineFailure>()));
    expect(s.isStarting, isFalse);
    expect(identical(await s.acquire(), fresh), isTrue);
    expect(attempts, 2);
    s.dispose();
    expect(fresh.disposals, 1);
  });

  test('options reach the process once per change', () async {
    final fake = FakeBughouseEngine();
    final s = session(override: fake);
    final engine = await s.acquire();
    const settings = BughouseEngineSettings(hashMb: 512, batchSize: 4);

    await s.applyOptions(engine, settings);
    await s.applyOptions(engine, settings);
    expect(fake.options, [
      (name: 'Hash', value: 512),
      (name: 'BatchSize', value: 4),
    ]);

    s.markOptionsDirty();
    await s.applyOptions(engine, settings.copyWith(hashMb: 64));
    expect(fake.options.skip(2), [
      (name: 'Hash', value: 64),
      (name: 'BatchSize', value: 4),
    ]);
  });

  test('a failed option push is retried on the next pass', () async {
    final fake = _RefusingEngine();
    final s = session(override: fake);
    final engine = await s.acquire();
    await expectLater(
      s.applyOptions(engine, const BughouseEngineSettings()),
      throwsA(isA<BughouseEngineFailure>()),
    );
    fake.refuse = false;
    await s.applyOptions(engine, const BughouseEngineSettings());
    expect(fake.options.map((o) => o.name), ['Hash', 'BatchSize']);
  });

  test('shutting an injected engine down releases without disposing', () async {
    final fake = FakeBughouseEngine();
    final s = session(override: fake);
    await s.acquire();
    await s.shutDown();
    expect(s.engine, isNull);
    expect(fake.disposals, 0);
    expect(changes, 0);
    // And it comes straight back on the next request.
    expect(identical(await s.acquire(), fake), isTrue);
  });
}

/// Refuses every `setoption` until told otherwise.
class _RefusingEngine extends FakeBughouseEngine {
  bool refuse = true;

  @override
  Future<void> setOption(String name, Object value) async {
    if (refuse) throw BughouseEngineFailure('refused $name');
    return super.setOption(name, value);
  }
}
