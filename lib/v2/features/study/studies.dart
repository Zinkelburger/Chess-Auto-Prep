import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/study.dart';
import '../../diagnostics/log.dart';
import '../../net/lichess_studies.dart';
import '../../storage/chapter_files.dart';
import '../../storage/document_ref.dart';
import '../../storage/pgn_document_store.dart' as store;
import '../../storage/study_files.dart';
import '../../ui/file_names.dart';
import '../../workspace/document_saver.dart';
import '../../workspace/document_session.dart';
import 'study_state.dart';

export 'study_state.dart';

/// The user's studies: the list of files under `Documents/studies/`, the
/// search over it, and the operations that make, import, export and remove
/// one.
///
/// A study's chapters are not here. They are the games of the file the
/// workspace has open, so the session holds them and the chapter operations
/// are commands over it (`study_commands.dart`). This owner knows only about
/// whole files.
///
/// One change at a time ([busy]), and the folder is listed again after each
/// of them, so what the panel shows is what the disk holds.
final class Studies extends ChangeNotifier {
  Studies({
    required StudyFiles files,
    required store.PgnDocumentStore documents,
    required DocumentSession session,
    required DocumentSaver saver,
    required LichessStudies lichess,
    required String root,
  }) : _files = files,
       _store = documents,
       _session = session,
       _saver = saver,
       _lichess = lichess,
       _root = root;

  /// What a study's first chapter is called before anyone renames it.
  static const firstChapter = 'Chapter 1';

  final StudyFiles _files;
  final store.PgnDocumentStore _store;
  final DocumentSession _session;
  final DocumentSaver _saver;
  final LichessStudies _lichess;

  /// The `studies` folder, absolute.
  final String _root;

  StudiesState _state = const StudiesLoading();
  String _query = '';
  int _refreshes = 0;
  bool _busy = false;
  bool _disposed = false;

  StudiesState get state => _state;

  String get query => _query;

  /// A change to the folder is in flight, so the row actions are off.
  bool get busy => _busy;

  List<ChapterRef> get studies => switch (_state) {
    StudiesLoaded(:final studies) => studies,
    _ => const [],
  };

  /// The studies whose name matches [query].
  List<ChapterRef> get visible {
    final needle = _query.trim().toLowerCase();
    if (needle.isEmpty) return studies;
    return [
      for (final study in studies)
        if (study.name.toLowerCase().contains(needle)) study,
    ];
  }

  /// The study the workspace has open, or null when what is open is not one
  /// of these files.
  ChapterRef? get open {
    final source = _session.source;
    if (source == null || _session.game == null) return null;
    return p.equals(p.dirname(source.path), _root) ? source : null;
  }

  /// The chapters of the open study, in file order.
  List<StudyChapter> get chapters {
    final chapter = open == null ? null : _session.chapter;
    return chapter == null ? const [] : studyChapters(chapter.lines);
  }

  /// Which chapter of the open study is on the board.
  int? get openChapter => open == null ? null : _session.game;

  void search(String query) {
    if (query == _query) return;
    _query = query;
    notifyListeners();
  }

  /// Reads the folder again. A refresh overtaken by a newer one discards its
  /// answer, and a list already on screen stays there while the new one is
  /// read.
  Future<void> refresh() async {
    final ticket = ++_refreshes;
    if (_state is! StudiesLoaded) _set(const StudiesLoading());
    final listing = await _files.list();
    if (_disposed || ticket != _refreshes) return;
    _set(switch (listing) {
      StudiesListed(:final studies) => StudiesLoaded(studies),
      StudiesUnreadable(:final detail) => _loadFailed(detail),
    });
  }

  /// A study with one empty chapter in it, which is what the old app makes.
  Future<StudyResult> create(String name) => _run('create the study $name', () {
    final wrong = nameProblem(name);
    if (wrong != null) return Future.value(StudyProblem(wrong));
    return _created(name, newStudyText(study: name, chapter: firstChapter));
  });

  /// What [input] is recognised as, for the import dialog to echo back, or
  /// null when it is not a link this app can fetch. Pure, so the dialog can
  /// ask on every keystroke; the widgets never see the client itself.
  String? linkDescription(String input) => parseStudyLink(input)?.describe;

  /// Downloads the study [url] names and files it under the name its own
  /// tags give it.
  ///
  /// Replacing nothing: a name already taken gets a number after it, because
  /// a download must never land on top of a study the user wrote. The PGN is
  /// read before it is written — that is where the name comes from, and a
  /// download with no games in it is refused rather than filed as an empty
  /// study.
  Future<StudyResult> importFromUrl(String url) {
    final link = parseStudyLink(url);
    if (link == null) {
      return Future.value(const StudyProblem('Not a Lichess study link.'));
    }
    return _run('import ${link.describe}', () async {
      final fetched = await _lichess.fetch(link);
      if (fetched case StudyNotFetched(:final sentence)) {
        return StudyProblem(sentence);
      }
      final pgn = (fetched as StudyFetched).pgn;
      final read = await readChapter(name: '', text: pgn);
      if (read.lines.isEmpty) {
        return StudyProblem(StudyFetchProblem.empty.sentence);
      }
      final wanted = studyNameIn(read.lines) ?? 'Lichess ${link.studyId}';
      return _createdUnderAFreeName(wanted, pgn);
    });
  }

  /// Recoverable: the file goes to the recovery folder through the store,
  /// which is where a deleted chapter goes too.
  Future<StudyResult> delete(ChapterRef study) =>
      _run('delete ${study.path}', () async {
        final revision = await _revisionOf(study);
        if (revision == null) {
          return const StudyProblem(
            'That study changed on disk. The list has been refreshed; try '
            'again.',
          );
        }
        switch (await _store.delete(study, expected: revision)) {
          case store.Deleted():
            if (_session.source == study) _session.closed();
            return const StudyDone();
          case store.Conflict():
            return const StudyProblem(
              'That study changed on disk while it was open. Reload it, then '
              'try again.',
            );
          case store.IoFailure(:final detail):
            return StudyProblem('Could not delete the study: $detail');
        }
      });

  /// The whole open study as PGN, once the draft on screen has reached the
  /// file: copying a study that is a second behind is copying the wrong one.
  Future<String?> pgnOfOpenStudy() async {
    await _saver.flush();
    final chapter = _session.chapter;
    return chapter == null ? null : writeChapter(chapter);
  }

  /// One chapter of the open study as PGN: the game exactly as the file
  /// holds it.
  Future<String?> pgnOfChapter(int index) async {
    await _saver.flush();
    final Chapter? chapter = _session.chapter;
    if (chapter == null || index < 0 || index >= chapter.lines.length) {
      return null;
    }
    return '${chapter.lines[index].text}\n';
  }

  /// [name], or `name 2`, `name 3`… until one of them is free. A study whose
  /// name a hundred files already carry is a problem the user has to look
  /// at, so the collision is reported rather than numbered for ever.
  Future<StudyResult> _createdUnderAFreeName(String name, String text) async {
    for (var attempt = 1; attempt <= 100; attempt++) {
      final wanted = attempt == 1 ? name : '$name $attempt';
      final created = await _created(_asFileName(wanted), text);
      if (created is! StudyProblem) return created;
      if (!await _isTaken(wanted)) return created;
    }
    return StudyProblem('No free name was found for "$name".');
  }

  Future<bool> _isTaken(String name) async =>
      await _store.open(DocumentRef(p.join(_root, '${_asFileName(name)}.pgn')))
          is store.Opened;

  /// A study is its file name, so a name a file cannot take is trimmed down
  /// to one that can rather than refused: the name came from a download, not
  /// from the user, and there is nobody to ask.
  String _asFileName(String name) =>
      safeFileName(name, fallback: 'Imported study');

  /// Writes `<name>.pgn` in the studies folder and nowhere else.
  ///
  /// The name is checked again here rather than trusted from the caller: a
  /// name reaches this from a dialog, from a download's own tags and from
  /// another mode, and one holding a separator or a dot segment would make
  /// a path out of what is supposed to be a file name.
  Future<StudyResult> _created(String name, String text) async {
    if (nameProblem(name) case final wrong?) return StudyProblem(wrong);
    final ref = DocumentRef(p.join(_root, '$name.pgn'));
    return switch (await _store.create(ref, text)) {
      store.Created() => StudyDone(opened: ChapterRef.at(ref.path)),
      store.Collision() => StudyProblem(
        'A study named "$name" already exists.',
      ),
      store.IoFailure(:final detail) => StudyProblem(
        'Could not create the study: $detail',
      ),
    };
  }

  /// The revision [study] has now, with the file held still when it is the
  /// one open, so a delete cannot land between an autosave and its answer.
  Future<Revision?> _revisionOf(ChapterRef study) async {
    if (_session.source == study) {
      return _saver.holdStill((revision) async => revision);
    }
    return switch (await _store.open(study)) {
      store.Opened(:final revision) => revision,
      store.Absent() => null,
      store.Unreadable(:final detail) => _unreadable(study, detail),
    };
  }

  Revision? _unreadable(ChapterRef study, String detail) {
    log.w('read ${study.path} before changing it', detail);
    return null;
  }

  /// One change at a time, then the folder is listed again: a half-applied
  /// change must be visible, and the disk is the only thing that knows what
  /// landed.
  Future<StudyResult> _run(
    String action,
    Future<StudyResult> Function() body,
  ) async {
    if (_busy) return const StudyProblem('Another change is still running.');
    _busy = true;
    notifyListeners();
    final StudyResult result;
    try {
      result = await body();
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
    if (_disposed) return result;
    if (result case StudyProblem(:final sentence)) log.w(action, sentence);
    await refresh();
    return result;
  }

  StudiesLoadFailed _loadFailed(String detail) {
    log.w('list the studies under $_root', detail);
    return StudiesLoadFailed(detail);
  }

  void _set(StudiesState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
