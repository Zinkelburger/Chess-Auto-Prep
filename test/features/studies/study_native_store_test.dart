import 'dart:io';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/studies/controllers/study_controller.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/studies/legacy_study_library_repository.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late NativePgnDocumentStore store;
  late StudyController study;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('study-native-');
    final storage = IOStorageService(
      documentsRoot: root,
      supportRoot: Directory('${root.path}/support'),
    );
    store = NativePgnDocumentStore();
    study = StudyController(
      library: LegacyStudyLibraryRepository(storage, store),
      documents: store,
    );
    await study.newStudy('Native');
  });
  tearDown(() async {
    study.dispose();
    await Future<void>.delayed(Duration.zero);
    await root.delete(recursive: true);
  });
  test('same-byte native replacement conflicts in the real editor', () async {
    final file = File(study.doc.filePath!);
    final bytes = await file.readAsBytes();
    study.setComment(TreePath.empty, 'local note');
    await File('${file.path}.replacement').writeAsBytes(bytes);
    await File('${file.path}.replacement').rename(file.path);
    expect(await study.save(), isA<PgnConflict>());
    expect(await file.readAsBytes(), bytes);
    expect(study.doc.toPgn(), contains('local note'));
    final recovery = study.saveError!;
    expect(recovery, contains('recovery copy'));
  });
  test(
    'rename retains captured revision and cannot accept unseen newer content',
    () async {
      final file = File(study.doc.filePath!);
      const external = '[Event "external"]\n\n1. d4 *';
      await file.writeAsString(external);
      await study.renameStudy('Renamed');
      study.setComment(TreePath.empty, 'stale note');
      expect(await study.save(), isA<PgnConflict>());
      expect(await File(study.doc.filePath!).readAsString(), external);
      expect(await file.exists(), isFalse);
    },
  );
  test(
    'rename of a captured file preserves its usable native revision',
    () async {
      await study.renameStudy('Renamed');
      study.setComment(TreePath.empty, 'new note');
      expect(await study.save(), isA<PgnSaved>());
      expect(
        await File(study.doc.filePath!).readAsString(),
        contains('new note'),
      );
    },
  );
  test(
    'uncertain native acknowledgement requires reload before another save',
    () async {
      // Fail only the final parent-directory flush, after the namespace commit.
      study.dispose();
      final storage = IOStorageService(
        documentsRoot: root,
        supportRoot: Directory('${root.path}/support'),
      );
      var fail = false;
      final uncertainStore = NativePgnDocumentStore(
        flushDirectory: (path) async {
          if (fail && !path.contains('.cap-pgn-history')) {
            throw const FileSystemException('acknowledgement');
          }
        },
      );
      study = StudyController(
        library: LegacyStudyLibraryRepository(storage, uncertainStore),
        documents: uncertainStore,
      );
      final path = await storage.studyFilePath('Native');
      await study.openStudy(path);
      study.setComment(TreePath.empty, 'committed but uncertain');
      fail = true;
      expect(await study.save(), isA<PgnWriteUncertain>());
      final bytes = await File(path).readAsBytes();
      study.setComment(TreePath.empty, 'later draft');
      expect(await study.save(), isNull);
      expect(await study.flushSave(), isFalse);
      expect(await File(path).readAsBytes(), bytes);
      fail = false;
      await study.reloadPreservingDraft();
      expect(study.doc.toPgn(), contains('committed but uncertain'));
      expect(
        study.state.retainedDrafts.single.content,
        contains('later draft'),
      );
      await study.restoreDraft(0);
      expect(await study.save(), isA<PgnSaved>());
      expect(await File(path).readAsString(), contains('later draft'));
    },
  );
}
