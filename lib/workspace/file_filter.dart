import 'dart:async';

import 'package:flutter/foundation.dart';

import '../chess/game_filter.dart';
import '../chess/fen.dart';
import '../chess/pgn/chapter.dart' show movesBeingRead;
import '../chess/pgn/chapter_line.dart';
import '../chess/pgn/game_text.dart';
import '../storage/chapter_files.dart';
import 'document_session.dart';
import 'filter_run.dart';

/// Which games of the open file pass the filter: the one filter both the
/// PGN Viewer's game list and the explorer's `This file` read. It is also
/// where `This file` learns what the open file's games are ([lines],
/// [file]), so the two agree on which games the numbers name.
///
/// The rules being typed ([filter]) apply a moment after the last change
/// ([delay], the old viewer's 300 ms), so a list of ten thousand games is
/// not filtered once per keystroke. What they apply to follows the
/// document: another file — opened, pasted onto the board, closed — clears
/// the rules and drops a change still waiting, so nothing typed for one file
/// lands on the next. An edit to the same file keeps the rules and filters
/// its games again at once.
final class FileFilter extends ChangeNotifier {
  FileFilter(
    this._session, {
    this.delay = const Duration(milliseconds: 300),
    this.timeout = const Duration(seconds: 2),
  }) {
    _session.addListener(_followTheDocument);
    _followTheDocument();
  }

  final DocumentSession _session;

  /// How long typing must rest before the rules apply.
  final Duration delay;
  final Duration timeout;
  FilterRun? _run;
  bool _disposed = false;
  bool _busy = false;
  String? _problem;
  int _revision = 0;

  /// Changes whenever the selection changes, even under identical rules.
  int get revision => _revision;
  bool get busy => _busy;
  String? get problem => _problem;

  GameFilter _filter = GameFilter.none;
  GameFilter _applied = GameFilter.none;
  Timer? _pending;
  ChapterRef? _file;
  List<ChapterLine> _lines = const [];

  /// Which games pass [applied], by place in the file; null when all do.
  List<bool>? _passes;
  int _kept = 0;
  final _values = <String, List<String>>{};
  List<String>? _headerNames;

  /// The rules as they stand, being typed or applied.
  GameFilter get filter => _filter;

  /// Capture once: later board navigation never changes the search target.
  void reachingBoardPosition() => reaching(_session.boardFen);
  void reaching(Fen position) => apply(_filter.copyWith(position: position));

  /// The rules the games were last filtered by.
  GameFilter get applied => _applied;

  /// Whether some rule is narrowing the games.
  bool get narrowing => _passes != null;

  /// The open file's games, as the filter last saw them.
  List<ChapterLine> get lines => _lines;

  /// The open file; null for the analysis board or nothing.
  ChapterRef? get file => _file;

  /// How many games the file has.
  int get total => _lines.length;

  /// How many of them pass.
  int get kept => _passes == null ? _lines.length : _kept;

  /// Whether the game at [index] of the file passes.
  bool keeps(int index) {
    final passes = _passes;
    return index >= 0 &&
        index < total &&
        (passes == null || (index < passes.length && passes[index]));
  }

  /// Takes [filter] as the rules being typed, applied once typing rests.
  void edit(GameFilter filter) {
    if (filter == _filter) return;
    _filter = filter;
    _cancelRun();
    _pending?.cancel();
    notifyListeners();
    if (delay == Duration.zero) {
      _apply();
    } else {
      _pending = Timer(delay, _apply);
    }
  }

  /// Takes [filter] as the rules at once: a rule added, removed or cleared,
  /// or all turned to any, is not typing.
  void apply(GameFilter filter) {
    _pending?.cancel();
    _filter = filter;
    _apply();
  }

  /// Every value [field] has in the file, sorted, each once: what a value
  /// box suggests while it is typed into. Worked out once per field until
  /// the file changes.
  List<String> valuesOf(String field) => _values.putIfAbsent(
    field,
    () => _sorted([
      for (final line in _lines)
        for (final header
            in field == playerField ? const ['White', 'Black'] : [field])
          tagValue(line.tags, header) ?? '',
    ]),
  );

  /// Every header name the file's games use, for the field box.
  List<String> get fields => _headerNames ??= _sorted([
    for (final line in _lines)
      for (final tag in line.tags)
        if (tag is PgnTag) tag.key,
  ]);

  void _apply() {
    _pending = null;
    _applied = _filter;
    _filterGames();
    notifyListeners();
  }

  void _filterGames() {
    _cancelRun();
    _revision++;
    _busy = false;
    _problem = null;
    if (_applied.isEmpty) {
      _passes = null;
      return;
    }
    if (_needsWorker) {
      // No positional matches from the previous snapshot may escape while
      // these headers are being read. The UI shows progress, not "no games".
      _passes = const [];
      _kept = 0;
      _busy = true;
      final moves = _applied.position != null || _applied.readsMoves;
      // A file just opened may still have its games' moves on their way
      // from the isolate reading them; a search of the moves starts when
      // they are here rather than read every game on this one.
      final read = moves ? movesBeingRead(_lines) : null;
      if (read == null) {
        _start(moves: moves);
      } else {
        final revision = _revision;
        unawaited(
          read.whenComplete(() {
            if (_disposed || revision != _revision || _run != null) return;
            _start(moves: moves);
          }),
        );
      }
      return;
    }
    _accept([
      for (final line in _lines)
        _applied.keeps((header) => tagValue(line.tags, header)),
    ]);
  }

  void _start({required bool moves}) {
    final run = _run = FilterRun.start(
      [for (final line in _lines) line.tags],
      _applied,
      timeout: moves ? const Duration(seconds: 15) : timeout,
      trees: moves ? [for (final line in _lines) line.tree] : null,
    );
    unawaited(_receive(run));
  }

  /// Small literal filters remain immediate. Regex, positions and move
  /// sequences always run elsewhere; ordinary filters also move off-thread
  /// once their input is substantial.
  bool get _needsWorker {
    if (_applied.position != null || _applied.readsMoves) return true;
    if (_applied.active.any((rule) => rule.rule == FilterRule.regex)) {
      return true;
    }
    if (_lines.length >= 500) return true;
    var size = 0;
    for (final line in _lines) {
      for (final tag in line.tags) {
        size += tag.text.length;
        if (size >= 64 * 1024) return true;
      }
    }
    return false;
  }

  Future<void> _receive(FilterRun run) async {
    List<bool>? passes;
    String? problem;
    try {
      passes = await run.result;
    } on TimeoutException {
      problem =
          'Filtering took too long. Simplify the rules or clear the filter.';
    } on Object {
      problem =
          'Could not filter these games. Change the rules or clear the filter.';
    }
    if (_disposed || _run != run) return;
    _run = null;
    _busy = false;
    _problem = problem;
    _accept(passes ?? const []);
    _revision++;
    notifyListeners();
  }

  void _accept(List<bool> passes) {
    _passes = passes;
    _kept = passes.where((pass) => pass).length;
  }

  void _cancelRun() {
    _run?.cancel();
    _run = null;
  }

  /// Another file clears the rules; the same file edited is filtered again.
  /// Switching games reads no new lines and does nothing.
  void _followTheDocument() {
    final lines = _session.chapter?.lines ?? const <ChapterLine>[];
    final file = _session.source;
    if (sameLines(lines, _lines) && file == _file) return;
    final another = !sameFile(file, _file);
    _lines = lines;
    _file = file;
    _values.clear();
    _headerNames = null;
    if (another) {
      _pending?.cancel();
      _pending = null;
      _filter = GameFilter.none;
      _applied = GameFilter.none;
    }
    _filterGames();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelRun();
    _pending?.cancel();
    _session.removeListener(_followTheDocument);
    super.dispose();
  }
}

/// Whether a document that was [was] and is now [now] is the same file —
/// edited, read again or showing another of its games — rather than
/// another file, a paste onto the analysis board or nothing. The board is
/// never the same file twice: what is on it was replaced.
bool sameFile(ChapterRef? now, ChapterRef? was) => now != null && now == was;

/// [values] trimmed, without blanks, `?` or repeats, in order.
List<String> _sorted(Iterable<String> values) => List.unmodifiable(
  {
    for (final value in values)
      if (value.trim() case final v when v.isNotEmpty && v != '?') v,
  }.toList()..sort(),
);
