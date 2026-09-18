import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/training/move_attempt_store.dart';
import 'package:chess_auto_prep/services/storage/file_mutation_service.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// Baseline reproductions: intended safety assertions fail on 3acf6c3f.
// No production implementation or new test-only product seam is included.
void main() {
  late Directory profile;
  late Directory root;
  late File source;
  late File destination;

  setUp(() async {
    profile = await Directory.systemTemp.createTemp('chapter-move-red-');
    root = await Directory(p.join(profile.path, 'repertoires')).create();
    final folder = await Directory(p.join(root.path, 'Opening')).create();
    source = File(p.join(folder.path, 'Main.pgn'));
    destination = File(p.join(folder.path, 'Renamed.pgn'));
    await source.writeAsString('1. e4 e5 *');
  });
  tearDown(() => profile.delete(recursive: true));

  IOStorageService storage() => IOStorageService(
    documentsRoot: profile,
    supportRoot: profile,
    repertoiresRoot: root,
  );

  test('a destination created at native rename must survive', () async {
    final racedSource = _BeforeRenameFile(source, () async {
      await destination.writeAsString('1. d4 d5 *');
    });
    Object? failure;
    try {
      await FileMutationService().moveFileNoReplace(
        racedSource,
        destination,
        allowedRoot: root,
      );
    } catch (error) {
      failure = error;
    }
    expect(racedSource.renameCalls, 1, reason: 'race must reach real rename');
    expect(await destination.readAsString(), '1. d4 d5 *');
    expect(await source.readAsString(), '1. e4 e5 *');
    expect(failure, isNotNull);
  }, skip: !Platform.isLinux);

  test('equal-text replacement after capture remains at its source', () async {
    final documents = NativePgnDocumentStore();
    final captured = (await documents.open(source.path) as PgnOpened).snapshot;
    final replacement = File(p.join(root.path, 'replacement.pgn'));
    await replacement.writeAsString(captured.content);
    await replacement.rename(source.path);
    final winner = (await documents.open(source.path) as PgnOpened).snapshot;
    expect(winner.content, captured.content);
    expect(winner.revision, isNot(captured.revision));
    // The current picker/Outline API sends only captured.path after its prompt.
    await storage().renameFile(captured.path, destination.path);
    expect(
      await source.exists(),
      isTrue,
      reason: 'confirmation must not authorize moving a replacement inode',
    );
    expect(await destination.exists(), isFalse);
  }, skip: !Platform.isLinux);

  Future<void> seedReferences() async {
    for (final name in [
      'repertoire_reviews.csv',
      'repertoire_review_history.csv',
      'repertoire_move_progress.csv',
    ]) {
      await File(
        p.join(profile.path, name),
      ).writeAsString('repertoire_id,line_id\n${source.path},line\n');
    }
    await File(
      p.join(profile.path, 'repertoire_move_attempts.jsonl'),
    ).writeAsString(
      '${jsonEncode({'repertoireId': source.path, 'lineId': 'line'})}\n',
    );
  }

  test('a successful chapter rename migrates every training store', () async {
    await seedReferences();
    await storage().renameFile(source.path, destination.path);
    expect(await destination.readAsString(), '1. e4 e5 *');
    final attempts = File(
      p.join(profile.path, 'repertoire_move_attempts.jsonl'),
    );
    expect(await attempts.readAsString(), contains(destination.path));
    for (final name in [
      'repertoire_reviews.csv',
      'repertoire_review_history.csv',
      'repertoire_move_progress.csv',
    ]) {
      expect(
        await File(p.join(profile.path, name)).readAsString(),
        contains(destination.path),
        reason: name,
      );
    }
  }, skip: !Platform.isLinux);

  test(
    'late training attempt must not recreate a relocated chapter key',
    () async {
      await seedReferences();
      final currentStorage = storage();
      await currentStorage.renameFile(source.path, destination.path);
      try {
        await MoveAttemptStore(currentStorage).record(
          repertoireId: source.path,
          lineId: 'line',
          moveIndex: 0,
          fen: 'captured position',
          playedSan: 'e4',
          expectedSan: 'e4',
          correct: true,
          phase: 'drilling',
        );
      } catch (_) {
        // Explicit stale-session refusal is also safe; silent old-key append is not.
      }
      expect(
        await MoveAttemptStore(currentStorage).load(repertoireId: source.path),
        isEmpty,
      );
    },
    skip: !Platform.isLinux,
  );

  test(
    'restart finishes references after an admitted file move fails',
    () async {
      await seedReferences();
      final failing = _FailAttemptUpdate(profile, root);
      await expectLater(
        failing.renameFile(source.path, destination.path),
        throwsStateError,
      );
      expect(failing.failed, isTrue);
      expect(await source.exists(), isFalse);
      expect(await destination.readAsString(), '1. e4 e5 *');
      // Existing library recovery is the durable owner used after restart.
      await storage().listRepertoires();
      expect(
        await File(
          p.join(profile.path, 'repertoire_move_attempts.jsonl'),
        ).readAsString(),
        contains(destination.path),
        reason: 'a moved file must not permanently strand its old references',
      );
    },
    skip: !Platform.isLinux,
  );
}

// Delegate real filesystem behavior, scheduling the external actor at the
// precise check/rename boundary without changing production code.
class _BeforeRenameFile implements File {
  _BeforeRenameFile(this.file, this.beforeRename);
  final File file;
  final Future<void> Function() beforeRename;
  int renameCalls = 0;
  @override
  String get path => file.path;
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<String> resolveSymbolicLinks() => file.resolveSymbolicLinks();
  @override
  Future<File> rename(String newPath) async {
    renameCalls++;
    await beforeRename();
    return file.rename(newPath);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailAttemptUpdate extends IOStorageService {
  _FailAttemptUpdate(Directory profile, Directory root)
    : super(
        documentsRoot: profile,
        supportRoot: profile,
        repertoiresRoot: root,
      );
  bool failed = false;
  @override
  Future<String> updateFile(
    String path,
    FutureOr<String> Function(String?) update,
  ) async {
    if (path == 'repertoire_move_attempts.jsonl') {
      failed = true;
      throw StateError('Injected first reference write failure');
    }
    return super.updateFile(path, update);
  }
}
