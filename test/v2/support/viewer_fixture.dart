import 'package:chess_auto_prep/v2/features/pgn_viewer/pgn_viewer.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_import.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_picker.dart';
import 'package:chess_auto_prep/v2/storage/recent_pgn_files.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';

import 'scripted_store.dart';

/// Where the downloaded collections live in these tests.
const collectionsRoot = '/Documents/pgn_collections';

ChapterRef collectionRef(String name) =>
    ChapterRef.at('$collectionsRoot/$name.pgn');

/// A recent-files list the test writes, and that records what was saved.
final class ScriptedRecentFiles implements RecentFiles {
  ScriptedRecentFiles([this.listing = const RecentFilesListed([])]);

  RecentFilesRead listing;

  /// Whether the next save lands.
  bool accepting = true;

  /// Every list that was saved, in order.
  final saved = <List<String>>[];

  @override
  Future<RecentFilesRead> load() async => listing;

  @override
  Future<bool> save(List<String> paths) async {
    saved.add(List.of(paths));
    return accepting;
  }
}

/// An import that copies nothing: a path under the collections root is
/// inside Documents; any other is answered as the test says.
final class ScriptedImport implements PgnFileImport {
  /// What a path outside Documents becomes; null fails the import.
  String? copyTo;

  /// Every path asked about, in order.
  final asked = <String>[];

  @override
  Future<ImportResult> insideDocuments(String path) async {
    asked.add(path);
    if (path.startsWith('/Documents/')) {
      return FileToOpen(path, copied: false);
    }
    final copy = copyTo;
    if (copy == null) return const ImportFailed('no room');
    return FileToOpen(copy, copied: true);
  }
}

/// A file dialog whose answer the test writes.
final class ScriptedPicker implements PgnFilePicker {
  ScriptedPicker([this.answer]);

  String? answer;

  /// The folder each dialog was asked to start in.
  final startedIn = <String?>[];

  @override
  Future<String?> pickPgn({String? startIn}) async {
    startedIn.add(startIn);
    return answer;
  }
}

/// A downloaded collection: three games with the tags a list shows.
const threeGameFile = '''
[Event "Tata Steel"]
[Site "Wijk aan Zee"]
[Date "2024.01.13"]
[White "Carlsen, Magnus"]
[Black "Nakamura, Hikaru"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 1-0

[Event "Tata Steel"]
[Date "2024.01.14"]
[White "Ding, Liren"]
[Black "Giri, Anish"]
[Result "1/2-1/2"]

1. d4 Nf6 2. c4 e6 1/2-1/2

[Event "Club night"]
[Date "????.??.??"]
[White "?"]
[Black "?"]
[Result "*"]

1. c4 *
''';

/// A viewer over [session] whose dialog answers nothing, for tests about
/// the window around it.
PgnViewer viewerFor(DocumentSession session, ScriptedRecentFiles recent) =>
    PgnViewer(
      recent: recent,
      picker: ScriptedPicker(),
      import: ScriptedImport(),
      session: session,
      collections: collectionsRoot,
    );

/// Everything a viewer test needs: a scripted store holding [text] under
/// [name] in the collections folder, a session over it, and the viewer.
final class ViewerFixture {
  ViewerFixture._({
    required this.store,
    required this.saver,
    required this.session,
    required this.viewer,
    required this.recent,
    required this.picker,
    required this.import,
    required this.ref,
  });

  final ScriptedDocumentStore store;
  final DocumentSaver saver;
  final DocumentSession session;
  final PgnViewer viewer;
  final ScriptedRecentFiles recent;
  final ScriptedPicker picker;
  final ScriptedImport import;
  final ChapterRef ref;

  String get onDisk => switch (store.documents[ref]) {
    Opened(:final text) => text,
    _ => '',
  };

  /// Opens [ref] the way the shell does: on its first game, then told to
  /// the viewer.
  Future<void> open({int game = 0}) async {
    await session.open(ref, game: game);
    await viewer.opened(ref);
  }

  void dispose() {
    viewer.dispose();
    session.dispose();
    saver.dispose();
  }
}

Future<ViewerFixture> viewerOver(
  String text, {
  String name = 'games',
  RecentFilesRead recent = const RecentFilesListed([]),
  String? readOnly,
}) async {
  final ref = collectionRef(name);
  final store = ScriptedDocumentStore()
    ..documents[ref] = Opened(text, scriptedRevision(text), readOnly: readOnly);
  final saver = DocumentSaver(store, delay: Duration.zero);
  final session = DocumentSession(store, saver);
  final recentFiles = ScriptedRecentFiles(recent);
  final picker = ScriptedPicker();
  final import = ScriptedImport();
  final viewer = PgnViewer(
    recent: recentFiles,
    picker: picker,
    import: import,
    session: session,
    collections: collectionsRoot,
  );
  return ViewerFixture._(
    store: store,
    saver: saver,
    session: session,
    viewer: viewer,
    recent: recentFiles,
    picker: picker,
    import: import,
    ref: ref,
  );
}
