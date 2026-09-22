import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/training/models/chapter_layout.dart'
    show ChapterSummary;
import 'dart:async';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_recovery_entry.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_recovery_required.dart';

import 'package:chess_auto_prep/features/repertoires/controllers/repertoire_catalog_controller.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_creation.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_catalog_repository.dart';
import 'package:flutter_test/flutter_test.dart';

RepertoireMetadata entry(String name, [int day = 1]) => RepertoireMetadata(
  filePath: '/$name',
  name: name,
  lastModified: DateTime(2026, 9, day),
);

class Catalog implements RepertoireCatalogRepository {
  @override
  Future<PgnOpenResult> prepareChapterDeletion(String path) async =>
      const PgnMissing();
  @override
  Future<PgnQuarantineResult> deleteChapter(PgnSnapshot baseline) async =>
      PgnQuarantineFailed(UnsupportedError('Fixture deletion unavailable'));
  @override
  Future<List<ChapterSummary>> chapterSections(String path) async => [];
  @override
  Future<PgnWriteResult> createChapter({
    required String folderPath,
    required String name,
    bool? isWhite,
  }) async => PgnWriteFailed(UnimplementedError());
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
  Object? studyError;

  @override
  Future<List<RepertoireMetadata>> listRepertoires() {
    reads++;
    if (throwSynchronously) throw StateError('synchronous failure');
    return read == null ? Future.value(entries) : read!();
  }

  @override
  Future<List<RepertoireMetadata>> listChapters(String folderPath) async => [];

  @override
  Future<List<RepertoireMetadata>> listStudies() async {
    studyReads++;
    if (studyError case final error?) throw error;
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
  late RepertoireCatalogController catalog;
  setUp(() {
    repository = Catalog();
    catalog = RepertoireCatalogController(repository);
  });
  tearDown(() {
    if (!catalog.isDisposed) catalog.dispose();
  });

  Future<RepertoireCatalogController> ready() async {
    await catalog.refresh();
    return catalog;
  }

  for (final fail in [false, true]) {
    test(
      'first trainer entry during a ${fail ? "failed" : "successful"} library mutation completes its read',
      () async {
        await ready();
        final gate = Completer<void>();
        repository.write = () => gate.future;
        final write = catalog.create(
          const CreateRepertoire(name: 'Saved', color: 'White'),
        );
        final settled = fail ? expectLater(write, throwsStateError) : write;
        await catalog.refresh(includeStudies: true);
        expect(catalog.snapshot(includeStudies: true).loading, true);
        await expectLater(
          catalog.rename(
            repository.entries.first,
            'Overlap',
            includeStudies: true,
          ),
          throwsStateError,
        );
        expect(repository.writes, 1);
        if (fail) {
          gate.completeError(StateError('disk'));
        } else {
          gate.complete();
        }
        await settled;
        expect(catalog.snapshot(includeStudies: true).loading, false);
        expect(
          catalog.snapshot(includeStudies: true).studies.single.name,
          'Study',
        );
        expect(repository.writes, 1);
        expect(catalog.snapshot().actionError, fail ? isStateError : isNull);
      },
    );
  }

  test(
    'read errors remain local to their catalog kind and explicit retry clears them',
    () async {
      repository.studyError = StateError('study read');
      await catalog.refresh(includeStudies: true);
      await catalog.refresh();
      expect(catalog.snapshot().loadError, isNull);
      expect(catalog.snapshot(includeStudies: true).loadError, isStateError);
      repository.studyError = null;
      await catalog.refresh(includeStudies: true);
      expect(catalog.snapshot(includeStudies: true).loadError, isNull);
    },
  );

  test(
    'failed library mutation restarts an earlier trainer read and rejects its late completion',
    () async {
      await ready();
      final gate = Completer<List<RepertoireMetadata>>();
      repository.read = () => gate.future;
      final stale = catalog.refresh(includeStudies: true);
      repository.read = null;
      repository.write = () async => throw StateError('disk');
      await expectLater(
        catalog.create(const CreateRepertoire(name: 'Failed', color: 'White')),
        throwsStateError,
      );
      expect(
        catalog.snapshot(includeStudies: true).studies.single.name,
        'Study',
      );
      expect(catalog.snapshot(includeStudies: true).loading, false);
      gate.complete([entry('Obsolete')]);
      await stale;
      expect(
        catalog.snapshot(includeStudies: true).repertoires.map((r) => r.name),
        ['New', 'Old'],
      );
      expect(catalog.snapshot().actionError, isStateError);
      expect(repository.writes, 1);
    },
  );

  test('a library mutation invalidates an older trainer read', () async {
    await ready();
    final gate = Completer<List<RepertoireMetadata>>();
    final stale = List<RepertoireMetadata>.of(repository.entries);
    repository.read = () => gate.future;
    final trainer = catalog.refresh(includeStudies: true);
    repository.read = null;
    await catalog.moveToRecovery(repository.entries.first);
    gate.complete(stale);
    await trainer;
    expect(catalog.snapshot().repertoires.map((r) => r.name), ['New']);
    expect(
      catalog.snapshot(includeStudies: true).repertoires.map((r) => r.name),
      ['New'],
    );
  });

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
      expect(catalog.snapshot().recovery, hasLength(1));
      repository.write = () async => throw StateError('collision');
      await expectLater(controller.restore('1-ab'), throwsStateError);
      expect(catalog.snapshot().recovery, hasLength(1));
      expect(catalog.snapshot().actionError, isA<StateError>());
      repository.write = null;
      await controller.restore('1-ab', name: 'Recovered');
      expect(catalog.snapshot().recovery, isEmpty);
      expect(
        catalog.snapshot().repertoires.map((r) => r.name),
        contains('Recovered'),
      );
      expect(catalog.snapshot().actionError, isNull);
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
      expect(catalog.snapshot().actionError, isA<RepertoireRecoveryRequired>());
      repository.read = () async => [entry('Renamed')];
      await controller.refresh();
      expect(catalog.snapshot().actionError, isNull);
      expect(catalog.snapshot().loadError, isNull);
      expect(catalog.snapshot().repertoires.single.name, 'Renamed');
      expect(repository.writes, 1);
    },
  );

  test(
    'sorts copies, exposes immutable lists, and omits unused study IO',
    () async {
      await ready();
      expect(catalog.snapshot().repertoires.map((e) => e.name), ['New', 'Old']);
      expect(repository.entries.first.name, 'Old');
      expect(repository.studyReads, 0);
      expect(
        () => catalog.snapshot().repertoires.clear(),
        throwsUnsupportedError,
      );
    },
  );

  test('synchronous read failure does not prevent explicit retry', () async {
    final controller = await ready();
    repository.throwSynchronously = true;
    await controller.refresh();
    expect(catalog.snapshot().loadError, isStateError);
    repository.throwSynchronously = false;
    await controller.refresh();
    expect(catalog.snapshot().loadError, isNull);
    expect(catalog.snapshot().repertoires, hasLength(2));
  });

  test('trainer catalog includes studies', () async {
    await catalog.refresh(includeStudies: true);
    expect(catalog.snapshot(includeStudies: true).studies.single.name, 'Study');
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
      expect(catalog.snapshot().loadError, isStateError);
      expect(catalog.snapshot().repertoires, hasLength(2));
      repository.read = null;
      await controller.refresh();
      expect(catalog.snapshot().loadError, isNull);
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
      expect(catalog.snapshot().busy, isTrue);
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
      expect(catalog.snapshot().busy, isFalse);
      expect(catalog.snapshot().repertoires.first.name, 'Caro');
    },
  );

  test('failed write remains failed until explicit retry', () async {
    final controller = await ready();
    repository.write = () async => throw StateError('disk');
    await expectLater(
      controller.rename(repository.entries.first, 'Renamed'),
      throwsStateError,
    );
    await Future<void>.delayed(Duration.zero);
    expect(repository.writes, 1);
    expect(catalog.snapshot().actionError, isStateError);
    expect(catalog.snapshot().busy, isFalse);
    repository.write = null;
    await controller.rename(repository.entries.first, 'Renamed');
    expect(repository.writes, 2);
    expect(catalog.snapshot().actionError, isNull);
  });

  test('confirmed commit succeeds even when catalog refresh fails', () async {
    final controller = await ready();
    repository.read = () async => throw StateError('read failed');
    final result = await controller.create(
      const CreateRepertoire(name: 'Saved', color: 'White'),
    );
    expect(result.directoryPath, '/Saved');
    expect(repository.writes, 1);
    expect(catalog.snapshot().loadError, isStateError);
    expect(catalog.snapshot().actionError, isNull);
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
      expect(catalog.snapshot().repertoires.map((e) => e.name), ['New']);
    },
  );

  test('disposing scope during a read ignores the late result', () async {
    final controller = await ready();
    final pending = Completer<List<RepertoireMetadata>>();
    repository.read = () => pending.future;
    final read = controller.refresh();
    catalog.dispose();
    pending.complete([entry('Late')]);
    await read;
  });

  test(
    'in-flight commit survives loss of every listener exactly once',
    () async {
      void listener() {}
      catalog.addListener(listener);
      final controller = catalog;
      await controller.refresh();
      final pending = Completer<void>();
      repository.write = () => pending.future;
      final save = controller.create(
        const CreateRepertoire(name: 'Offscreen', color: 'White'),
      );
      catalog.removeListener(listener);
      await Future<void>.delayed(Duration.zero);
      pending.complete();
      await save;
      await Future<void>.delayed(Duration.zero);
      expect(repository.writes, 1);
      expect(repository.entries.last.name, 'Offscreen');
    },
  );
}
