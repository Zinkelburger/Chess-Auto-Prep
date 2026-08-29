/// The outline panel's flattened row list.
///
/// The panel renders a lazy list, so the tree has to be flattened into rows
/// first; that flattening — which folders are open, which chapters unfold,
/// which lines survive the search and position filters — is done here by
/// [OutlineRowBuilder], once per change of its inputs (see
/// `RepertoireOutlineController.rows`).  Rows are value objects the panel
/// turns into widgets on demand.
library;

import 'package:flutter/foundation.dart' show immutable, listEquals;
import 'package:path/path.dart' as p;

import 'repertoire_outline.dart';

/// What the user is filtering the outline by.
@immutable
class OutlineFilter {
  /// Lowercase, trimmed search text; empty for none.
  final String search;

  /// Only lines through the board position ([currentMoves]).
  final bool atPosition;

  /// SAN sequence on the board.
  final List<String> currentMoves;

  const OutlineFilter({
    this.search = '',
    this.atPosition = false,
    this.currentMoves = const [],
  });

  static const OutlineFilter none = OutlineFilter();

  bool get isActive =>
      search.isNotEmpty || (atPosition && currentMoves.isNotEmpty);

  @override
  bool operator ==(Object other) =>
      other is OutlineFilter &&
      other.search == search &&
      other.atPosition == atPosition &&
      listEquals(other.currentMoves, currentMoves);

  @override
  int get hashCode =>
      Object.hash(search, atPosition, Object.hashAll(currentMoves));
}

/// One row of the panel.  Every row is [OutlineRow.height] tall so the list
/// can use a fixed item extent.
sealed class OutlineRow {
  const OutlineRow({required this.depth});

  /// Indentation level.
  final int depth;

  /// Fixed row height, shared with the list's `itemExtent`.
  static const double height = 30;

  /// Stable identity for the list's keys.
  Object get key;
}

class FolderRow extends OutlineRow {
  const FolderRow({
    required this.folder,
    required super.depth,
    required this.expanded,
  });

  final OutlineFolder folder;
  final bool expanded;

  @override
  Object get key => ('folder', folder.path);
}

class ChapterRow extends OutlineRow {
  const ChapterRow({
    required this.chapter,
    required super.depth,
    required this.active,
    required this.open,
    required this.visibleLines,
  });

  final OutlineChapter chapter;
  final bool active;
  final bool open;

  /// Lines shown under the chapter given the filter (all of them unfiltered).
  final int visibleLines;

  @override
  Object get key => ('chapter', chapter.path);
}

class SectionRow extends OutlineRow {
  const SectionRow({
    required this.chapter,
    required this.title,
    required super.depth,
    required this.count,
  });

  final OutlineChapter chapter;

  /// Section title; null for the untitled lines of a sectioned chapter.
  final String? title;
  final int count;

  @override
  Object get key => ('section', chapter.path, title);
}

class LineRow extends OutlineRow {
  const LineRow({
    required this.chapter,
    required this.line,
    required super.depth,
  });

  final OutlineChapter chapter;
  final OutlineLine line;

  @override
  Object get key => ('line', chapter.path, line.gameIndex);
}

class HintRow extends OutlineRow {
  const HintRow({
    required this.chapter,
    required super.depth,
    required this.text,
  });

  final OutlineChapter chapter;
  final String text;

  @override
  Object get key => ('hint', chapter.path);
}

/// Flattens an outline into rows under a filter and fold state.
class OutlineRowBuilder {
  const OutlineRowBuilder({
    required this.filter,
    required this.isExpanded,
    required this.isChapterOpen,
    required this.activeChapterPath,
  });

  final OutlineFilter filter;
  final bool Function(String folderPath) isExpanded;
  final bool Function(String chapterPath) isChapterOpen;
  final String? activeChapterPath;

  List<OutlineRow> build(OutlineFolder root) {
    final rows = <OutlineRow>[];
    _appendFolder(rows, root, depth: 0, isRoot: true);
    return List.unmodifiable(rows);
  }

  bool _lineVisible(OutlineLine line) {
    if (filter.atPosition && !line.passesThrough(filter.currentMoves)) {
      return false;
    }
    return filter.search.isEmpty || line.matches(filter.search);
  }

  int _visibleCount(OutlineChapter chapter) {
    final lines = chapter.lines;
    if (lines == null) return chapter.lineCount;
    if (!filter.isActive) return lines.length;
    return lines.where(_lineVisible).length;
  }

  /// A name hit keeps a chapter or folder even when none of its lines match.
  /// Only a real search term can hit — the "at this position" filter has no
  /// text, and every name contains the empty string.
  bool _nameHit(String nameLower) =>
      filter.search.isNotEmpty && nameLower.contains(filter.search);

  bool _chapterVisible(OutlineChapter chapter, int visibleCount) =>
      !filter.isActive || visibleCount > 0 || _nameHit(chapter.nameLower);

  bool _folderVisible(OutlineFolder folder) =>
      !filter.isActive ||
      _nameHit(folder.nameLower) ||
      folder.chapterList.any((c) => _chapterVisible(c, _visibleCount(c)));

  void _appendFolder(
    List<OutlineRow> rows,
    OutlineFolder folder, {
    required int depth,
    required bool isRoot,
  }) {
    if (!isRoot) {
      if (!_folderVisible(folder)) return;
      final expanded = isExpanded(folder.path);
      rows.add(FolderRow(folder: folder, depth: depth, expanded: expanded));
      if (!expanded) return;
    }
    final childDepth = isRoot ? depth : depth + 1;
    for (final child in folder.children) {
      switch (child) {
        case OutlineFolder f:
          _appendFolder(rows, f, depth: childDepth, isRoot: false);
        case OutlineChapter c:
          _appendChapter(rows, c, depth: childDepth);
        case OutlineLine _:
          break;
      }
    }
  }

  void _appendChapter(
    List<OutlineRow> rows,
    OutlineChapter chapter, {
    required int depth,
  }) {
    final visibleCount = _visibleCount(chapter);
    if (!_chapterVisible(chapter, visibleCount)) return;
    final active =
        activeChapterPath != null && p.equals(activeChapterPath!, chapter.path);
    // A filter unfolds every chapter that has a hit; otherwise the user's
    // fold state rules.
    final open = filter.isActive || isChapterOpen(chapter.path);
    rows.add(
      ChapterRow(
        chapter: chapter,
        depth: depth,
        active: active,
        open: open,
        visibleLines: visibleCount,
      ),
    );
    if (!open) return;
    final lines = chapter.lines;
    if (lines == null) return;
    if (lines.isEmpty) {
      rows.add(
        HintRow(
          chapter: chapter,
          depth: depth + 1,
          text: 'Empty — add lines to fill this chapter.',
        ),
      );
      return;
    }
    final bySection = chapter.linesBySection;
    if (bySection.isEmpty) {
      for (final line in lines) {
        if (_lineVisible(line)) {
          rows.add(LineRow(chapter: chapter, line: line, depth: depth + 1));
        }
      }
      return;
    }
    for (final entry in bySection.entries) {
      final inSection = filter.isActive
          ? entry.value.where(_lineVisible).toList()
          : entry.value;
      if (inSection.isEmpty) continue;
      rows.add(
        SectionRow(
          chapter: chapter,
          title: entry.key,
          depth: depth + 1,
          count: inSection.length,
        ),
      );
      for (final line in inSection) {
        rows.add(LineRow(chapter: chapter, line: line, depth: depth + 2));
      }
    }
  }
}

/// A flattened row list with the inputs it was built from.
class OutlineRowCache {
  const OutlineRowCache({
    required this.outline,
    required this.viewVersion,
    required this.filter,
    required this.rows,
  });

  final OutlineFolder outline;
  final int viewVersion;
  final OutlineFilter filter;
  final List<OutlineRow> rows;
}
