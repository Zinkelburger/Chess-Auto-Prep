import 'dart:async';

import 'package:chess_auto_prep/chess_core/pgn/pgn_slice_filter.dart';
import 'package:chess_auto_prep/features/documents/controllers/viewer_filter_controller.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_collection_filter.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:flutter_test/flutter_test.dart';

const games = <GameRecord>[
  (headers: {'White': 'First'}, pgnText: '1. e4 e5 *'),
  (headers: {'White': 'Second'}, pgnText: '1. d4 d5 *'),
];
const first = SliceConfig(
  headerFilters: [
    HeaderFilterConfig(field: 'White', mode: MatchMode.exact, value: 'First'),
  ],
);
const second = SliceConfig(
  headerFilters: [
    HeaderFilterConfig(field: 'White', mode: MatchMode.exact, value: 'Second'),
  ],
);

class Request {
  Request(this.config, this.games, this.index);
  final SliceConfig config;
  final List<GameRecord> games;
  final Map<String, List<int>>? index;
  final result = Completer<List<int>>();
}

class Matcher implements PgnCollectionFilter {
  final requests = <Request>[];
  @override
  Future<List<int>> match(
    SliceConfig config,
    List<GameRecord> games, {
    Map<String, List<int>>? fenIndex,
  }) {
    final request = Request(config, games, fenIndex);
    requests.add(request);
    return request.result.future;
  }
}

void main() {
  late Matcher matcher;
  late ViewerFilterController owner;
  setUp(() {
    matcher = Matcher();
    owner = ViewerFilterController(matcher);
  });

  test(
    'malformed decoded config releases loading before any worker starts',
    () async {
      final malformed = SliceConfig.fromJsonString(
        '{"additionalPositions":[42]}',
      );
      expect(await owner.compute(malformed, () => games), isNull);
      expect(owner.isLoading, isFalse);
      expect(owner.error, isA<TypeError>());
      expect(matcher.requests, isEmpty);
      expect(owner.selection.active, isFalse);
    },
  );

  test('latest request wins even if older matching finishes last', () async {
    final a = owner.compute(first, () => games);
    final b = owner.compute(second, () => games);
    matcher.requests[1].result.complete([1]);
    final accepted = await b;
    expect(accepted!.indices, [1]);
    matcher.requests[0].result.complete([0]);
    expect(await a, isNull);
    expect(owner.selection, same(accepted));
    expect(owner.selection.config.toJsonString(), second.toJsonString());
  });

  test(
    'old errors cannot release a newer request or publish a failure',
    () async {
      final a = owner.compute(first, () => games);
      final b = owner.compute(second, () => games);
      matcher.requests[0].result.completeError(StateError('old failure'));
      expect(await a, isNull);
      expect(owner.isLoading, isTrue);
      expect(owner.error, isNull);
      matcher.requests[1].result.complete([1]);
      await b;
      expect(owner.isLoading, isFalse);
    },
  );

  test(
    'reapplying an identical selection still revokes pending work',
    () async {
      owner.apply([0], first, 2);
      final selection = owner.selection;
      final pending = owner.compute(second, () => games);
      expect(owner.apply([0], first, 2), isFalse);
      matcher.requests.single.result.complete([1]);
      expect(await pending, isNull);
      expect(owner.selection, same(selection));
      expect(owner.isLoading, isFalse);
    },
  );

  test(
    'failure preserves the accepted selection and retry can succeed',
    () async {
      owner.apply([0], first, 2);
      final selection = owner.selection;
      final pending = owner.compute(second, () => games);
      matcher.requests.single.result.completeError(
        StateError('worker unavailable'),
      );
      expect(await pending, isNull);
      expect(owner.selection, same(selection));
      expect(owner.error, isA<StateError>());
      expect(owner.isLoading, isFalse);
      final retry = owner.compute(second, () => games);
      matcher.requests.last.result.complete([1]);
      await retry;
      expect(owner.selection.indices, [1]);
      expect(owner.error, isNull);
    },
  );

  test(
    'reset and disposal revoke results without losing lifecycle boundaries',
    () async {
      owner.apply([0], first, 2);
      final pending = owner.compute(second, () => games);
      owner.reset();
      matcher.requests.single.result.complete([1]);
      expect(await pending, isNull);
      expect(owner.selection.active, isFalse);
      expect(owner.selection.indices, isNull);
      final next = owner.compute(first, () => games);
      owner.dispose();
      matcher.requests.last.result.completeError(StateError('disposed worker'));
      expect(await next, isNull);
      expect(await owner.compute(first, () => games), isNull);
      expect(owner.apply([0], first, 2), isFalse);
      expect(matcher.requests, hasLength(2));
    },
  );

  test(
    'saved empty results fall back; deliberate empty results remain active',
    () async {
      final restore = owner.compute(first, () => games, restoring: true);
      matcher.requests.single.result.complete([]);
      expect(await restore, isNull);
      expect(owner.selection.active, isFalse);
      expect(owner.pendingRestore, isNull);
      expect(owner.isLoading, isFalse);
      final search = owner.compute(first, () => games);
      matcher.requests.last.result.complete([]);
      await search;
      expect(owner.selection.indices, isEmpty);
      expect(owner.selection.active, isTrue);
      final all = owner.compute(first, () => games, restoring: true);
      matcher.requests.last.result.complete([0, 1]);
      await all;
      expect(owner.selection.active, isTrue);
      expect(owner.pendingRestore!.filteredCount, 2);
      owner.clearPendingRestore();
      expect(owner.pendingRestore, isNull);
    },
  );

  test(
    'captures caller-owned config, () => records, results and queried index entries',
    () async {
      final headers = {'White': 'Original'};
      final records = <GameRecord>[(headers: headers, pgnText: '1. e4 *')];
      final filters = [
        const HeaderFilterConfig(
          field: 'White',
          mode: MatchMode.exact,
          value: 'Original',
        ),
      ];
      final positions = ['1. e4'];
      final target = parseTargetFen('1. e4')!;
      final indices = [0];
      final index = {
        target: indices,
        'unused index': <int>[9],
      };
      final pending = owner.compute(
        SliceConfig(headerFilters: filters, additionalPositions: positions),
        () => records,
        fenIndex: () => index,
      );
      headers['White'] = 'Mutated';
      records.clear();
      filters.clear();
      positions.clear();
      indices.clear();
      final request = matcher.requests.single;
      expect(request.games.single.headers['White'], 'Original');
      expect(request.config.headerFilters.single.value, 'Original');
      expect(request.config.additionalPositions, ['1. e4']);
      expect(request.index, {
        target: [0],
      });
      final result = [0];
      request.result.complete(result);
      await pending;
      result.clear();
      expect(owner.selection.indices, [0]);
      expect(() => owner.selection.indices!.clear(), throwsUnsupportedError);
      expect(
        () => owner.selection.config.headerFilters.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => request.games.single.headers.clear(),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'invalid worker indices fail atomically and keep the previous selection',
    () async {
      owner.apply([1], second, 2);
      final accepted = owner.selection;
      for (final invalid in [
        [-1],
        [2],
        [0, 0],
      ]) {
        final pending = owner.compute(first, () => games);
        matcher.requests.last.result.complete(invalid);
        expect(await pending, isNull);
        expect(owner.error, isA<ArgumentError>());
        expect(owner.selection, same(accepted));
      }
      expect(() => owner.apply([7], first, 2), throwsArgumentError);
      expect(owner.selection, same(accepted));
    },
  );

  for (final failOld in [false, true]) {
    test(
      'changed records recompute the same intent after an old ${failOld ? 'failure' : 'result'}',
      () async {
        var current = games;
        final pending = owner.compute(first, () => current);
        current = [
          (headers: {'White': 'Updated'}, pgnText: '1. c4 *'),
        ];
        owner.sourceChanged();
        if (failOld) {
          matcher.requests.single.result.completeError(StateError('obsolete'));
        } else {
          matcher.requests.single.result.complete([1]);
        }
        await Future<void>.delayed(Duration.zero);
        expect(matcher.requests, hasLength(2));
        expect(matcher.requests.last.games.single.headers['White'], 'Updated');
        expect(owner.isLoading, isTrue);
        matcher.requests.last.result.complete([0]);
        expect((await pending)!.indices, [0]);
        expect(owner.error, isNull);
      },
    );
  }

  test(
    'navigation snapshots retain config and distinguish partial empty filters',
    () {
      owner.apply([0], const SliceConfig.empty(), 1);
      expect(owner.selection.active, isFalse);
      expect(owner.apply([0], const SliceConfig.empty(), 2), isTrue);
      expect(owner.selection.active, isTrue);
      final captured = owner.selection;
      owner.reset();
      owner.restoreSelection(captured);
      expect(owner.selection, same(captured));
    },
  );

  test('player presets and chip removal preserve other filter dimensions', () {
    const config = SliceConfig(
      positionInput: '1. e4',
      additionalPositions: ['1. d4'],
      matchAny: true,
      sequencePattern: 'e4 [gap] Nf3',
      sequenceGap: 8,
      headerFilters: [
        HeaderFilterConfig(
          field: 'White',
          mode: MatchMode.exact,
          value: 'Player',
        ),
      ],
    );
    owner.apply([0], config, 2);
    const black = HeaderFilterConfig(
      field: 'Black',
      mode: MatchMode.contains,
      value: 'Player',
    );
    final preset = owner.withPreset(black);
    expect(preset.headerFilters, [black]);
    expect(preset.additionalPositions, ['1. d4']);
    expect(preset.matchAny, isTrue);
    expect(preset.sequenceGap, 8);
    expect(owner.withoutChip(0)!.positionInput, isNull);
    expect(owner.withoutChip(0)!.additionalPositions, ['1. d4']);
    expect(owner.withoutChip(99), isNull);
  });
}
