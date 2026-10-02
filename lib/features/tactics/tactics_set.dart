import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/chapter_edit.dart';
import '../../chess/pgn/chapter_line.dart';
import '../../chess/tactics/mistake_counts.dart';
import '../../chess/tactics/puzzle.dart';
import '../../chess/tactics/puzzle_edits.dart';
import '../../chess/tactics/puzzle_queue.dart';
import '../../diagnostics/log.dart';
import '../../storage/chapter_files.dart';
import '../../storage/edit_scope.dart';
import '../../storage/pgn_document_store.dart';
import '../../storage/settings_store.dart';
import '../../workspace/document_session.dart';

/// Where the set's puzzles stand.
sealed class SetState {
  const SetState();
}

final class SetLoading extends SetState {
  const SetLoading();
}

/// No set file yet: nothing has been mined.
final class SetMissing extends SetState {
  const SetMissing();
}

/// The file is there and could not be read; [detail] is for the screen.
final class SetUnreadable extends SetState {
  const SetUnreadable(this.detail);

  final String detail;
}

final class SetReady extends SetState {
  const SetReady(this.puzzles);

  final List<Puzzle> puzzles;
}

/// The tactics set — `Documents/tactics_sets/Default.pgn`, one game per
/// puzzle, shared with the old app — and which of its puzzles the filter
/// lets through, in the order a session plays them.
///
/// While the set is the document in the workspace, its puzzles are read from
/// the session, so a result written a moment ago is already in the list;
/// otherwise this reads the file itself. Either way the file has one reader
/// and one writer at a time, and the writer is the session.
final class TacticsSet extends ChangeNotifier {
  TacticsSet({
    required PgnDocumentStore documents,
    required DocumentSession session,
    required SettingsStore settings,
    required this.ref,
    DateTime Function() now = DateTime.now,
    Random? random,
  }) : _documents = documents,
       _session = session,
       _settings = settings,
       _now = now,
       _random = random ?? Random() {
    _seed = _random.nextInt(_seeds);
    _session.addListener(_documentChanged);
    _settings.addListener(_settingsChanged);
  }

  final PgnDocumentStore _documents;
  final DocumentSession _session;
  final SettingsStore _settings;
  final DateTime Function() _now;
  final Random _random;

  /// The set's file.
  final ChapterRef ref;

  /// What Random order shuffles by. It stays for the set's life, so the
  /// attempt written after each puzzle does not shuffle the list again, and
  /// changes when Random is picked again, which is asking for a new order.
  int _seed = 0;
  static const _seeds = 1 << 32;

  SetState _state = const SetLoading();
  List<ChapterLine>? _readFrom;
  final _mistakes = ValueNotifier<Map<String, MistakeCounts>>(const {});
  ({
    List<Puzzle> puzzles,
    PuzzleFilter filter,
    DateTime day,
    int seed,
    List<Puzzle> queue,
  })?
  _queued;
  int _loads = 0;
  bool _disposed = false;

  SetState get state => _state;

  List<Puzzle> get puzzles => switch (_state) {
    SetReady(:final puzzles) => puzzles,
    _ => const [],
  };

  String _query = '';
  String get query => _query;

  void search(String value) {
    if (_query == value) return;
    _query = value;
    notifyListeners();
  }

  /// Text search and filter controls describe the same playable scope.
  List<Puzzle> get queue => _query.isEmpty
      ? filteredQueue
      : filteredQueue.where((puzzle) => puzzle.matches(_query)).toList();

  PuzzleFilter get filter => _settings.value.puzzles;

  /// How many of the user's moves the review marked in each game it went
  /// through, by game id, as the set's heading keeps them — the one owner
  /// of the counts, which My games shows on its rows too. It changes with
  /// every read of the set, including an unsaved edit in the workspace.
  ValueListenable<Map<String, MistakeCounts>> get mistakes => _mistakes;

  /// [puzzle]'s own game as the file has it, or null when the set no longer
  /// holds it where the list saw it.
  String? textOf(Puzzle puzzle) {
    final lines = _readFrom;
    if (lines == null || puzzle.index >= lines.length) return null;
    final line = lines[puzzle.index];
    return puzzleOf(line, puzzle.index)?.fen == puzzle.fen ? line.text : null;
  }

  /// The puzzles a session plays, in its order. Worked out again only when
  /// the puzzles, the filter or the day changes.
  List<Puzzle> get filteredQueue {
    final now = _now();
    final day = DateTime(now.year, now.month, now.day);
    final memo = _queued;
    if (memo != null &&
        identical(memo.puzzles, puzzles) &&
        memo.filter == filter &&
        memo.day == day &&
        memo.seed == _seed) {
      return memo.queue;
    }
    final queue = queueOf(puzzles, filter, today: day, seed: _seed);
    _queued = (
      puzzles: puzzles,
      filter: filter,
      day: day,
      seed: _seed,
      queue: queue,
    );
    return queue;
  }

  /// The puzzle at [index] of the file, or null when there is none.
  Puzzle? at(int index) =>
      puzzles.where((puzzle) => puzzle.index == index).firstOrNull;

  /// Whether the workspace has the set open.
  bool get isOpen => _session.source == ref;

  /// Reads the file, unless the workspace has it open and it is read there.
  Future<void> load() async {
    if (isOpen) return _documentChanged();
    final ticket = ++_loads;
    final read = await _documents.open(ref);
    if (_disposed || ticket != _loads || isOpen) return;
    switch (read) {
      case Opened(:final text):
        final chapter = await readChapter(name: ref.name, text: text, game: 0);
        if (_disposed || ticket != _loads || isOpen) return;
        _show(chapter);
      case Absent():
        _become(const SetMissing());
      case Unreadable(:final detail):
        log.w('read ${ref.path}', detail);
        _become(SetUnreadable(detail));
    }
  }

  /// Takes [puzzle] out of the set; the version replaced is kept with the
  /// file's backups, and its game stays reviewed, so it is not mined again.
  /// While the set is the workspace's document the session makes the edit
  /// and saves it; otherwise it is written here against the version read.
  /// Answers why it was not taken out, or null.
  Future<String?> delete(Puzzle puzzle) async {
    ChapterEdit edit(Chapter set) =>
        deletePuzzle(set, index: puzzle.index, fen: puzzle.fen);
    if (isOpen) return _session.apply(edit);
    try {
      return await _session.access.changing(
        ref.path,
        () => _deleteOnDisk(edit),
      );
    } on Object catch (error) {
      log.w('delete a puzzle from ${ref.path}', error);
      return '$error';
    }
  }

  Future<String?> _deleteOnDisk(ChapterEdit Function(Chapter) edit) async {
    final read = await _documents.open(ref);
    if (read is! Opened) {
      return read is Unreadable
          ? read.detail
          : 'That puzzle is no longer in the set.';
    }
    if (read.readOnly case final reason?) return reason;
    final set = await readChapter(name: ref.name, text: read.text, game: 0);
    final edited = edit(set);
    if (edited is! ChapterEdited) {
      return edited is ChapterEditRefused ? edited.reason : null;
    }
    final saved = await _documents.save(
      ref,
      writeChapter(edited.chapter),
      expected: read.revision,
      scope: GamesRearranged(edited.games),
    );
    switch (saved) {
      case Saved():
        // A load that read the file before this write must not put the
        // puzzle back.
        _loads++;
        if (!_disposed) _show(edited.chapter);
        return null;
      case Conflict():
        return 'The puzzles changed on disk. Try again.';
      case SaveDidNotLand(:final detail):
        log.w('delete a puzzle from ${ref.path}', detail);
        return detail;
    }
  }

  /// Keeps [next] as the filter, for this list and the next launch.
  void setFilter(PuzzleFilter next) =>
      _settings.update(_settings.value.copyWith(puzzles: next));

  void _documentChanged() {
    if (!isOpen) return;
    final chapter = _session.chapter;
    if (chapter == null) return;
    _loads++;
    _show(chapter);
  }

  void _show(Chapter set) {
    final lines = set.lines;
    if (identical(lines, _readFrom)) return;
    _readFrom = lines;
    _mistakes.value = mistakesIn(set.preamble);
    _become(SetReady(puzzlesOf(lines)));
  }

  void _become(SetState state) {
    _state = state;
    notifyListeners();
  }

  /// The filter lives in the settings, so a change to it is heard here.
  void _settingsChanged() {
    final was = _queued?.filter;
    if (was == filter) return;
    if (filter.order == PuzzleOrder.random && was?.order != filter.order) {
      _seed = _random.nextInt(_seeds);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _session.removeListener(_documentChanged);
    _settings.removeListener(_settingsChanged);
    _mistakes.dispose();
    super.dispose();
  }
}
