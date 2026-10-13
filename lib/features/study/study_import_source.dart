import 'package:path/path.dart' as p;
import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/study.dart';
import '../../net/lichess_studies.dart';
import '../../storage/pgn_file_import.dart';
import '../../storage/pgn_file_picker.dart';

sealed class StudyImportRead {
  const StudyImportRead();
}

final class StudyImportProblem extends StudyImportRead {
  const StudyImportProblem(this.message);
  final String message;
}

final class StudyImportData extends StudyImportRead {
  const StudyImportData(this.name, this.text, this.chapter);
  final String name, text;
  final Chapter chapter;
  bool get complete => chapter.lines.every((line) => line.isWhole);
}

/// Reading and validation precede the user's destination choice and any writes.
class StudyImportSource {
  const StudyImportSource({required this.lichess, this.picker, this.importer});
  final LichessStudies lichess;
  final PgnFilePicker? picker;
  final PgnFileImport? importer;

  Future<StudyImportRead?> file() async {
    if (picker == null || importer == null)
      return const StudyImportProblem('File import is unavailable.');
    final path = await picker!.pickPgn();
    if (path == null) return null;
    return switch (await importer!.read(path)) {
      PickedUnread() => const StudyImportProblem(
        'That PGN could not be read. Choose another file.',
      ),
      PickedText(foreignEncoding: final why?) => StudyImportProblem(why),
      PickedText(:final text) => pgn(
        text,
        name: p.basenameWithoutExtension(path),
      ),
    };
  }

  Future<StudyImportRead> url(String text) async {
    final link = parseStudyLink(text);
    if (link == null)
      return const StudyImportProblem('Use a Lichess study or chapter link.');
    return switch (await lichess.fetch(link)) {
      StudyNotFetched(:final sentence) => StudyImportProblem(sentence),
      StudyFetched(:final pgn) => this.pgn(
        pgn,
        name: 'Lichess ${link.studyId}',
      ),
    };
  }

  Future<StudyImportRead> pgn(
    String text, {
    String name = 'Imported study',
  }) async {
    final chapter = await readChapter(name: name, text: text);
    if (chapter.lines.isEmpty || chapter.lines.every((line) => !line.isWhole)) {
      return const StudyImportProblem(
        'No complete games found. Check the PGN and try again.',
      );
    }
    return StudyImportData(studyNameIn(chapter.lines) ?? name, text, chapter);
  }
}
