import 'package:flutter_test/flutter_test.dart';

import 'props.dart';

/// No override from the shell running the tests reaches these checks.
const Map<String, String> _noEnv = {};

Matcher _failureSaying(List<String> parts) => isA<TestFailure>().having(
  (f) => f.message,
  'message',
  allOf([for (final p in parts) contains(p)]),
);

void main() {
  group('Rand', () {
    test('a seed gives the same values on every run and every machine', () {
      // Pinned outputs: printed seeds in old failure reports replay only
      // while the generator stays byte-identical.
      List<int> first(int seed) {
        final r = Rand(seed);
        return [for (var i = 0; i < 4; i++) r.nextInt(1000)];
      }

      expect(first(0), [31, 712, 831, 865]);
      expect(first(defaultPropSeed), [791, 522, 866, 799]);
      expect(first(12345), [29, 40, 471, 809]);
    });

    test('a generator draws the same values from the same seed', () {
      final gen = listOf(oneOf([ints(0, 9), ints(100, 200)]), max: 12);
      for (var seed = 0; seed < 50; seed++) {
        expect(gen.sample(Rand(seed)), gen.sample(Rand(seed)));
      }
    });
  });

  group('checkProperty', () {
    test(
      'a failure reports its seed, a replay line and a shrunk value',
      () async {
        await expectLater(
          checkProperty(
            'ints stay small',
            ints(0, 1000),
            (v) => expect(v, lessThan(10)),
            seed: 7,
            environment: _noEnv,
          ),
          throwsA(
            _failureSaying([
              'Property failed: ints stay small',
              'seed:       7 (case ',
              'replay:     seed: ',
              'CAP_PROP_SEED=',
              '--plain-name "ints stay small"',
              'keep it:    regressionSeeds: [',
              'shrunk to:  10\n',
            ]),
          ),
        );
      },
    );

    test('the replay seed reproduces the reported value', () async {
      Object? report;
      try {
        await checkProperty(
          'no big lists',
          listOf(ints(0, 50), max: 8),
          (v) => expect(v.length, lessThan(5)),
          environment: _noEnv,
        );
      } on TestFailure catch (e) {
        report = e.message;
      }
      final text = report! as String;
      final caseSeed = int.parse(
        RegExp(r'caseSeed (\d+)').firstMatch(text)!.group(1)!,
      );
      final generated = RegExp(r'generated:  (.*)\n').firstMatch(text)!;
      expect(
        listOf(ints(0, 50), max: 8).sample(Rand(caseSeed)).toString(),
        generated.group(1),
      );
      // Shrinking dropped the elements the failure does not need.
      final shrunk = RegExp(r'shrunk to:  \[(.*)\]\n').firstMatch(text)!;
      expect(shrunk.group(1)!.split(', '), hasLength(5));
    });

    test('regressions run before the random cases, in order', () async {
      final seen = <int>[];
      await checkProperty(
        'records order',
        ints(100, 200),
        seen.add,
        runs: 3,
        regressions: const [1, 2],
        regressionSeeds: const [42],
        environment: _noEnv,
      );
      expect(seen.take(3), [1, 2, ints(100, 200).sample(Rand(42))]);
      expect(seen, hasLength(6));
      expect(seen.skip(3), everyElement(inInclusiveRange(100, 200)));
    });

    test('a failing regression is reported as one', () async {
      await expectLater(
        checkProperty(
          'never 13',
          ints(0, 5),
          (v) => expect(v, isNot(13)),
          regressions: const [4, 13],
          environment: _noEnv,
        ),
        throwsA(_failureSaying(['regression: 1 of regressions:', '13'])),
      );
    });

    test('async cases are awaited one at a time', () async {
      var running = 0;
      var finished = 0;
      final order = <String>[];
      await checkProperty<int>(
        'awaits',
        ints(0, 3),
        (v) async {
          expect(running, 0, reason: 'a case started before the last ended');
          running++;
          order.add('start');
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);
          order.add('end');
          running--;
          finished++;
        },
        runs: 5,
        environment: _noEnv,
      );
      expect(finished, 5);
      expect(order, [
        for (var i = 0; i < 5; i++) ...['start', 'end'],
      ]);
    });

    test('an async failure is caught, shrunk and reported', () async {
      await expectLater(
        checkProperty<int>('async small', ints(0, 1000), (v) async {
          await Future<void>.delayed(Duration.zero);
          if (v >= 10) throw StateError('too big: $v');
        }, environment: _noEnv),
        throwsA(_failureSaying(['shrunk to:  10\n', 'too big: 10'])),
      );
    });

    test('CAP_PROP_RUNS and CAP_PROP_SEED win over the arguments', () async {
      final seen = <int>[];
      await checkProperty(
        'env',
        ints(0, 1 << 20),
        seen.add,
        runs: 50,
        seed: 1,
        environment: const {'CAP_PROP_RUNS': '2', 'CAP_PROP_SEED': '900'},
      );
      expect(seen, [
        ints(0, 1 << 20).sample(Rand(900)),
        ints(0, 1 << 20).sample(Rand(901)),
      ]);
    });

    test('a malformed override is an error, not a silent default', () async {
      await expectLater(
        checkProperty(
          'env',
          ints(0, 1),
          (_) {},
          environment: const {'CAP_PROP_RUNS': 'lots'},
        ),
        throwsArgumentError,
      );
    });
  });

  group('combinators', () {
    test('oneOf draws from every alternative', () {
      final gen = oneOf([
        choice(const ['a']),
        choice(const ['b']),
      ]);
      final r = Rand(3);
      final drawn = {for (var i = 0; i < 100; i++) gen.sample(r)};
      expect(drawn, {'a', 'b'});
    });

    test('frequency follows the weights and never draws weight 0', () {
      final gen = frequency([
        (9, choice(const ['common'])),
        (1, choice(const ['rare'])),
        (0, choice(const ['never'])),
      ]);
      final r = Rand(5);
      final counts = <String, int>{};
      for (var i = 0; i < 2000; i++) {
        counts.update(gen.sample(r), (n) => n + 1, ifAbsent: () => 1);
      }
      expect(counts.keys, unorderedEquals(['common', 'rare']));
      expect(counts['common']!, greaterThan(counts['rare']! * 5));
    });

    test('frequency rejects weights that cannot be drawn from', () {
      expect(() => frequency([(0, ints(0, 1))]), throwsArgumentError);
      expect(
        () => frequency([(2, ints(0, 1)), (-1, ints(0, 1))]),
        throwsArgumentError,
      );
      expect(() => oneOf(<Generator<int>>[]), throwsArgumentError);
    });

    test('oneOf shrinks through its alternatives', () async {
      await expectLater(
        checkProperty(
          'small or huge',
          oneOf([ints(0, 5), ints(500, 1000)]),
          (v) => expect(v, lessThan(600)),
          environment: _noEnv,
        ),
        throwsA(_failureSaying(['shrunk to:  600\n'])),
      );
    });
  });
}
