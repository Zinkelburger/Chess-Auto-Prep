import 'package:flutter/foundation.dart';

import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/chapter_line.dart';
import '../../chess/tactics/puzzle.dart';
import '../../chess/tactics/puzzle_queue.dart';
import '../../diagnostics/log.dart';
import '../../storage/chapter_files.dart';
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
  }) : _documents = documents,
       _session = session,
       _settings = settings,
       _now = now {
    _session.addListener(_documentChanged);
    _settings.addListener(_settingsChanged);
  }

  final PgnDocumentStore _documents;
  final DocumentSession _session;
  final SettingsStore _settings;
  final DateTime Function() _now;

  /// The set's file.
  final ChapterRef ref;

  SetState _state = const SetLoading();
  List<ChapterLine>? _readFrom;
  ({
    List<Puzzle> puzzles,
    PuzzleFilter filter,
    DateTime day,
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

  PuzzleFilter get filter => _settings.value.puzzles;

  /// The puzzles a session plays, in its order. Worked out again only when
  /// the puzzles, the filter or the day changes.
  List<Puzzle> get queue {
    final now = _now();
    final day = DateTime(now.year, now.month, now.day);
    final memo = _queued;
    if (memo != null &&
        identical(memo.puzzles, puzzles) &&
        memo.filter == filter &&
        memo.day == day) {
      return memo.queue;
    }
    final queue = queueOf(puzzles, filter, today: day);
    _queued = (puzzles: puzzles, filter: filter, day: day, queue: queue);
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
        _show(chapter.lines);
      case Absent():
        _become(const SetMissing());
      case Unreadable(:final detail):
        log.w('read ${ref.path}', detail);
        _become(SetUnreadable(detail));
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
    _show(chapter.lines);
  }

  void _show(List<ChapterLine> lines) {
    if (identical(lines, _readFrom)) return;
    _readFrom = lines;
    _become(SetReady(puzzlesOf(lines)));
  }

  void _become(SetState state) {
    _state = state;
    notifyListeners();
  }

  /// The filter lives in the settings, so a change to it is heard here.
  void _settingsChanged() {
    if (_queued?.filter != filter) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _session.removeListener(_documentChanged);
    _settings.removeListener(_settingsChanged);
    super.dispose();
  }
}
