import 'package:chess_auto_prep/v2/features/study/studies.dart';
import 'package:chess_auto_prep/v2/net/lichess_studies.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/study_files.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';

import 'scripted_store.dart';

/// Where the studies live in these tests.
const studiesRoot = '/studies';

ChapterRef studyRef(String name) => ChapterRef(
  repertoire: 'studies',
  name: name,
  path: '$studiesRoot/$name.pgn',
);

/// A studies listing the test writes.
final class ScriptedStudyFiles implements StudyFiles {
  ScriptedStudyFiles([this.listing = const StudiesListed([])]);

  StudyListing listing;

  var listings = 0;

  @override
  Future<StudyListing> list() async {
    listings++;
    return listing;
  }
}

/// A Lichess client the test writes the answers for. Nothing here reaches
/// the network.
final class ScriptedLichess implements LichessStudies {
  ScriptedLichess(this.answer);

  StudyFetch answer;

  /// Every link that was asked for, in order.
  final asked = <LichessStudyLink>[];

  @override
  Future<StudyFetch> fetch(LichessStudyLink link) async {
    asked.add(link);
    return answer;
  }
}

/// A study file with two chapters, in the Lichess export format.
const twoChapterStudy = '''
[Event "Endgames: Rook endings"]
[Result "*"]
[StudyName "Endgames"]
[ChapterName "Rook endings"]
[Orientation "white"]

1. e4 e5 2. Nf3 *

[Event "Endgames: Pawn endings"]
[Result "*"]
[StudyName "Endgames"]
[ChapterName "Pawn endings"]
[Orientation "black"]

1. d4 d5 *
''';

/// Everything a study test needs: a scripted store holding [text] under
/// [name], a session over it and the owner that lists it.
final class StudyFixture {
  StudyFixture._({
    required this.store,
    required this.saver,
    required this.session,
    required this.studies,
    required this.files,
    required this.lichess,
    required this.ref,
  });

  final ScriptedDocumentStore store;
  final DocumentSaver saver;
  final DocumentSession session;
  final Studies studies;
  final ScriptedStudyFiles files;
  final ScriptedLichess lichess;
  final ChapterRef ref;

  String get onDisk => switch (store.documents[ref]) {
    Opened(:final text) => text,
    _ => '',
  };

  void dispose() {
    studies.dispose();
    session.dispose();
    saver.dispose();
  }
}

Future<StudyFixture> openStudy(
  String text, {
  String name = 'Endgames',
  int chapter = 0,
  StudyFetch fetch = const StudyNotFetched(StudyFetchProblem.unreachable),
}) async {
  final ref = studyRef(name);
  final store = ScriptedDocumentStore()
    ..documents[ref] = Opened(text, scriptedRevision(text));
  final saver = DocumentSaver(store, delay: Duration.zero);
  final session = DocumentSession(store, saver);
  final files = ScriptedStudyFiles(StudiesListed([ref]));
  final lichess = ScriptedLichess(fetch);
  final studies = Studies(
    files: files,
    documents: store,
    session: session,
    saver: saver,
    lichess: lichess,
    root: studiesRoot,
  );
  await studies.refresh();
  await session.open(ref, game: chapter);
  return StudyFixture._(
    store: store,
    saver: saver,
    session: session,
    studies: studies,
    files: files,
    lichess: lichess,
    ref: ref,
  );
}
