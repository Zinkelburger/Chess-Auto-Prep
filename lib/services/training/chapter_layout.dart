/// Detecting how a repertoire file organises its lines into chapters.
///
/// Course exports (Chessable and friends) title every game's chapter in the
/// `[White]` header and its variation in `[Black]`; hand-made files often
/// encode the same thing in the line name ("3...c6 #2"). Both are offered to
/// the user as "looks like `<format>` — sort into chapters?" instead of being
/// silently applied, because guessing wrong turns one list into 40 stubs.
library;

import '../../models/repertoire_line.dart';
import '../../models/training_settings.dart';

/// One chapter of a proposed layout: its title and how many lines land in it.
class ChapterSummary {
  final String name;
  final int lineCount;

  const ChapterSummary({required this.name, required this.lineCount});
}

/// A chapter layout the file appears to use, ready to show the user.
class ChapterLayoutProposal {
  /// Grouping source that produces [chapters].
  final ChapterGroupingMode mode;

  /// Short name of the format, used in the prompt title —
  /// "a course export", "chapter names in the line titles".
  final String formatLabel;

  /// One sentence explaining where the names come from.
  final String explanation;

  final List<ChapterSummary> chapters;

  /// Lines that fall outside every chapter.
  final int ungroupedLineCount;

  const ChapterLayoutProposal({
    required this.mode,
    required this.formatLabel,
    required this.explanation,
    required this.chapters,
    this.ungroupedLineCount = 0,
  });

  int get chapterCount => chapters.length;
  int get groupedLineCount =>
      chapters.fold(0, (sum, chapter) => sum + chapter.lineCount);
}

/// The chapter layout [lines] appear to use, or null when they look like a
/// plain flat list.
///
/// [delimiter] is [TrainingSettings.chapterDelimiter] — the separator tried
/// for name-prefix chapters ("Reversed Meran # 4" → "Reversed Meran").
ChapterLayoutProposal? detectChapterLayout(
  List<RepertoireLine> lines, {
  String delimiter = '#',
}) {
  if (lines.length < 4) return null;

  // Header chapters win: the parser already validated them against the
  // whole file (see RepertoireService.detectHeaderChapters).
  final headerProposal = _summarize(
    lines,
    (line) => line.chapter,
    mode: ChapterGroupingMode.auto,
    formatLabel: 'a course export',
    explanation:
        'Every game in this PGN names its chapter in the [White] header '
        '(how Chessable and similar courses export).',
  );
  if (headerProposal != null) return headerProposal;

  if (delimiter.isEmpty) return null;
  return _summarize(
    lines,
    (line) {
      final cut = line.name.indexOf(delimiter);
      if (cut <= 0) return null;
      final prefix = line.name.substring(0, cut).trim();
      return prefix.isEmpty ? null : prefix;
    },
    mode: ChapterGroupingMode.namePrefix,
    formatLabel: 'chapter names inside the line titles',
    explanation:
        'Line names look like "Chapter $delimiter variation", so everything '
        'before the "$delimiter" can become a chapter.',
  );
}

/// Groups [lines] by [chapterOf] and returns a proposal when the grouping is
/// real: at least two chapters, at least one holding several lines, and most
/// of the file covered.
ChapterLayoutProposal? _summarize(
  List<RepertoireLine> lines,
  String? Function(RepertoireLine line) chapterOf, {
  required ChapterGroupingMode mode,
  required String formatLabel,
  required String explanation,
}) {
  final counts = <String, int>{};
  int ungrouped = 0;
  for (final line in lines) {
    final chapter = chapterOf(line);
    if (chapter == null) {
      ungrouped++;
    } else {
      counts[chapter] = (counts[chapter] ?? 0) + 1;
    }
  }

  if (counts.length < 2) return null;
  if (!counts.values.any((count) => count >= 2)) return null;
  final grouped = lines.length - ungrouped;
  if (grouped * 2 < lines.length) return null;

  return ChapterLayoutProposal(
    mode: mode,
    formatLabel: formatLabel,
    explanation: explanation,
    chapters: [
      for (final entry in counts.entries)
        ChapterSummary(name: entry.key, lineCount: entry.value),
    ],
    ungroupedLineCount: ungrouped,
  );
}
