import '../../storage/player_files.dart';
import '../../storage/pgn_file_picker.dart';
import '../../storage/pgn_file_import.dart';
import '../../storage/pgn_export.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/chapter_edit.dart';
import '../../chess/pgn/study.dart';
import '../../chess/pgn/study_edits.dart' as pgn show addChapters;
import '../../storage/edit_scope.dart' show GamesRearranged;
import '../../workspace/study_choice.dart';
import 'study_commands.dart' show studyNameOf;
import 'study_file_changes.dart';
import 'study_import_source.dart';
import 'studies_state.dart';
import '../../diagnostics/log.dart';
import '../../net/lichess_studies.dart';
import '../../storage/pending_writes.dart';
import '../../storage/chapter_files.dart';
import '../../storage/deleted_chapters.dart';
import '../../storage/document_ref.dart';
import '../../storage/pgn_document_store.dart' as store;
import '../../storage/study_files.dart';
import '../../ui/file_names.dart';
import '../../workspace/document_saver.dart';
import '../../workspace/document_session.dart';

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
    required this._files,
    required store.PgnDocumentStore documents,
    required this._session,
    this.pendingWrites,
    this.picker,
    this.importer,
    this.exporter,
    this.linkedPlayers,
    required this._saver,
    required this._lichess,
    required this._root,
  }) : _store = documents;

  /// What a study's first chapter is called before anyone renames it.
  static const firstChapter = 'Chapter 1';

  late final _changes = StudyFileChanges(
    store: _store,
    session: _session,
    saver: _saver,
    root: _root,
    resource: this,
    pendingWrites: pendingWrites,
    linkedPlayers: linkedPlayers,
  );

  late final imports = StudyImportSource(
    lichess: _lichess,
    picker: picker,
    importer: importer,
  );

  final PgnFilePicker? picker;
  final PgnFileImport? importer;
  final PgnExport? exporter;
  final PlayerStore? linkedPlayers;
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

  /// A study with one empty chapter in it.
  Future<StudyResult> create(String name) => _run('create the study $name', () {
    final wrong = nameProblem(name);
    if (wrong != null) return Future.value(StudyProblem(wrong));
    return _created(name, newStudyText(study: name, chapter: firstChapter));
  });

  /// [drafts] as new chapters at the end of the study [into] names, or of a
  /// new study made for them — what every "Add to study" of another mode
  /// comes to. The answer names the study and its first new chapter.
  ///
  /// A study open in the workspace takes them through its editor, so its
  /// own draft and autosave see them; any other is changed on disk through
  /// the store, against the revision just read, touching no other game.
  Future<StudyResult> addChapters(
    StudyChoice into,
    List<ChapterDraft> drafts,
  ) => _run('add chapters to a study', () => _addChapters(into, drafts));

  Future<StudyResult> _addChapters(
    StudyChoice into,
    List<ChapterDraft> drafts,
  ) async {
    switch (into) {
      case NewStudy(:final name):
        if (nameProblem(name) case final wrong?) return StudyProblem(wrong);
        final empty = await readChapter(name: name, text: '');
        final edit = pgn.addChapters(empty, study: name, drafts: drafts);
        if (edit is! ChapterEdited) return _refusedAdd(edit);
        final created = await _created(name, writeChapter(edit.chapter));
        return created is StudyDone
            ? StudyDone(opened: created.opened, chapter: 0)
            : created;
      case IntoStudy(:final study):
        // Held against opening it, so a read begun before the write is read
        // again rather than shown with the chapters missing.
        return _changes.changing(
          study.path,
          () async => _session.source?.path == study.path
              ? _addOpen(study, drafts)
              : _addOnDisk(study, drafts),
        );
    }
  }

  StudyResult _addOpen(ChapterRef study, List<ChapterDraft> drafts) {
    final chapter = _session.chapter;
    if (chapter == null || _session.game == null) {
      return const StudyProblem('Open that study from its list first.');
    }
    final first = chapter.lines.length;
    final refused = _session.apply(
      (open) => pgn.addChapters(open, study: studyNameOf(open), drafts: drafts),
    );
    return refused == null
        ? StudyDone(opened: study, chapter: first)
        : StudyProblem('Could not add to ${study.name}: $refused.');
  }

  Future<StudyResult> _addOnDisk(
    ChapterRef study,
    List<ChapterDraft> drafts,
  ) async {
    final String text;
    final Revision revision;
    switch (await _store.open(study)) {
      case store.Opened(readOnly: final why?):
        return StudyProblem(why);
      case store.Opened(text: final read, revision: final at):
        (text, revision) = (read, at);
      case store.Absent():
        return studyChangedOnDisk;
      case store.Unreadable(:final detail):
        log.w('read ${study.path} to add to it', detail);
        return StudyProblem('Could not read ${study.name}.');
    }
    final chapter = await readChapter(name: study.name, text: text);
    final edit = pgn.addChapters(
      chapter,
      study: studyNameIn(chapter.lines) ?? study.name,
      drafts: drafts,
    );
    if (edit is! ChapterEdited) return _refusedAdd(edit);
    final saved = await _store.save(
      study,
      writeChapter(edit.chapter),
      expected: revision,
      scope: GamesRearranged(edit.games),
    );
    return switch (saved) {
      store.Saved() => StudyDone(opened: study, chapter: chapter.lines.length),
      store.Conflict() => studyChangedOnDisk,
      store.SaveDidNotLand(:final detail) => StudyProblem(
        'Could not add to ${study.name}: $detail',
      ),
    };
  }

  static StudyProblem _refusedAdd(ChapterEdit edit) =>
      StudyProblem(switch (edit) {
        ChapterEditRefused(:final reason) => reason,
        _ => 'Nothing to add.',
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

  Future<StudyResult> importPgn() async {
    if (picker == null || importer == null) {
      return const StudyProblem('File import is unavailable.');
    }
    if (_busy || _disposed) return const StudyDone();
    final path = await picker!.pickPgn();
    if (path == null || _disposed) return const StudyDone();
    return _run('import study PGN', () async {
      // Read where it is: the study is the only copy the import makes.
      final String text;
      switch (await importer!.read(path)) {
        case PickedUnread(:final detail):
          log.w('read $path to import it', detail);
          return const StudyProblem('That PGN could not be read.');
        case PickedText(foreignEncoding: final why?):
          return StudyProblem(why);
        case PickedText(text: final read):
          text = read;
      }
      final name = p.basenameWithoutExtension(path);
      final chapter = await readChapter(name: name, text: text);
      if (chapter.lines.isEmpty ||
          chapter.lines.every((line) => !line.isWhole)) {
        return const StudyProblem('That PGN contains no readable games.');
      }
      return _createdUnderAFreeName(name, text);
    });
  }

  Future<StudyResult> importPreview(
    StudyImportData data, {
    ChapterRef? into,
    String? name,
  }) => _run('import study chapters', () async {
    if (name != null) {
      if (nameProblem(name) case final wrong?) return StudyProblem(wrong);
    }
    if (into == null) {
      return _createdUnderAFreeName(name ?? data.name, data.text);
    }
    if (!data.complete) {
      return const StudyProblem(
        'Some games could not be read completely. Import them as a new study to preserve their original text.',
      );
    }
    return _addChapters(IntoStudy(into), [
      for (final (index, line) in data.chapter.lines.indexed)
        ChapterDraft(
          name: studyChapterName(
            line,
            index: index,
            study: studyNameIn(data.chapter.lines),
          ),
          orientation: studyOrientation(line),
          moves: line.tree!,
          tags: line.tags,
          result: line.terminator,
        ),
    ]);
  });

  Future<StudyResult> exportPgn(String name) async {
    if (nameProblem(name) case final wrong?) return StudyProblem(wrong);
    final chapter = open == null ? null : _session.snapshot();
    if (chapter == null || exporter == null) {
      return const StudyProblem('Open a study first.');
    }
    final text = writeChapter(chapter);
    return _run('export study PGN', () async {
      await _saver.flush();
      final nameWithExtension = p.extension(name).toLowerCase() == '.pgn'
          ? name
          : '$name.pgn';
      final result = await exporter!.save(nameWithExtension, text);
      return switch (result) {
        PgnExportFailed(:final message) => StudyProblem(message),
        _ => const StudyDone(),
      };
    });
  }

  /// A rename changes the file's name, preserving all PGN bytes and tags.
  /// The original revision and operation id survive an uncertain result.
  bool get canRetryRename => _changes.canRetryRename;
  Future<StudyResult> rename(ChapterRef study, String name) {
    if (nameProblem(name) case final wrong?) {
      return Future.value(StudyProblem(wrong));
    }
    if (!p.equals(p.dirname(study.path), _root)) {
      return Future.value(
        const StudyProblem('Only saved studies can be renamed.'),
      );
    }
    final to = ChapterRef.at(p.join(_root, '$name.pgn'));
    if (_changes.canRetryRename) {
      return _changes.renames(study, to)
          ? retryRename()
          : Future.value(
              const StudyProblem('Retry the pending study rename first.'),
            );
    }
    if (to == study) return Future.value(const StudyDone());
    return _run('rename study', () => _changes.rename(study, to));
  }

  Future<StudyResult> retryRename() =>
      _run('retry study rename', _changes.retryRename);

  Future<DeletedListing> deleted() => _files.deleted();

  bool get canRetryRestore => _changes.canRetryRestore;
  Future<StudyResult> restore(DeletedChapter deleted, {String? name}) =>
      _run('restore study', () => _changes.restore(deleted, name: name));

  Future<StudyResult> retryRestore() =>
      _run('retry study restore', _changes.retryRestore);

  /// Recoverable: the file goes to the recovery folder through the store,
  /// which is where a deleted chapter goes too. A study Players & prep
  /// links to stays, as it does for a rename.
  Future<StudyResult> delete(ChapterRef study) =>
      _run('delete ${study.path}', () => _changes.delete(study));

  /// The whole open study as PGN, once the draft on screen has reached the
  /// file: copying a study that is a second behind is copying the wrong one.
  Future<String?> pgnOfOpenStudy() async {
    final chapter = _session.snapshot();
    await _saver.flush();
    return chapter == null ? null : writeChapter(chapter);
  }

  /// One chapter of the open study as PGN: the game exactly as the file
  /// holds it.
  Future<String?> pgnOfChapter(int index) async {
    final Chapter? chapter = _session.snapshot();
    await _saver.flush();
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
      if (created is! StudyNameTaken) return created;
    }
    return StudyProblem('No free name was found for "$name".');
  }

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
  _StudyCreate? _creation;
  bool get canRetrySave => _creation != null;
  Future<StudyResult> retrySave() => _run('retry study save', _finishCreated);

  Future<StudyResult> _created(String name, String text) async {
    if (nameProblem(name) case final wrong?) return StudyProblem(wrong);
    if (_creation != null) {
      return const StudyProblem('Retry the pending study save first.');
    }
    final ref = ChapterRef.at(p.join(_root, '$name.pgn'));
    final pending = pendingWrites ?? PendingWrites();
    var uncertain = false;
    Future<store.CreateResult> write() async {
      if (uncertain) {
        final read = await _store.open(ref);
        if (read is store.Opened &&
            read.readOnly == null &&
            read.text == text) {
          return store.Created(read.revision);
        }
      }
      final result = await _store.create(ref, text);
      uncertain = result is store.IoFailure;
      return result;
    }

    _creation = _StudyCreate(
      ref,
      pending.accept<store.CreateResult>(
        resource: this,
        label: 'Save study',
        work: write,
        problem: (result) => result is store.IoFailure ? result.detail : null,
      ),
    );
    return _finishCreated();
  }

  Future<StudyResult> _finishCreated() async {
    final creation = _creation;
    if (creation == null) return const StudyDone();
    final result = await creation.pending.run();
    if (result is! store.IoFailure) _creation = null;
    return switch (result) {
      store.Created() => StudyDone(opened: creation.ref),
      store.Collision() => StudyNameTaken(
        'A study named "${creation.ref.name}" already exists.',
      ),
      store.IoFailure(:final detail) => StudyProblem(
        'Could not save the study: $detail. Retry study save to finish.',
      ),
    };
  }

  /// One change at a time, then the folder is listed again: a half-applied
  /// change must be visible, and the disk is the only thing that knows what
  /// landed.
  final PendingWrites? pendingWrites;

  Future<StudyResult> _run(
    String action,
    Future<StudyResult> Function() body,
  ) =>
      pendingWrites?.track(this, _perform(action, body), label: 'Studies') ??
      _perform(action, body);

  Future<StudyResult> _perform(
    String action,
    Future<StudyResult> Function() body,
  ) async {
    if (_disposed) return const StudyProblem('The study workspace is closed.');
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

final class _StudyCreate {
  const _StudyCreate(this.ref, this.pending);
  final ChapterRef ref;
  final PendingObligation<store.CreateResult> pending;
}
