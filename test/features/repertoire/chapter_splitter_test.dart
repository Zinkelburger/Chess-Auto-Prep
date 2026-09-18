import 'dart:async';
import 'dart:io';
import 'package:chess_auto_prep/features/repertoire/services/course_chapter_partition.dart';

import 'package:chess_auto_prep/features/repertoire/services/chapter_splitter.dart';
import 'package:chess_auto_prep/models/repertoire_review_entry.dart';
import 'package:chess_auto_prep/services/repertoire_review_service.dart';
import 'package:chess_auto_prep/services/repertoire_service.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/repertoire/services/review_progress_repointer.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Review CSVs in memory. The real ones live in the user's `~/Documents`,
/// which a test must not touch; everything else runs against a real temp
/// directory, because a split is a file-system operation.
class _CsvStorage implements StorageService {
  String? reviews;
  String? moveProgress;

  @override
  Future<String?> readRepertoireReviewsCsv() async => reviews;
  @override
  Future<void> saveRepertoireReviewsCsv(String csv) async => reviews = csv;
  @override
  Future<String?> readRepertoireMoveProgressCsv() async => moveProgress;
  @override
  Future<void> saveRepertoireMoveProgressCsv(String csv) async =>
      moveProgress = csv;

  final Map<String, String> backups = {};
  @override
  Future<String?> readFile(String path) async => switch (path) {
    'repertoire_reviews.csv' => reviews,
    'repertoire_move_progress.csv' => moveProgress,
    _ => backups[path],
  };
  @override
  Future<bool> fileExists(String path) async => await readFile(path) != null;
  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    backups[path] = content;
  }

  @override
  Future<String> updateFile(
    String path,
    FutureOr<String> Function(String?) update,
  ) async {
    final next = await update(await readFile(path));
    if (path == 'repertoire_reviews.csv') reviews = next;
    if (path == 'repertoire_move_progress.csv') moveProgress = next;
    return next;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A course-export game: the chapter in [White], the variation in [Black],
/// [Result] always `*`. [EventDate] is there on purpose — every Chessable
/// export carries it, and it is what used to cut games in half.
String _game(String chapter, String variation, String moves) =>
    '[Event "Lifetime Repertoires"]\n'
    '[White "$chapter"]\n'
    '[Black "$variation"]\n'
    '[Result "*"]\n'
    '[EventDate "2024.??.??"]\n\n'
    '$moves *\n';

/// A real game the author included as illustration: a decisive result, so it
/// belongs to no chapter.
String _modelGame(String moves) =>
    '[Event "Bertok-Fischer"]\n'
    '[White "Bertok"]\n'
    '[Black "Fischer"]\n'
    '[Result "0-1"]\n'
    '[EventDate "1962.??.??"]\n\n'
    '$moves 0-1\n';

class _ReplacingDocuments extends NativePgnDocumentStore {
  _ReplacingDocuments(this.source, this.replacement);
  final String source;
  final String replacement;
  @override
  Future<PgnWriteResult> create(String path, String content) async {
    final result = await super.create(path, content);
    if (p.basename(path) == 'Two.pgn') {
      final winner = File('$source.external');
      await winner.writeAsString(replacement);
      await winner.rename(source);
    }
    return result;
  }
}

class _ControlledDocuments extends NativePgnDocumentStore {
  @override
  bool supportsQuarantine = true;
  int createCalls = 0;
  int? failCreateAt;
  bool uncertainCreate = false;
  bool uncertainSource = false;
  @override
  Future<PgnWriteResult> create(String path, String content) async {
    createCalls++;
    if (createCalls == failCreateAt) {
      if (!uncertainCreate) {
        return PgnWriteFailed(StateError('destination unavailable'));
      }
      final result = await super.create(path, content);
      return PgnWriteUncertain(
        error: StateError('ack lost'),
        before: null,
        observed: result is PgnSaved ? result.after : null,
        recoveryPath: '$path.recovery',
      );
    }
    return super.create(path, content);
  }

  @override
  Future<PgnQuarantineResult> quarantine(
    PgnSnapshot baseline, {
    String? allowedRoot,
  }) async {
    if (uncertainSource) {
      return PgnQuarantineUncertain(
        error: StateError('quarantine ack lost'),
        before: baseline,
        quarantinePath: '${baseline.path}.retained',
        recoveryPath: '${baseline.path}.raw',
        observedSource: baseline,
        observedQuarantine: null,
      );
    }
    return super.quarantine(baseline, allowedRoot: allowedRoot);
  }
}

class _Repointer extends ReviewProgressRepointer {
  int calls = 0;
  Object? failure;
  @override
  Future<void> repoint({
    required String from,
    required Map<String, Set<String>> movedIdsByPath,
  }) async {
    calls++;
    if (failure case final error?) throw error;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String root;
  late String main_;
  late _CsvStorage csv;
  late ChapterSplitter splitter;

  const tartakower = '1. d4 d5 2. c4 e6 3. Nc3 Nf6 4. Bg5 Be7 5. e3 O-O';
  const catalan = '1. d4 d5 2. c4 e6 3. g3 Nf6 4. Bg2 Be7 5. Nf3 O-O';

  void writeMain(String body) =>
      File(main_).writeAsStringSync('// Main\n// Color: Black\n\n$body');

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('chapter_splitter_test');
    root = p.join(tmp.path, 'QGD');
    Directory(root).createSync();
    main_ = p.join(root, 'Main.pgn');
    csv = _CsvStorage();
    splitter = ChapterSplitter(
      documents: NativePgnDocumentStore(),
      storage: IOStorageService(
        documentsRoot: tmp,
        supportRoot: tmp,
        repertoiresRoot: Directory(root),
      ),
      review: RepertoireReviewService(storage: csv),
    );
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  List<String> chapterFiles() =>
      Directory(root).listSync().whereType<File>().map((f) => f.path).toList()
        ..sort();

  test(
    'promotes each [White] chapter to its own file, in course order',
    () async {
      writeMain(
        '${_game('1) Tartakower', 'cxd5 #1', tartakower)}\n'
        '${_game('1) Tartakower', 'cxd5 #2', '$tartakower 6. Nf3')}\n'
        '${_game('2) Catalan', 'Qc2 a6', catalan)}\n'
        '${_game('2) Catalan', 'Ne5 Nc6', '$catalan 6. O-O')}\n'
        '${_modelGame('1. d4 Nf6 2. c4 e6')}',
      );

      final result = await splitter.split(main_, isWhite: false);

      expect(result.createdPaths.map(p.basename), [
        '1) Tartakower.pgn',
        '2) Catalan.pgn',
      ]);
      expect(result.movedLines, 4);
      expect(result.remainingLines, 1);
      expect(result.sourceRemoved, isFalse);

      final service = RepertoireService();
      final tartakowerLines = service.parseRepertoirePgn(
        File(result.createdPaths.first).readAsStringSync(),
      );
      expect(tartakowerLines.map((l) => l.name), ['cxd5 #1', 'cxd5 #2']);

      // The colour of the source carries into the new chapters, so a later load
      // still knows which side the file trains.
      expect(
        File(result.createdPaths.first).readAsStringSync(),
        contains('// Color: Black'),
      );

      // The model game has no chapter of its own and stays put.
      final left = service.parseRepertoirePgn(File(main_).readAsStringSync());
      expect(left.single.isModelGame, isTrue);
    },
  );

  for (final leaveModel in [false, true]) {
    for (final sameText in [false, true]) {
      test(
        'source replacement during final destination survives (equal text: $sameText, remaining: $leaveModel)',
        () async {
          writeMain(
            '${_game('One', 'a', tartakower)}\n${_game('One', 'b', '$tartakower 6. Nf3')}\n${_game('Two', 'c', catalan)}\n${_game('Two', 'd', '$catalan 6. O-O')}'
            '${leaveModel ? _modelGame('1. e4 e5') : ''}',
          );
          final winner = sameText
              ? await File(main_).readAsString()
              : '// external winner\n${_modelGame('1. e4 e5')}';
          final repointer = _Repointer();
          final guarded = ChapterSplitter(
            documents: _ReplacingDocuments(main_, winner),
            repointer: repointer,
            storage: IOStorageService(
              documentsRoot: tmp,
              supportRoot: tmp,
              repertoiresRoot: Directory(root),
            ),
            review: RepertoireReviewService(storage: csv),
          );
          await expectLater(
            guarded.split(main_, isWhite: false),
            throwsA(isA<ChapterSplitException>()),
          );
          expect(await File(main_).readAsString(), winner);
          expect(repointer.calls, 0);
          expect(csv.reviews, isNull);
          expect(csv.moveProgress, isNull);
        },
      );
    }
  }

  void writeCourse() => writeMain(
    '${_game('One', 'a', tartakower)}\n${_game('One', 'b', '$tartakower 6. Nf3')}\n'
    '${_game('Two', 'c', catalan)}\n${_game('Two', 'd', '$catalan 6. O-O')}',
  );

  ChapterSplitter controlled(
    _ControlledDocuments documents,
    _Repointer repointer,
  ) => ChapterSplitter(
    documents: documents,
    repointer: repointer,
    storage: IOStorageService(
      documentsRoot: tmp,
      supportRoot: tmp,
      repertoiresRoot: Directory(root),
    ),
  );

  test(
    'unsupported quarantine refuses before creating any destination',
    () async {
      writeCourse();
      final documents = _ControlledDocuments()..supportsQuarantine = false;
      final repointer = _Repointer();
      await expectLater(
        controlled(documents, repointer).split(main_, isWhite: false),
        throwsA(
          isA<ChapterSplitException>().having(
            (e) => e.kind,
            'kind',
            ChapterSplitFailure.unsupported,
          ),
        ),
      );
      expect(documents.createCalls, 0);
      expect(chapterFiles().map(p.basename), ['Main.pgn']);
      expect(repointer.calls, 0);
    },
  );

  for (final uncertain in [false, true]) {
    test(
      'destination failure retains acknowledged paths and candidate (uncertain: $uncertain)',
      () async {
        writeCourse();
        final documents = _ControlledDocuments()
          ..failCreateAt = 2
          ..uncertainCreate = uncertain;
        final repointer = _Repointer();
        await expectLater(
          controlled(documents, repointer).split(main_, isWhite: false),
          throwsA(
            isA<ChapterSplitException>()
                .having((e) => e.createdPaths.map(p.basename), 'acknowledged', [
                  'One.pgn',
                ])
                .having(
                  (e) => e.pathsToInspect.first,
                  'candidate',
                  p.join(root, 'Two.pgn'),
                )
                .having(
                  (e) => e.sourceState,
                  'source',
                  ChapterSplitSourceState.unchanged,
                ),
          ),
        );
        expect(documents.createCalls, 2);
        expect(File(main_).existsSync(), isTrue);
        expect(repointer.calls, 0);
        expect(File(p.join(root, 'One.pgn')).existsSync(), isTrue);
        expect(File(p.join(root, 'Two.pgn')).existsSync(), uncertain);
      },
    );
  }

  test(
    'uncertain source mutation retains paths without moving progress',
    () async {
      writeCourse();
      final documents = _ControlledDocuments()..uncertainSource = true;
      final repointer = _Repointer();
      await expectLater(
        controlled(documents, repointer).split(main_, isWhite: false),
        throwsA(
          isA<ChapterSplitException>()
              .having((e) => e.createdPaths.length, 'saved', 2)
              .having(
                (e) => e.sourceState,
                'source',
                ChapterSplitSourceState.uncertain,
              )
              .having((e) => e.pathsToInspect, 'recovery', [
                main_,
                '$main_.retained',
                '$main_.raw',
              ]),
        ),
      );
      expect(repointer.calls, 0);
      expect(documents.createCalls, 2);
    },
  );

  test(
    'failed progress repoint reports committed files and retained source',
    () async {
      writeCourse();
      final documents = _ControlledDocuments();
      final repointer = _Repointer()
        ..failure = StateError('history write unavailable');
      ChapterSplitException? failure;
      try {
        await controlled(documents, repointer).split(main_, isWhite: false);
      } on ChapterSplitException catch (error) {
        failure = error;
      }
      expect(failure, isNotNull);
      expect(failure!.kind, ChapterSplitFailure.progress);
      expect(failure.sourceState, ChapterSplitSourceState.committed);
      expect(failure.sourceRemoved, isTrue);
      expect(failure.createdPaths, hasLength(2));
      expect(File(main_).existsSync(), isFalse);
      for (final path in [...failure.createdPaths, ...failure.pathsToInspect]) {
        expect(File(path).existsSync(), isTrue, reason: path);
      }
      expect(repointer.calls, 1);
    },
  );

  test('removes the source chapter when every line moved out', () async {
    writeMain(
      '${_game('One', 'a', tartakower)}\n'
      '${_game('One', 'b', '$tartakower 6. Nf3')}\n'
      '${_game('Two', 'c', catalan)}\n'
      '${_game('Two', 'd', '$catalan 6. O-O')}',
    );

    final result = await splitter.split(main_, isWhite: false);

    expect(result.sourceRemoved, isTrue);
    expect(result.remainingLines, 0);
    expect(File(main_).existsSync(), isFalse);
    expect(chapterFiles().map(p.basename), ['One.pgn', 'Two.pgn']);
  });

  test('makes filenames out of titles that are not filenames', () async {
    // A name already taken, so the split has to work around it.
    File(p.join(root, 'QGD Other Lines.pgn')).writeAsStringSync('// taken\n');
    writeMain(
      '${_game('QGD: Other Lines', 'a', tartakower)}\n'
      '${_game('QGD: Other Lines', 'b', '$tartakower 6. Nf3')}\n'
      '${_game('Reti / Neo-Catalan', 'c', catalan)}\n'
      '${_game('Reti / Neo-Catalan', 'd', '$catalan 6. O-O')}',
    );

    final result = await splitter.split(main_, isWhite: false);

    expect(result.createdPaths.map(p.basename), [
      'QGD Other Lines (2).pgn',
      'Reti Neo-Catalan.pgn',
    ]);
    expect(
      File(p.join(root, 'QGD Other Lines.pgn')).readAsStringSync(),
      '// taken\n',
    );
  });

  test(
    'carries each line\'s id and training progress to its new chapter',
    () async {
      writeMain(
        '${_game('One', 'a', tartakower)}\n'
        '${_game('One', 'b', '$tartakower 6. Nf3')}\n'
        '${_game('Two', 'c', catalan)}\n'
        '${_game('Two', 'd', '$catalan 6. O-O')}',
      );

      final service = RepertoireService();
      final before = service.parseRepertoirePgn(File(main_).readAsStringSync());
      // A line's fallback id encodes its position in the file, so the last one
      // is the id most likely to be lost by a move.
      final moved = before.last;
      csv.reviews =
          'repertoire_id,line_id,line_name,difficulty,interval_days,due_utc,'
          'last_rating,last_reviewed_utc,pass_count,fail_count,excluded\n'
          '${RepertoireReviewEntry(repertoireId: main_, lineId: moved.id, lineName: moved.name, intervalDays: 12, lastRating: 'good', passCount: 3, excluded: true).toCsvRow()}\n';

      final result = await splitter.split(main_, isWhite: false);
      final two = result.createdPaths.last;

      // Same id after the move, because it was pinned into the game.
      final after = service.parseRepertoirePgn(File(two).readAsStringSync());
      expect(after.map((l) => l.id), contains(moved.id));

      final entries = await RepertoireReviewService(storage: csv).loadAll();
      final entry = entries.singleWhere((e) => e.lineId == moved.id);
      expect(entry.repertoireId, two);
      expect(entry.intervalDays, 12);
      expect(entry.passCount, 3);
      expect(entry.excluded, isTrue);
    },
  );

  test('refuses a chapter with no course chapters in it', () async {
    writeMain(
      '${_modelGame(tartakower)}\n'
      '${_modelGame(catalan)}',
    );
    await expectLater(
      splitter.split(main_, isWhite: false),
      throwsA(isA<ChapterSplitException>()),
    );
    expect(chapterFiles().map(p.basename), ['Main.pgn']);
  });

  group('fileNameFor', () {
    test('replaces what a filesystem will not take', () {
      expect(
        CourseChapterPartition.fileNameFor('QGD: Other Lines'),
        'QGD Other Lines',
      );
      expect(
        CourseChapterPartition.fileNameFor(r'Reti / KIA \ lines'),
        'Reti KIA lines',
      );
      expect(
        CourseChapterPartition.fileNameFor('Trailing dots...'),
        'Trailing dots',
      );
      expect(CourseChapterPartition.fileNameFor('   '), 'Chapter');
      expect(CourseChapterPartition.fileNameFor('x' * 200).length, 80);
    });
  });
}
