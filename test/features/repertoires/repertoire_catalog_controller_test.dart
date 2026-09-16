import 'dart:async';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_recovery_entry.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_recovery_required.dart';

import 'package:chess_auto_prep/features/repertoires/controllers/repertoire_catalog_controller.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_creation.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_catalog_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

RepertoireMetadata entry(String name, [int day = 1]) => RepertoireMetadata(
  filePath: '/$name',
  name: name,
  lastModified: DateTime(2026, 9, day),
);

class Catalog implements RepertoireCatalogRepository {
  @override
  bool get supportsRecovery => true;
  List<RepertoireRecoveryEntry> recovery = [];
  @override
  Future<List<RepertoireRecoveryEntry>> listRecovery() async => recovery;
  @override
  Future<void> restore(String id, {String? name}) async {
    writes++;
    await write?.call();
    final item = recovery.singleWhere((r) => r.id == id);
    entries = [...entries, entry(name ?? item.name)];
    recovery = recovery.where((r) => r.id != id).toList();
  }

  List<RepertoireMetadata> entries = [entry('Old'), entry('New', 2)];
  Future<List<RepertoireMetadata>> Function()? read;
  Future<void> Function()? write;
  bool throwSynchronously = false;
  int reads = 0;
  int writes = 0;
  int studyReads = 0;

  @override
  Future<List<RepertoireMetadata>> listRepertoires() {
    reads++;
    if (throwSynchronously) throw StateError('synchronous failure');
    return read == null ? Future.value(entries) : read!();
  }

  @override
  Future<List<RepertoireMetadata>> listStudies() async {
    studyReads++;
    return [entry('Study')];
  }

  @override
  Future<RepertoireCreationResult> create(CreateRepertoire request) async {
    writes++;
    await write?.call();
    entries = [...entries, entry(request.name, 3)];
    return RepertoireCreationResult(
      directoryPath: '/${request.name}',
      chapterPath: '/${request.name}/Main.pgn',
      gameCount: 0,
    );
  }

  @override
  Future<void> rename(RepertoireMetadata repertoire, String name) async {
    writes++;
    await write?.call();
    entries = [
      for (final item in entries)
        if (item == repertoire) entry(name) else item,
    ];
  }

  @override
  Future<void> moveToRecovery(RepertoireMetadata repertoire) async {
    writes++;
    await write?.call();
    entries = entries.where((item) => item != repertoire).toList();
  }
}

void main() {
  late Catalog repository;
  late ProviderContainer container;
  final provider = repertoireCatalogProvider(false);

  setUp(() {
    repository = Catalog();
    container = ProviderContainer(
      overrides: [
        repertoireCatalogRepositoryProvider.overrideWithValue(repository),
      ],
      retry: (count, error) => null,
    );
  });
  tearDown(() => container.dispose());

  Future<RepertoireCatalogController> ready() async {
    container.listen(provider, (_, _) {});
    await container.pump();
    await container.read(provider.notifier).refresh();
    return container.read(provider.notifier);
  }

  test(
    'restore retains recovery on failure and refreshes both lists after commit',
    () async {
      repository.recovery = [
        RepertoireRecoveryEntry(
          id: '1-ab',
          name: 'Deleted',
          originalPath: '/Deleted',
          deletedAt: DateTime(2026),
          available: true,
        ),
      ];
      final controller = await ready();
      expect(container.read(provider).recovery, hasLength(1));
      repository.write = () async => throw StateError('collision');
      await expectLater(controller.restore('1-ab'), throwsStateError);
      expect(container.read(provider).recovery, hasLength(1));
      expect(container.read(provider).actionError, isA<StateError>());
      repository.write = null;
      await controller.restore('1-ab', name: 'Recovered');
      expect(container.read(provider).recovery, isEmpty);
      expect(
        container.read(provider).repertoires.map((r) => r.name),
        contains('Recovered'),
      );
      expect(container.read(provider).actionError, isNull);
    },
  );

  test(
    'recovery refresh clears its error only after a confirmed read and never repeats rename',
    () async {
      final controller = await ready();
      repository.write = () async =>
          throw const RepertoireRecoveryRequired('operation', 'interrupted');
      await expectLater(
        controller.rename(repository.entries.first, 'Renamed'),
        throwsA(isA<RepertoireRecoveryRequired>()),
      );
      repository.read = () async =>
          throw const RepertoireRecoveryRequired('operation', 'still pending');
      await controller.refresh();
      expect(
        container.read(provider).actionError,
        isA<RepertoireRecoveryRequired>(),
      );
      repository.read = () async => [entry('Renamed')];
      await controller.refresh();
      expect(container.read(provider).actionError, isNull);
      expect(container.read(provider).loadError, isNull);
      expect(container.read(provider).repertoires.single.name, 'Renamed');
      expect(repository.writes, 1);
    },
  );

  test(
    'sorts copies, exposes immutable lists, and omits unused study IO',
    () async {
      await ready();
      expect(container.read(provider).repertoires.map((e) => e.name), [
        'New',
        'Old',
      ]);
      expect(repository.entries.first.name, 'Old');
      expect(repository.studyReads, 0);
      expect(
        () => container.read(provider).repertoires.clear(),
        throwsUnsupportedError,
      );
    },
  );

  test('synchronous read failure does not prevent explicit retry', () async {
    final controller = await ready();
    repository.throwSynchronously = true;
    await controller.refresh();
    expect(container.read(provider).loadError, isStateError);
    repository.throwSynchronously = false;
    await controller.refresh();
    expect(container.read(provider).loadError, isNull);
    expect(container.read(provider).repertoires, hasLength(2));
  });

  test('trainer catalog includes studies', () async {
    final trainer = repertoireCatalogProvider(true);
    container.listen(trainer, (_, _) {});
    await container.pump();
    await container.read(trainer.notifier).refresh();
    expect(container.read(trainer).studies.single.name, 'Study');
  });

  test(
    'coalesces refresh and preserves last good list on read failure',
    () async {
      final controller = await ready();
      final pending = Completer<List<RepertoireMetadata>>();
      repository.read = () => pending.future;
      final before = repository.reads;
      final first = controller.refresh();
      final second = controller.refresh();
      expect(repository.reads, before + 1);
      pending.completeError(StateError('offline'));
      await Future.wait([first, second]);
      expect(container.read(provider).loadError, isStateError);
      expect(container.read(provider).repertoires, hasLength(2));
      repository.read = null;
      await controller.refresh();
      expect(container.read(provider).loadError, isNull);
    },
  );

  test(
    'rejects overlapping actions; one confirmed create and no automatic retry',
    () async {
      final controller = await ready();
      final pending = Completer<void>();
      repository.write = () => pending.future;
      final first = controller.create(
        const CreateRepertoire(name: 'Caro', color: 'Black'),
      );
      expect(container.read(provider).busy, isTrue);
      await expectLater(
        controller.create(
          const CreateRepertoire(name: 'Duplicate', color: 'White'),
        ),
        throwsStateError,
      );
      await expectLater(
        controller.moveToRecovery(repository.entries.first),
        throwsStateError,
      );
      expect(repository.writes, 1);
      pending.complete();
      await first;
      expect(container.read(provider).busy, isFalse);
      expect(container.read(provider).repertoires.first.name, 'Caro');
    },
  );

  test('failed write remains failed until explicit retry', () async {
    final controller = await ready();
    repository.write = () async => throw StateError('disk');
    await expectLater(
      controller.rename(repository.entries.first, 'Renamed'),
      throwsStateError,
    );
    await container.pump();
    expect(repository.writes, 1);
    expect(container.read(provider).actionError, isStateError);
    expect(container.read(provider).busy, isFalse);
    repository.write = null;
    await controller.rename(repository.entries.first, 'Renamed');
    expect(repository.writes, 2);
    expect(container.read(provider).actionError, isNull);
  });

  test('confirmed commit succeeds even when catalog refresh fails', () async {
    final controller = await ready();
    repository.read = () async => throw StateError('read failed');
    final result = await controller.create(
      const CreateRepertoire(name: 'Saved', color: 'White'),
    );
    expect(result.directoryPath, '/Saved');
    expect(repository.writes, 1);
    expect(container.read(provider).loadError, isStateError);
    expect(container.read(provider).actionError, isNull);
  });

  test(
    'read begun before mutation cannot resurrect a deleted repertoire',
    () async {
      final controller = await ready();
      final pending = Completer<List<RepertoireMetadata>>();
      final stale = [...repository.entries];
      repository.read = () => pending.future;
      final read = controller.refresh();
      repository.read = null;
      await controller.moveToRecovery(repository.entries.first);
      pending.complete(stale);
      await read;
      expect(container.read(provider).repertoires.map((e) => e.name), ['New']);
    },
  );

  test('disposing scope during a read ignores the late result', () async {
    final controller = await ready();
    final pending = Completer<List<RepertoireMetadata>>();
    repository.read = () => pending.future;
    final read = controller.refresh();
    container.dispose();
    pending.complete([entry('Late')]);
    await read;
  });

  test(
    'in-flight commit survives loss of every listener exactly once',
    () async {
      final subscription = container.listen(provider, (_, _) {});
      await container.pump();
      final controller = container.read(provider.notifier);
      await controller.refresh();
      final pending = Completer<void>();
      repository.write = () => pending.future;
      final save = controller.create(
        const CreateRepertoire(name: 'Offscreen', color: 'White'),
      );
      subscription.close();
      await container.pump();
      pending.complete();
      await save;
      await container.pump();
      expect(repository.writes, 1);
      expect(repository.entries.last.name, 'Offscreen');
    },
  );
}
