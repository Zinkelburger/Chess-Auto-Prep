import 'package:chess_auto_prep/chess/pgn/chapter_heading.dart';
import 'package:chess_auto_prep/features/trainer/training_scope.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_files.dart';
import '../../support/scripted_store.dart';

const _main = '// Color: White\n\n[Event "Main"]\n\n1. e4 e5 2. Nf3 *';
const _other = '// Color: White\n\n[Event "Other"]\n\n1. d4 d5 2. c4 *';
const _course = '''
// Color: White

[Event "A"]
[ChapterName "Open"]

1. e4 e5 *

[Event "B"]
[ChapterName "Closed"]

1. d4 d5 *
''';

void main() {
  late ScriptedDocumentStore store;
  late ScriptedFiles files;
  late ScopeReader reader;

  final kidMain = ref('KID', 'Main');
  final kidOther = ref('KID', 'Other');

  ChapterLines onBoard(ChapterRef chapter) =>
      (ref: chapter, lines: const [], revision: scriptedRevision(_main));

  setUp(() {
    store = ScriptedDocumentStore();
    store.documents[kidMain] = Opened(_main, scriptedRevision(_main));
    store.documents[kidOther] = Opened(_other, scriptedRevision(_other));
    files = ScriptedFiles(
      listing: Repertoires([
        folder('KID', ['Main', 'Other']),
      ]),
    );
    reader = ScopeReader(files: files, documents: store);
  });

  group('a retained sitting', () {
    test(
      'survives while every source is the version it was read from',
      () async {
        final chapters = await reader.repertoireOf(onBoard(kidMain));
        expect(await reader.unchanged(chapters), isTrue);
      },
    );

    test('is dropped when one of its files changed', () async {
      final chapters = await reader.repertoireOf(onBoard(kidMain));
      const edited = '$_other\n';
      store.documents[kidOther] = Opened(edited, scriptedRevision(edited));
      expect(await reader.unchanged(chapters), isFalse);
    });

    test('is dropped when a file of the same text took the path', () async {
      final chapters = await reader.repertoireOf(onBoard(kidMain));
      store.documents[kidOther] = Opened(
        _other,
        Revision(scriptedRevision(_other).contentHash, nativeIdentity: 'new'),
      );
      expect(await reader.unchanged(chapters), isFalse);
    });

    test('is dropped when one of its files went', () async {
      final chapters = await reader.repertoireOf(onBoard(kidMain));
      store.documents.remove(kidOther);
      expect(await reader.unchanged(chapters), isFalse);
    });
  });

  test('a repertoire is the folder holding the chapter, the open one taken '
      'as it is on the board', () async {
    files.listing = Repertoires([
      folder('benko', ['Main']),
      folder('KID', ['Main', 'Other']),
    ]);
    final open = onBoard(kidMain);
    final chapters = await reader.repertoireOf(open);
    expect([for (final c in chapters) c.ref], [kidMain, kidOther]);
    expect(identical(chapters.first, open), isTrue);
    expect(chapters.last.revision, scriptedRevision(_other));
    expect(chapters.last.lines, hasLength(1));
    expect(store.opened, [kidOther]);
  });

  test('a chapter in no folder is trained alone', () async {
    final loose = ref('Loose', 'Alone');
    final open = onBoard(loose);
    expect(await reader.repertoireOf(open), [open]);
  });

  test('a book leaves out drafts and files that cannot be read, and reads a '
      'course file once for all its chapters', () async {
    const draft = ChapterRef(
      repertoire: 'KID',
      name: 'Draft',
      path: '/repertoires/KID/Draft.pgn',
      heading: ChapterHeading(draft: true),
    );
    final broken = ref('KID', 'Broken');
    final open = ChapterRef.at('/repertoires/KID/Course.pgn', section: 'Open');
    final closed = ChapterRef.at(
      '/repertoires/KID/Course.pgn',
      section: 'Closed',
    );
    store.documents[draft] = Opened(_main, scriptedRevision(_main));
    store.documents[broken] = const Unreadable('bad sector');
    store.documents[DocumentRef(open.path)] = Opened(
      _course,
      scriptedRevision(_course),
    );
    files.listing = Repertoires([
      RepertoireFolder(
        name: 'KID',
        path: '/repertoires/KID',
        modified: DateTime(2026),
        chapters: [draft, broken, open, closed, kidOther],
      ),
    ]);
    final (:chapters, :problem) = await reader.chaptersWhere(
      (ref) => ref != kidOther,
      null,
    );
    expect(problem, isNull);
    expect([for (final c in chapters) c.ref], [open, closed]);
    expect(chapters.first.lines.single.moves.first.san, 'e4');
    expect(chapters.last.lines.single.moves.first.san, 'd4');
    expect(store.opened.where((r) => r.path == open.path), hasLength(1));
    expect(store.opened, isNot(contains(draft)));
  });

  test(
    'a repertoire list that cannot be read says so, unlike an empty book',
    () async {
      files.listing = const RepertoiresUnreadable('permission denied');
      final unreadable = await reader.chaptersWhere((_) => true, null);
      expect(unreadable.chapters, isEmpty);
      expect(unreadable.problem, contains('permission denied'));

      files.listing = const Repertoires([]);
      final empty = await reader.chaptersWhere((_) => true, null);
      expect(empty.chapters, isEmpty);
      expect(empty.problem, isNull);
    },
  );
}
