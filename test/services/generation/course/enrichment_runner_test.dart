/// [EnrichmentRunner] on its own: the six steps every post-build pass shares.
///
/// The contract worth pinning is that a pass is *best-effort* — switched off,
/// nothing to do, cancelled, or thrown are all "no findings, export goes
/// ahead", and all four look identical to the caller.
library;

import 'package:chess_auto_prep/services/generation/course/enrichment_runner.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:flutter_test/flutter_test.dart';

const _startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

/// A config that wants the engine, which is the gate every pass sits behind.
TreeBuildConfig _engineConfig() =>
    const TreeBuildConfig(startFen: _startFen, playAsWhite: true, maxPly: 6);

void main() {
  late List<String> statuses;
  late int engineStarts;
  late bool cancelled;
  late TreeBuildConfig? config;

  EnrichmentRunner makeRunner() => EnrichmentRunner(
    config: () => config,
    isCancelled: () => cancelled,
    onStatus: statuses.add,
    ensureEngine: () async => engineStarts++,
  );

  setUp(() {
    statuses = [];
    engineStarts = 0;
    cancelled = false;
    config = _engineConfig();
  });

  /// A probe that reports one step of progress and returns [findings].
  EnrichmentProbe<int> probeReturning(Map<String, int> findings) =>
      ({required isCancelled, required onProgress}) async {
        onProgress(1, 2);
        return findings;
      };

  group('a pass that runs', () {
    test('returns its findings and records the count', () async {
      final runner = makeRunner();
      final out = await runner.run<int>(
        EnrichmentPass.refutations,
        enabled: true,
        status: (done, total) => 'probing $done of $total',
        prepare: () => probeReturning({'a': 1, 'b': 2}),
      );

      expect(out, {'a': 1, 'b': 2});
      expect(runner.countOf(EnrichmentPass.refutations), 2);
      expect(runner.anyFindings, isTrue);
    });

    test('warms the engine pool exactly once', () async {
      await makeRunner().run<int>(
        EnrichmentPass.engineTails,
        enabled: true,
        status: (d, t) => '',
        prepare: () => probeReturning({'a': 1}),
      );
      expect(engineStarts, 1);
    });

    test('renders progress through the status callback', () async {
      await makeRunner().run<int>(
        EnrichmentPass.alternatives,
        enabled: true,
        status: (done, total) => 'checked $done of $total',
        prepare: () => probeReturning({'a': 1}),
      );
      expect(statuses, ['checked 1 of 2']);
    });

    test('counts are per pass, not shared', () async {
      final runner = makeRunner();
      await runner.run<int>(
        EnrichmentPass.refutations,
        enabled: true,
        status: (d, t) => '',
        prepare: () => probeReturning({'a': 1, 'b': 2, 'c': 3}),
      );
      await runner.run<int>(
        EnrichmentPass.improvements,
        enabled: true,
        status: (d, t) => '',
        prepare: () => probeReturning({'x': 1}),
      );
      expect(runner.countOf(EnrichmentPass.refutations), 3);
      expect(runner.countOf(EnrichmentPass.improvements), 1);
      expect(runner.countOf(EnrichmentPass.engineTails), 0);
    });
  });

  group('a pass that does not run costs nothing and reports nothing', () {
    /// Every skip reason must look the same to the caller: no findings, no
    /// engine started, no count, and above all no throw.
    Future<void> expectSkipped(
      EnrichmentRunner runner,
      Future<Map<String, int>> Function() call, {
      required String reason,
    }) async {
      final out = await call();
      expect(out, isEmpty, reason: reason);
      expect(engineStarts, 0, reason: '$reason must not start the engine');
      expect(runner.countOf(EnrichmentPass.refutations), 0, reason: reason);
      expect(runner.anyFindings, isFalse, reason: reason);
    }

    test('switched off in the config', () async {
      final runner = makeRunner();
      var prepared = false;
      await expectSkipped(
        runner,
        () => runner.run<int>(
          EnrichmentPass.refutations,
          enabled: false,
          status: (d, t) => '',
          prepare: () {
            prepared = true;
            return probeReturning({'a': 1});
          },
        ),
        reason: 'disabled',
      );
      expect(prepared, isFalse, reason: 'a disabled pass builds no prober');
    });

    test('the run was cancelled before it started', () async {
      cancelled = true;
      final runner = makeRunner();
      await expectSkipped(
        runner,
        () => runner.run<int>(
          EnrichmentPass.refutations,
          enabled: true,
          status: (d, t) => '',
          prepare: () => probeReturning({'a': 1}),
        ),
        reason: 'cancelled',
      );
    });

    test('there is no active config', () async {
      config = null;
      final runner = makeRunner();
      await expectSkipped(
        runner,
        () => runner.run<int>(
          EnrichmentPass.refutations,
          enabled: true,
          status: (d, t) => '',
          prepare: () => probeReturning({'a': 1}),
        ),
        reason: 'no config',
      );
    });

    test('the prober found nothing to work on', () async {
      final runner = makeRunner();
      await expectSkipped(
        runner,
        () => runner.run<int>(
          EnrichmentPass.refutations,
          enabled: true,
          status: (d, t) => '',
          prepare: () => null,
        ),
        reason: 'no targets',
      );
    });
  });

  group('a pass that fails', () {
    test('is swallowed — it costs its own output, never the export', () async {
      final runner = makeRunner();
      final out = await runner.run<int>(
        EnrichmentPass.refutations,
        enabled: true,
        status: (d, t) => '',
        prepare: () =>
            ({required isCancelled, required onProgress}) async =>
                throw StateError('engine died'),
      );

      expect(out, isEmpty);
      expect(runner.countOf(EnrichmentPass.refutations), 0);
    });

    test('does not stop the next pass', () async {
      final runner = makeRunner();
      await runner.run<int>(
        EnrichmentPass.refutations,
        enabled: true,
        status: (d, t) => '',
        prepare: () =>
            ({required isCancelled, required onProgress}) async =>
                throw StateError('engine died'),
      );
      final out = await runner.run<int>(
        EnrichmentPass.engineTails,
        enabled: true,
        status: (d, t) => '',
        prepare: () => probeReturning({'a': 1}),
      );
      expect(out, {'a': 1});
      expect(runner.countOf(EnrichmentPass.engineTails), 1);
    });
  });

  group('counts across runs', () {
    test('reset clears every pass', () async {
      final runner = makeRunner();
      await runner.run<int>(
        EnrichmentPass.refutations,
        enabled: true,
        status: (d, t) => '',
        prepare: () => probeReturning({'a': 1}),
      );
      expect(runner.anyFindings, isTrue);

      runner.reset();

      expect(runner.countOf(EnrichmentPass.refutations), 0);
      expect(runner.anyFindings, isFalse);
    });

    test(
      're-running a pass replaces its count rather than adding to it',
      () async {
        final runner = makeRunner();
        await runner.run<int>(
          EnrichmentPass.refutations,
          enabled: true,
          status: (d, t) => '',
          prepare: () => probeReturning({'a': 1, 'b': 2}),
        );
        await runner.run<int>(
          EnrichmentPass.refutations,
          enabled: true,
          status: (d, t) => '',
          prepare: () => probeReturning({'c': 3}),
        );
        expect(runner.countOf(EnrichmentPass.refutations), 1);
      },
    );

    test('a pass that stops running zeroes its own count', () async {
      final runner = makeRunner();
      await runner.run<int>(
        EnrichmentPass.refutations,
        enabled: true,
        status: (d, t) => '',
        prepare: () => probeReturning({'a': 1}),
      );
      // The count must not survive into a run where the pass is switched off,
      // or the summary would claim findings this run never produced.
      await runner.run<int>(
        EnrichmentPass.refutations,
        enabled: false,
        status: (d, t) => '',
        prepare: () => probeReturning({'a': 1}),
      );
      expect(runner.countOf(EnrichmentPass.refutations), 0);
    });
  });

  test('every pass has a distinct label for its failure log', () {
    final labels = EnrichmentPass.values.map((p) => p.label).toSet();
    expect(labels, hasLength(EnrichmentPass.values.length));
  });
}
