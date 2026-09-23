import 'dart:async';

import 'package:flutter/foundation.dart';

import '../chess/game_filter.dart';
import '../chess/pgn/chapter_line.dart';
import '../chess/pgn/game_text.dart';
import '../storage/chapter_files.dart';
import 'document_session.dart';

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
  FileFilter(this._session, {this.delay = const Duration(milliseconds: 300)}) {
    _session.addListener(_followTheDocument);
    _followTheDocument();
  }

  final DocumentSession _session;

  /// How long typing must rest before the rules apply.
  final Duration delay;

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
    return passes == null || (index < passes.length && passes[index]);
  }

  /// Takes [filter] as the rules being typed, applied once typing rests.
  void edit(GameFilter filter) {
    if (filter == _filter) return;
    _filter = filter;
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
    if (_applied.isEmpty) {
      _passes = null;
      return;
    }
    final passes = [
      for (final line in _lines)
        _applied.keeps((header) => tagValue(line.tags, header)),
    ];
    _passes = passes;
    _kept = passes.where((pass) => pass).length;
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
