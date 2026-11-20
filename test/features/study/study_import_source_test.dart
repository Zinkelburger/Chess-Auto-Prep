// What reading an import source answers before anything is written: the
// refusals the import dialog shows instead of a preview.

import 'package:chess_auto_prep/features/study/study_import_source.dart';
import 'package:chess_auto_prep/net/lichess_studies.dart';
import 'package:chess_auto_prep/storage/pgn_file_import.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/study_fixture.dart';
import '../../support/viewer_fixture.dart';

void main() {
  final lichess = ScriptedLichess(
    const StudyNotFetched(StudyFetchProblem.unreachable),
  );

  String? problemOf(StudyImportRead? read) => switch (read) {
    StudyImportProblem(:final message) => message,
    _ => null,
  };

  test('file import with only half of what it needs says it is unavailable '
      'and asks nothing', () async {
    final picker = ScriptedPicker('/games.pgn');
    final importer = ScriptedImport()
      ..picked['/games.pgn'] = const PickedText(twoChapterStudy);

    final noImporter = StudyImportSource(lichess: lichess, picker: picker);
    expect(problemOf(await noImporter.file()), 'File import is unavailable.');
    expect(picker.startedIn, isEmpty);

    final noPicker = StudyImportSource(lichess: lichess, importer: importer);
    expect(problemOf(await noPicker.file()), 'File import is unavailable.');
    expect(importer.reads, isEmpty);
  });

  test('pasted PGN whose every game is broken has nothing to import', () async {
    const source = StudyImportSource(lichess: _NoLichess());
    final read = await source.pgn('[Event "Broken"]\n\n1. d4 e9 *\n');
    expect(
      problemOf(read),
      'No complete games found. Check the PGN and try again.',
    );
  });

  test(
    'pasted PGN with one whole game among broken ones is previewed',
    () async {
      const source = StudyImportSource(lichess: _NoLichess());
      final read = await source.pgn(
        '[Event "Valid"]\n\n1. e4 *\n\n[Event "Broken"]\n\n1. d4 e9 *\n',
      );
      expect(read, isA<StudyImportData>());
      expect((read as StudyImportData).complete, isFalse);
    },
  );
}

/// Nothing in these tests reaches Lichess.
final class _NoLichess implements LichessStudies {
  const _NoLichess();

  @override
  Future<StudyFetch> fetch(LichessStudyLink link) =>
      throw StateError('no fetch expected');
}
