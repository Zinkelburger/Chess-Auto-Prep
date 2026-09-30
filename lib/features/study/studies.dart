import '../../storage/player_files.dart';
import '../../storage/pgn_file_picker.dart';
import '../../storage/pgn_file_import.dart';
import '../../storage/pgn_export.dart';
import '../../storage/operation_id.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/chapter_edit.dart';
import '../../chess/pgn/study.dart';
import '../../chess/pgn/study_edits.dart' as pgn show addChapters;
import '../../storage/edit_scope.dart' show GamesRearranged;
import '../../workspace/study_choice.dart';
import 'study_commands.dart' show studyNameOf;
import '../../diagnostics/log.dart';
import '../../net/lichess_studies.dart';
import '../../storage/pending_writes.dart';
import '../../storage/chapter_files.dart';
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
    required StudyFiles files,
    required store.PgnDocumentStore documents,
    required DocumentSession session,
    this.pendingWrites,
    this.picker,
    this.importer,
    this.exporter,
    this.linkedPlayers,
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

  /// A study with one empty chapter in it, which is what the old app makes.
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
  ) => _run('add chapters to a study', () async {
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
        return _changing(
          study.path,
          () async => _session.source?.path == study.path
              ? _addOpen(study, drafts)
              : _addOnDisk(study, drafts),
        );
    }
  });

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
        return _changedOnDisk;
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
      store.Conflict() => _changedOnDisk,
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
    if (picker == null || importer == null)
      return const StudyProblem('File import is unavailable.');
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
      if (chapter.lines.isEmpty || chapter.lines.every((line) => !line.isWhole))
        return const StudyProblem('That PGN contains no readable games.');
      return _createdUnderAFreeName(name, text);
    });
  }

  Future<StudyResult> exportPgn(String name) async {
    if (nameProblem(name) case final wrong?) return StudyProblem(wrong);
    final chapter = open == null ? null : _session.snapshot();
    if (chapter == null || exporter == null)
      return const StudyProblem('Open a study first.');
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
  _StudyRename? _rename;
  bool get canRetryRename => _rename != null;
  Future<StudyResult> rename(ChapterRef study, String name) {
    if (nameProblem(name) case final wrong?)
      return Future.value(StudyProblem(wrong));
    if (!p.equals(p.dirname(study.path), _root))
      return Future.value(
        const StudyProblem('Only saved studies can be renamed.'),
      );
    final to = ChapterRef.at(p.join(_root, '$name.pgn'));
    if (_rename case final pending?) {
      return pending.from == study && pending.to == to
          ? retryRename()
          : Future.value(
              const StudyProblem('Retry the pending study rename first.'),
            );
    }
    if (to == study) return Future.value(const StudyDone());
    return _run('rename study', () async {
      final linkProblem = await _linked(study, doing: 'renaming');
      if (linkProblem != null) return StudyProblem(linkProblem);
      return _session.access.changing(
        study.path,
        () => _session.access.changing(
          to.path,
          () => _withRevision(study, (revision) async {
            final id = newOperationId();
            final token = Object();
            if (_session.source == study &&
                !_saver.beginExternal(token, revision))
              return _changedOnDisk;
            final pending = pendingWrites ?? PendingWrites();
            Future<store.MoveResult> work() =>
                _store.move(study, to, expected: revision, operationId: id);
            final obligation = pending.accept<store.MoveResult>(
              resource: this,
              label: 'Rename study',
              work: work,
              // One the store recorded is finished by recovery, so exit
              // does not ask about it.
              problem: (result) =>
                  result is store.IoFailure && result is! store.Unfinished
                  ? result.detail
                  : null,
            );
            _rename = _StudyRename(
              study,
              to,
              token,
              obligation,
              () => pending.track(this, work(), label: 'Rename study'),
            );
            return _finishRename();
          }),
        ),
      );
    });
  }

  /// Why [study] cannot be moved from its path — players or groups in
  /// Players & prep name it there — or null when nothing does. [doing] is
  /// the change being asked for, for the sentence.
  Future<String?> _linked(ChapterRef study, {required String doing}) async {
    final source = linkedPlayers;
    if (source == null) return null;
    try {
      final data = await source.read();
      if (data.warnings.isNotEmpty)
        return 'The player directory needs attention before $doing a linked study.';
      final names = [
        for (final player in data.players)
          if (p.equals(player.text('prep_file'), study.path)) player.name,
        for (final group in data.groups)
          if (group.fields['study'] == study.path) group.name,
      ];
      return names.isEmpty
          ? null
          : 'This study is linked to ${names.join(', ')} in Players & prep. Update its links before $doing it.';
    } on Object catch (error) {
      log.w('check study links', error);
      return 'Could not check study links. Retry when the player directory is readable.';
    }
  }

  Future<StudyResult> retryRename() => _run('retry study rename', () async {
    final move = _rename;
    if (move == null) return const StudyDone();
    return _session.access.changing(
      move.from.path,
      () => _session.access.changing(
        move.to.path,
        () async => _session.source == move.from
            ? await _saver.holdStill(
                    (_) => _finishRename(),
                    continuing: move.token,
                  ) ??
                  _changedOnDisk
            : _finishRename(),
      ),
    );
  });
  Future<StudyResult> _finishRename() async {
    final move = _rename!;
    // A recorded rename left the obligations when the store answered
    // Unfinished; asking again under its id follows it to where recovery
    // carried it, and a refusal while it is still owed stays unasked at exit.
    final result = move.pending.committed
        ? await move.again()
        : await move.pending.run();
    if (result is! store.IoFailure) _rename = null;
    switch (result) {
      case store.Moved():
        if (_session.source == move.from) _session.relocated(move.to);
        _saver.resolveExternalMove(move.token);
        return const StudyDone();
      case store.Collision():
        _saver.resolveExternalMove(move.token);
        return const StudyProblem('A study with that name already exists.');
      case store.Conflict():
        _saver.resolveExternalMove(
          move.token,
          failure: _changedOnDisk.sentence,
        );
        return _changedOnDisk;
      case store.IoFailure(:final detail):
        // Edits wait until the study follows its rename: recovery may move
        // the file at any access, recorded or not.
        _saver.resolveExternalMove(
          move.token,
          failure: detail,
          uncertain: true,
        );
        return StudyProblem(
          'Rename was not confirmed: $detail. Retry rename to finish.',
        );
    }
  }

  /// Recoverable: the file goes to the recovery folder through the store,
  /// which is where a deleted chapter goes too. A study Players & prep
  /// links to stays, as it does for a rename.
  Future<StudyResult> delete(ChapterRef study) =>
      _run('delete ${study.path}', () async {
        final linkProblem = await _linked(study, doing: 'deleting');
        if (linkProblem != null) return StudyProblem(linkProblem);
        return _changing(
          study.path,
          () => _withRevision(study, (revision) async {
            switch (await _store.delete(study, expected: revision)) {
              case store.Deleted():
                if (_session.source == study) _session.closed();
                return const StudyDone();
              case store.Conflict():
                return const StudyProblem(
                  'That study changed on disk while it was open. Reload it, '
                  'then try again.',
                );
              case store.IoFailure(:final detail):
                return StudyProblem('Could not delete the study: $detail');
            }
          }),
        );
      });

  /// Runs [work] with opening [path] held off until it is over. Another
  /// command already changing that file is a refusal, not a wait.
  Future<StudyResult> _changing(
    String path,
    Future<StudyResult> Function() work,
  ) async {
    try {
      return await _session.access.changing(path, work);
    } on StateError catch (error) {
      log.w('change $path', error);
      return const StudyProblem('Another change is still running.');
    }
  }

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
      if (created is! _StudyNameTaken) return created;
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
    if (_creation != null)
      return const StudyProblem('Retry the pending study save first.');
    final ref = ChapterRef.at(p.join(_root, '$name.pgn'));
    final pending = pendingWrites ?? PendingWrites();
    var uncertain = false;
    Future<store.CreateResult> write() async {
      if (uncertain) {
        final read = await _store.open(ref);
        if (read is store.Opened && read.readOnly == null && read.text == text)
          return store.Created(read.revision);
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
      store.Collision() => _StudyNameTaken(
        'A study named "${creation.ref.name}" already exists.',
      ),
      store.IoFailure(:final detail) => StudyProblem(
        'Could not save the study: $detail. Retry study save to finish.',
      ),
    };
  }

  /// Runs [write] against the revision [study] has now.
  ///
  /// The study open in the workspace is held still by its saver until
  /// [write] is over, so an autosave cannot land between the revision and
  /// the write that expects it. Any other is read from disk, which is also
  /// the check that it is still there.
  Future<StudyResult> _withRevision(
    ChapterRef study,
    Future<StudyResult> Function(Revision revision) write,
  ) async {
    if (_session.source == study) return _held(write);
    switch (await _store.open(study)) {
      case store.Opened(:final revision):
        // The user may have opened the study while it was being read, and
        // from here on its writes belong behind the saver's hold.
        if (_session.source == study) return _held(write);
        return write(revision);
      case store.Absent():
        return _changedOnDisk;
      case store.Unreadable(:final detail):
        log.w('read ${study.path} before changing it', detail);
        return _changedOnDisk;
    }
  }

  /// Runs [write] with the open study held still by its saver. When the
  /// saver cannot hold it — nothing is open by the time its draft is
  /// written, or another change holds it — the answer is the one for a
  /// study gone from disk: the list is read again and the user tries again.
  Future<StudyResult> _held(
    Future<StudyResult> Function(Revision revision) write,
  ) async => await _saver.holdStill(write) ?? _changedOnDisk;

  static const _changedOnDisk = StudyProblem(
    'That study changed on disk. The list has been refreshed; try again.',
  );

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

/// What the studies panel is showing.
sealed class StudiesState {
  const StudiesState();
}

/// The folder is being read for the first time.
final class StudiesLoading extends StudiesState {
  const StudiesLoading();
}

final class StudiesLoaded extends StudiesState {
  const StudiesLoaded(this.studies);

  /// In name order. Empty means the folder holds no studies, which is
  /// different from not having been able to read it.
  final List<ChapterRef> studies;
}

/// The folder is there but could not be read. The panel says so and offers
/// to try again; it never shows an empty list instead.
final class StudiesLoadFailed extends StudiesState {
  const StudiesLoadFailed(this.detail);

  /// The operating system's message, for the log; the panel writes the
  /// sentence.
  final String detail;
}

/// What became of a change to the studies folder.
sealed class StudyResult {
  const StudyResult();
}

/// It happened. [opened] is the study the change produced, when it produced
/// one, so the panel can open it at once; [chapter] its first new chapter,
/// when chapters were added.
final class StudyDone extends StudyResult {
  const StudyDone({this.opened, this.chapter});

  final ChapterRef? opened;
  final int? chapter;
}

/// It did not happen. [sentence] is plain English for the screen; the owner
/// has already put the same thing in the log with the action it belongs to.
final class StudyProblem extends StudyResult {
  const StudyProblem(this.sentence);

  final String sentence;
}

final class _StudyRename {
  const _StudyRename(this.from, this.to, this.token, this.pending, this.again);
  final Object token;
  final ChapterRef from, to;
  final PendingObligation<store.MoveResult> pending;

  /// The same move under the same operation id, waited for at exit but not
  /// asked about: for a rename the store recorded.
  final Future<store.MoveResult> Function() again;
}

final class _StudyCreate {
  const _StudyCreate(this.ref, this.pending);
  final ChapterRef ref;
  final PendingObligation<store.CreateResult> pending;
}

final class _StudyNameTaken extends StudyProblem {
  const _StudyNameTaken(super.sentence);
}
