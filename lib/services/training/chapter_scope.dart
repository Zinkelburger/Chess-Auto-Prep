/// Chapter grouping and scoping for a training session.
///
/// Answers three separate questions that [TrainingSessionController] used to
/// answer inline, tangled with drilling and scheduling state:
///
///  1. *Which chapter does this line belong to?* — depends on the grouping
///     mode (header chapters, a name prefix, or off) and on whether the user
///     declined chapters for this file.
///  2. *Does this file look chapter-organised?* — [detectChapterLayout] plus
///     the once-per-file "sort into chapters?" answer stored in
///     [AskedQuestionsStore].
///  3. *What is training scoped to right now?* — [activeChapter].
///
/// Deliberately knows nothing about queues, notification, or persistence of
/// review state. Mutators that change what the queue should contain return
/// `true` when something actually changed, so the owner can decide whether to
/// rebuild and notify.
library;

import '../../models/repertoire_line.dart';
import '../../models/training_settings.dart';
import '../asked_questions_store.dart';
import 'chapter_layout.dart';

class ChapterScope {
  ChapterScope({
    required this.askedQuestions,
    required TrainingSettings Function() settings,
    required List<RepertoireLine> Function() lines,
    required bool Function() sourceIsStudy,
  }) : _settings = settings,
       _lines = lines,
       _sourceIsStudy = sourceIsStudy;

  final AskedQuestionsStore askedQuestions;

  /// Read through suppliers rather than held copies: the owner reassigns its
  /// `settings` and `lines` fields wholesale (a settings reload, a new file),
  /// and a cached reference here would silently group by the previous file.
  final TrainingSettings Function() _settings;
  final List<RepertoireLine> Function() _lines;
  final bool Function() _sourceIsStudy;

  TrainingSettings get settings => _settings();

  /// Trainable lines only.  A course export can carry model games — real
  /// games included to show what the opening is played for — and being asked
  /// to reproduce forty moves of somebody else's game is not training, so
  /// they are filtered out here rather than in the file: browsing and study
  /// still show them.
  List<RepertoireLine> get lines => [
    for (final line in _lines())
      if (!line.isModelGame) line,
  ];

  /// A study's chapters are its puzzles — nothing to re-group.
  bool get sourceIsStudy => _sourceIsStudy();

  /// Sentinel [activeChapter] for "the lines this file's chapter scheme
  /// doesn't cover" — a real chapter name can never be a NUL byte.
  static const ungrouped = '__trainer_ungrouped__';

  /// Chapter the trainer is currently scoped to, or null for all lines.
  String? activeChapter;

  /// Chapter layout this file appears to use, waiting on the user's answer
  /// ("Looks like a course export — sort into chapters?"). Null when the file
  /// has no detectable layout or the question was already answered.
  ChapterLayoutProposal? pendingPrompt;

  /// The user said "keep one flat list" for this file.
  bool declined = false;

  /// Chapter layout detected in the loaded file, whether or not it is in use.
  /// Kept so the header's "Chapters…" entry point only appears when there is
  /// actually something to propose.
  ChapterLayoutProposal? _detectedLayout;

  bool get canOffer => _detectedLayout != null;

  /// The chapter a line belongs to under the current grouping setting.
  String? chapterOf(RepertoireLine line) {
    if (declined) return null;
    switch (settings.chapterGrouping) {
      case ChapterGroupingMode.off:
        return null;
      case ChapterGroupingMode.auto:
        return line.chapter;
      case ChapterGroupingMode.namePrefix:
        final delimiter = settings.chapterDelimiter;
        if (delimiter.isEmpty) return null;
        final cut = line.name.indexOf(delimiter);
        if (cut <= 0) return null;
        final prefix = line.name.substring(0, cut).trim();
        return prefix.isEmpty ? null : prefix;
    }
  }

  /// Whether [line] belongs to [chapter]; null means "all chapters" and
  /// [ungrouped] means "the lines with no chapter of their own".
  bool contains(RepertoireLine line, String? chapter) {
    if (chapter == null) return true;
    final own = chapterOf(line);
    return chapter == ungrouped ? own == null : own == chapter;
  }

  /// Distinct chapters in file order. Empty when the source has none.
  List<String> get names {
    final seen = <String>{};
    final ordered = <String>[];
    for (final line in lines) {
      final chapter = chapterOf(line);
      if (chapter != null && seen.add(chapter)) ordered.add(chapter);
    }
    return ordered;
  }

  /// Lines the chapter scheme leaves out (an intro game with no title, say).
  bool get hasUngroupedLines =>
      names.isNotEmpty && lines.any((line) => chapterOf(line) == null);

  /// [lines] scoped to [activeChapter].
  List<RepertoireLine> get scopedLines => activeChapter == null
      ? lines
      : [
          for (final line in lines)
            if (contains(line, activeChapter)) line,
        ];

  /// Scope training to [chapter] (null = all chapters).
  /// Returns whether the scope actually changed.
  bool setActive(String? chapter) {
    if (activeChapter == chapter) return false;
    activeChapter = chapter;
    return true;
  }

  /// The chapter grouping source changed — the old filter may not exist under
  /// the new scheme, so drop it and re-detect.
  void onSettingsChanged() {
    activeChapter = null;
    // The delimiter feeds name-prefix detection, so what the file *could* be
    // grouped by can change with the setting.
    _detectedLayout = sourceIsStudy
        ? null
        : detectChapterLayout(lines, delimiter: settings.chapterDelimiter);
  }

  /// Work out whether this newly loaded file looks chapter-organised, and
  /// whether the user has already answered for it. Clears the active filter,
  /// and sets [pendingPrompt] when the question is still open.
  ///
  /// [isStudy] is passed rather than read from [sourceIsStudy] on purpose: the
  /// caller runs across awaits and a concurrent handoff can flip the live
  /// field underneath it, so the load must decide from its own snapshot.
  Future<void> resolveLayout(String filePath, {required bool isStudy}) async {
    activeChapter = null;
    declined = false;
    pendingPrompt = null;
    _detectedLayout = null;
    if (isStudy) return;

    final proposal = detectChapterLayout(
      lines,
      delimiter: settings.chapterDelimiter,
    );
    _detectedLayout = proposal;
    if (proposal == null) return;

    final stored = await askedQuestions.boolAnswerFor(
      AskedQuestion.chapterLayout,
      subject: filePath,
    );
    if (stored == false) {
      declined = true;
      return;
    }
    if (stored == true) {
      await _applyMode(proposal.mode);
      return;
    }
    pendingPrompt = proposal;
  }

  Future<void> _applyMode(ChapterGroupingMode mode) async {
    if (settings.chapterGrouping == mode) return;
    settings.chapterGrouping = mode;
    await settings.save();
  }

  /// Answer the "sort into chapters?" prompt. The choice is remembered per
  /// file, so the question is asked once and stays changeable from the
  /// trainer header.
  ///
  /// [filePath] is the source being answered for; when null the answer applies
  /// to this session only and nothing is recorded.
  ///
  /// [onApplied] runs once the new grouping is in effect but before the answer
  /// is written to disk, so the owner can refresh and repaint without the user
  /// waiting on a file write.
  Future<void> answerPrompt(
    bool useChapters, {
    required String? filePath,
    void Function()? onApplied,
  }) async {
    final proposal = pendingPrompt;
    pendingPrompt = null;
    declined = !useChapters;
    activeChapter = null;
    if (useChapters && proposal != null) {
      await _applyMode(proposal.mode);
    }
    onApplied?.call();
    if (filePath == null) return;
    await askedQuestions.record(
      AskedQuestion.chapterLayout,
      subject: filePath,
      answer: useChapters,
      // What was on screen when they answered, so the stored file explains
      // itself months later.
      note: proposal == null
          ? null
          : '${proposal.formatLabel} · ${proposal.chapterCount} chapters',
    );
  }

  /// Drop the prompt without recording an answer — the user dismissed the
  /// dialog rather than choosing, so the next load should ask again.
  /// Returns whether a prompt was actually showing.
  bool dismissPrompt() {
    if (pendingPrompt == null) return false;
    pendingPrompt = null;
    return true;
  }

  /// Re-open the chapter prompt from the header ("Chapters…"), so a "no"
  /// answer is never final. Returns whether there was anything to re-open.
  bool reopenPrompt() {
    final proposal = _detectedLayout;
    if (proposal == null) return false;
    pendingPrompt = proposal;
    return true;
  }
}
