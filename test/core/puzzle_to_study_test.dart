/// The puzzle → study pipeline: a puzzle is encoded as one PGN game, appended
/// to a study as a chapter, and comes back out of the study file as a
/// trainable tactics line.
library;

import 'dart:io';

import 'package:chess_auto_prep/core/study_controller.dart';
import 'package:chess_auto_prep/features/tactics/models/tactics_position.dart';
import 'package:chess_auto_prep/features/tactics/models/tactics_session_settings.dart';
import 'package:chess_auto_prep/services/repertoire_service.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/features/tactics/services/tactics_pgn_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

/// Mate-in-one for Black: back-rank rook mate (Re1#).
const _blackToMateFen = '4r1k1/5ppp/8/8/8/8/5PPP/6K1 b - - 0 30';

const _solutionSan = ['Re1#'];

/// A one-move puzzle on [_blackToMateFen], shaped exactly as an authored
/// custom puzzle reaches [encodePuzzlePgn].
TacticsPosition _puzzle({String note = '', int rating = 0}) => TacticsPosition(
  fen: _blackToMateFen,
  userMove: '',
  correctLine: _solutionSan,
  mistakeType: TacticsSessionSettings.customMistakeType,
  mistakeAnalysis: note,
  gameWhite: '',
  gameBlack: '',
  gameResult: '*',
  gameDate: '2026.07.28',
  gameId: 'custom_test',
  rating: rating,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('puzzle_to_study_test');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('puzzle → encodePuzzlePgn → study chapter → trainable line '
      'round-trips FEN, solution, note and rating', () async {
    final chapterPgn = encodePuzzlePgn(
      _puzzle(note: 'Back rank.', rating: 4),
      _solutionSan,
      event: 'Back-rank mate',
      noteAfterLastMove: true,
    );

    // Save into a (not currently open) study file on disk.
    final study = StudyController();
    final path = await StorageFactory.instance.studyFilePath('Puzzles');
    await study.addChapterToStudyFile(path, 'Back-rank mate', chapterPgn);

    final saved = await File(path).readAsString();
    expect(saved, contains('[Event "Back-rank mate"]'));
    expect(saved, contains('[FEN "$_blackToMateFen"]'));
    expect(saved, contains('[StarRating "4"]'), reason: 'headers preserved');
    expect(saved, contains('Back rank.'), reason: 'note rides as a comment');

    // The trainer parses the study with per-chapter solver colours.
    final lines = RepertoireService().parseRepertoirePgn(
      saved,
      colorFromStartingSide: true,
    );
    expect(lines, hasLength(1));
    expect(lines.single.name, 'Back-rank mate');
    expect(lines.single.color, 'black', reason: 'solver is the side to move');
    expect(lines.single.moves, ['Re1#']);
    expect(lines.single.startPosition.fen, _blackToMateFen);
    expect(
      lines.single.comments['0'],
      'Back rank.',
      reason: 'the note is an annotation on the solution move',
    );
    study.dispose();
  });

  test('addChapterToStudyFile preserves custom headers when the target study '
      'is the open document', () async {
    final study = StudyController();
    await study.newStudy('Open study');
    final path = study.doc.filePath!;

    final chapterPgn = encodePuzzlePgn(
      _puzzle(note: 'Note.', rating: 5),
      _solutionSan,
      event: 'Chapter 2',
    );

    // The open-document path routes through the in-memory StudyDocument —
    // the regression this guards: headers used to be dropped there.
    await study.addChapterToStudyFile(path, 'Chapter 2', chapterPgn);
    expect(study.doc.chapters, hasLength(2));

    final saved = await File(path).readAsString();
    expect(saved, contains('[StarRating "5"]'));
    expect(saved, contains('[FEN "$_blackToMateFen"]'));
    study.dispose();
  });

  test(
    'an external edit is preserved instead of being overwritten by autosave',
    () async {
      final study = StudyController();
      await study.newStudy('Concurrent edit');
      final path = study.doc.filePath!;
      await File(path).writeAsString('external editor content');

      await study.addChapterToStudyFile(
        path,
        'Local chapter',
        encodePuzzlePgn(_puzzle(), _solutionSan, event: 'Local chapter'),
      );

      expect(await File(path).readAsString(), 'external editor content');
      expect(study.saveError, contains('changed on disk'));
      expect(study.dirty, isTrue, reason: 'the local edit remains recoverable');
      study.dispose();
    },
  );
}
