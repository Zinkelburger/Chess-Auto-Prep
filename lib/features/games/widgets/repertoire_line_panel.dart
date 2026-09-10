import 'dart:async';

import 'package:dartchess/dartchess.dart' show Position;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../models/repertoire_line.dart';
import '../../../models/repertoire_metadata.dart';
import '../../../services/storage/storage_factory.dart';
import '../../../widgets/common/choice_field.dart';
import '../../../widgets/common/list_search_field.dart';
import 'opening_position_preview.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/pgn_viewer_widget.dart';
import '../services/game_deviation_service.dart';
import '../services/my_repertoire_settings.dart';
import '../services/opening_review.dart';
import 'my_repertoires_panel.dart';
import '../../../utils/movetext_builder.dart';

/// "Where does *this* game leave my book, and what should I have played?" — as
/// a tab in the PGN viewer, beside Game and Analysis.
///
/// This was a dialog on top of a dialog: a popup listing the verdicts, which
/// opened a second popup with a small board to review the line on. Both were
/// re-creating, badly, what the viewer already is — a board with movetext next
/// to it. So it lives here instead: pick a colour, get one verdict per
/// designated book, and step through the prepared line on the *real* board,
/// with the game itself one tab away and the engine one tab further.
///
/// Every designated book for the chosen colour is reported separately: with two
/// White repertoires loaded, "the deepest match" is not the answer, "here is
/// what each of them says" is.
class RepertoireLinePanel extends StatefulWidget {
  const RepertoireLinePanel({
    super.key,
    required this.gameLabel,
    required this.sans,
    required this.initialMeWhite,
    required this.onShowPosition,
    this.onEditInBuilder,
    this.lineController,
    this.deviationService,
    this.settings,
    this.loadLines = loadBookLines,
    this.loadContents = loadBookChapterContents,
  });

  /// How the game reads in the header ("Bob vs Alice, Jul 12").
  final String gameLabel;

  /// Mainline SANs of the game on screen.
  final List<String> sans;

  /// Which side to check as, when the caller could work it out from the
  /// headers. Null starts on White and leaves it to the user.
  final bool? initialMeWhite;

  /// Push a position from the book line onto the viewer's board.
  final ValueChanged<Position> onShowPosition;

  /// Open the selected book chapter in the Repertoire Builder — the deliberate
  /// trip to *edit* the line, as opposed to reviewing it here.
  final void Function(DeviationReport report)? onEditInBuilder;

  /// Controller for the book-line movetext, so the screen's arrow keys can
  /// drive this pane while it is the active tab.
  final PgnViewerWidgetController? lineController;

  /// Injectable for tests.
  final GameDeviationService? deviationService;

  /// Which books are designated. Injectable for tests; defaults to the
  /// app-wide singleton the rest of the app writes.
  final MyRepertoireSettings? settings;

  /// Injectable for tests: the book lines through a deviation point.
  final Future<List<RepertoireLine>> Function({
    required String chapterPath,
    required List<String> prefixSans,
  })
  loadLines;

  final Future<List<RepertoireLine>> Function(String chapterPath) loadContents;

  @override
  State<RepertoireLinePanel> createState() => _RepertoireLinePanelState();
}

class _RepertoireLinePanelState extends State<RepertoireLinePanel> {
  late bool _meWhite;

  late final MyRepertoireSettings _settings =
      widget.settings ?? MyRepertoireSettings.instance;

  /// Repertoire folder → what that book says about this game. Null while the
  /// walk is running.
  Map<String, DeviationReport>? _reports;

  /// Which book's line is open below the verdicts (a folder key), and the lines
  /// loaded for it.
  String? _openFolder;
  List<RepertoireLine>? _openLines;
  int _lineIndex = 0;
  int _request = 0;
  int _lineRequest = 0;
  List<RepertoireMetadata> _chapters = const [];
  String? _chapterPath;
  bool _matchingOnly = true;
  String? _courseChapter;
  String _lineSearch = '';
  String? _loadError;

  GameDeviationService get _service =>
      widget.deviationService ?? GameDeviationService.instance;

  @override
  void initState() {
    super.initState();
    _meWhite = widget.initialMeWhite ?? true;
    _settings.addListener(_onDesignationsChanged);
    unawaited(_settings.ensureLoaded().then((_) => _run()));
  }

  @override
  void didUpdateWidget(covariant RepertoireLinePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different game arrived under the same panel (next game in the file).
    if (oldWidget.sans != widget.sans ||
        oldWidget.gameLabel != widget.gameLabel) {
      if (widget.initialMeWhite != null) _meWhite = widget.initialMeWhite!;
      _closeLine();
      unawaited(_run());
    }
  }

  @override
  void dispose() {
    _settings.removeListener(_onDesignationsChanged);
    super.dispose();
  }

  /// Designating a book from inside this panel should immediately produce a
  /// verdict for it, without a second trip through the menu.
  void _onDesignationsChanged() {
    _service.invalidateCache();
    unawaited(_run());
  }

  Future<void> _run() async {
    if (!mounted) return;
    final request = ++_request;
    setState(() => _reports = null);
    final reports = await _service.analyzeGameByRepertoire(
      gameSans: widget.sans,
      meWhite: _meWhite,
    );
    if (!mounted || request != _request) return;
    setState(() => _reports = reports);
    // One book, one deviation: open it without making the user click twice.
    final only = reports.length == 1 ? reports.entries.first : null;
    if (only != null) {
      unawaited(_openLine(only.key, only.value));
    }
  }

  void _setColour(bool meWhite) {
    if (!mounted || _meWhite == meWhite) return;
    setState(() => _meWhite = meWhite);
    _closeLine();
    unawaited(_run());
  }

  void _closeLine() {
    if (!mounted) return;
    ++_lineRequest;
    setState(() {
      _openFolder = null;
      _openLines = null;
      _lineIndex = 0;
      _loadError = null;
    });
  }

  Future<void> _openLine(String folder, DeviationReport report) async {
    if (!mounted) return;
    setState(() {
      _openFolder = folder;
      _chapters = const [];
      _chapterPath = report.chapterPath;
      _matchingOnly = !report.differentOpening;
      _courseChapter = null;
      _lineSearch = '';
      _loadError = null;
    });
    unawaited(_loadChapters(folder));
    await _loadSelectedChapter();
  }

  Future<void> _loadChapters(String folder) async {
    final List<RepertoireMetadata> chapters;
    try {
      chapters = await StorageFactory.instance.listChapters(folder);
    } catch (_) {
      return;
    }
    if (!mounted || _openFolder != folder) return;
    setState(() => _chapters = chapters);
  }

  Future<void> _loadSelectedChapter() async {
    if (!mounted) return;
    final report = _reports?[_openFolder];
    if (report == null || _chapterPath == null) return;
    final request = ++_lineRequest;
    setState(() {
      _openLines = null;
      _lineIndex = 0;
      _loadError = null;
    });
    try {
      final lines = _matchingOnly
          ? await widget.loadLines(
              chapterPath: _chapterPath!,
              prefixSans: report.pathSans,
            )
          : await widget.loadContents(_chapterPath!);
      if (!mounted || request != _lineRequest) return;
      setState(() => _openLines = lines);
    } catch (_) {
      if (!mounted || request != _lineRequest) return;
      setState(() {
        _openLines = const [];
        _loadError = 'Could not read this chapter. Try opening it again.';
      });
    }
  }

  Widget _buildContentsControls() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: Column(
      children: [
        if (_chapters.isNotEmpty)
          ChoiceField<String>(
            key: const ValueKey('book-chapter'),
            value: _chapterPath,
            label: 'Chapter',
            items: [
              for (final chapter in _chapters)
                ChoiceItem(value: chapter.filePath, label: chapter.name),
            ],
            onChanged: (path) {
              if (!mounted) return;
              setState(() {
                _chapterPath = path;
                _lineSearch = '';
                _courseChapter = null;
                _matchingOnly = false;
              });
              unawaited(_loadSelectedChapter());
            },
          ),
        const SizedBox(height: 4),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('Matching lines')),
            ButtonSegment(value: false, label: Text('Chapter contents')),
          ],
          selected: {_matchingOnly},
          showSelectedIcon: false,
          style: SegmentedButton.styleFrom(
            visualDensity: VisualDensity.compact,
          ),
          onSelectionChanged: (selection) {
            if (!mounted) return;
            setState(() {
              _matchingOnly = selection.first;
              _courseChapter = null;
              _lineSearch = '';
            });
            unawaited(_loadSelectedChapter());
          },
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildColourRow(),
        const Divider(height: 1),
        if (_openFolder == null)
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: _buildResults(),
            ),
          )
        else ...[
          _buildBookHeader(),
          _buildContentsControls(),
          Expanded(child: _buildLinePane()),
        ],
      ],
    );
  }

  Widget _buildBookHeader() {
    final report = _reports?[_openFolder];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: ChoiceField<String>(
              value: _openFolder,
              label: 'Book',
              compact: true,
              items: [
                for (final folder in _reports?.keys ?? <String>[])
                  ChoiceItem(value: folder, label: p.basename(folder)),
              ],
              onChanged: (folder) {
                if (!mounted) return;
                final selected = _reports?[folder];
                if (selected != null) unawaited(_openLine(folder, selected));
              },
            ),
          ),
          if (report != null && widget.onEditInBuilder != null)
            IconButton(
              tooltip: 'Edit this chapter in the Repertoire Builder',
              onPressed: () {
                if (!mounted) return;
                final chapterPath = _chapterPath ?? report.chapterPath;
                final selectedLine = _openLines?.elementAtOrNull(_lineIndex);
                final moves = _matchingOnly
                    ? report.pathSans
                    : selectedLine?.moves ?? const <String>[];
                widget.onEditInBuilder!(
                  DeviationReport(
                    matchedPlies: moves.length,
                    chapterPath: chapterPath,
                    chapterName:
                        _chapters
                            .where((chapter) => chapter.filePath == chapterPath)
                            .firstOrNull
                            ?.name ??
                        report.chapterName,
                    pathSans: moves,
                    lineName: selectedLine?.qualifiedName,
                  ),
                );
              },
              icon: const Icon(Icons.edit_outlined, size: 18),
            ),
        ],
      ),
    );
  }

  Widget _buildColourRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Text('I played', style: AppTextStyles.body.copyWith(fontSize: 12)),
          const SizedBox(width: 8),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('White')),
              ButtonSegment(value: false, label: Text('Black')),
            ],
            selected: {_meWhite},
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              textStyle: const TextStyle(fontSize: 12),
            ),
            onSelectionChanged: (s) => _setColour(s.first),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => showMyRepertoiresDialog(context),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('My books…'),
          ),
        ],
      ),
    );
  }

  Widget _buildResults() {
    if (widget.sans.isEmpty) {
      return _hint('This game has no moves to check.');
    }
    final designated = _settings.pathsFor(white: _meWhite);
    if (designated.isEmpty) {
      return _hint(
        'No ${_meWhite ? 'White' : 'Black'} book is designated, so there is '
        'nothing to compare this game against. Pick one with "My books…" '
        'above.',
      );
    }
    final reports = _reports;
    if (reports == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (reports.isEmpty) {
      return _hint(
        'The designated ${_meWhite ? 'White' : 'Black'} book has no usable '
        'chapters (folder missing, or every line starts from a custom '
        'position).',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final folder in designated)
          if (reports[folder] case final report?)
            _ReportTile(
              bookName: p.basename(folder),
              report: report,
              isOpen: _openFolder == folder,
              onShowLine: () => _openFolder == folder
                  ? _closeLine()
                  : _openLine(folder, report),
              onEditInBuilder: widget.onEditInBuilder == null
                  ? null
                  : () => widget.onEditInBuilder!(report),
            ),
      ],
    );
  }

  /// The prepared line itself, parked at the position where the game left it —
  /// stepping through it drives the viewer's board.
  Widget _buildLinePane() {
    final report = _reports?[_openFolder];
    final lines = _openLines;
    if (report == null) return const SizedBox.shrink();
    if (lines == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (lines.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: Text(
            _loadError ??
                (_matchingOnly
                    ? 'No matching lines in this chapter. Choose Chapter contents to browse it.'
                    : 'This chapter has no entries.'),
            textAlign: TextAlign.center,
            style: AppTextStyles.body.copyWith(
              fontSize: 12,
              color: AppColors.onSurfaceSoft,
            ),
          ),
        ),
      );
    }
    final visible = <int>[
      for (var i = 0; i < lines.length; i++)
        if ((_courseChapter == null || lines[i].chapter == _courseChapter) &&
            matchesSearch(_lineSearch, lines[i].qualifiedName))
          i,
    ];
    final index = _lineIndex.clamp(0, lines.length - 1);
    final line = lines[index];
    final bookPly = _matchingOnly ? report.pathSans.length : 0;
    final landingMoveNumber = bookPly ~/ 2 + 1;
    final chapters = lines
        .map((line) => line.chapter)
        .nonNulls
        .toSet()
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_matchingOnly) ...[
          if (chapters.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ChoiceField<String>(
                key: const ValueKey('book-course-chapter'),
                value: _courseChapter ?? '',
                label: 'Contents',
                items: [
                  const ChoiceItem(value: '', label: 'All chapters'),
                  for (final chapter in chapters)
                    ChoiceItem(value: chapter, label: chapter),
                ],
                onChanged: (chapter) {
                  if (!mounted) return;
                  setState(() {
                    _courseChapter = chapter.isEmpty ? null : chapter;
                    _lineSearch = '';
                    _lineIndex = lines.indexWhere(
                      (line) =>
                          _courseChapter == null ||
                          line.chapter == _courseChapter,
                    );
                  });
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
            child: ListSearchField(
              key: ValueKey('book-contents-search-$_courseChapter'),
              hintText: 'Search lines',
              onChanged: (query) {
                if (mounted) setState(() => _lineSearch = query);
              },
            ),
          ),
          Flexible(
            child: visible.isEmpty
                ? const Center(child: Text('No matching lines'))
                : Scrollbar(
                    child: ListView.builder(
                      key: const ValueKey('book-contents-list'),
                      itemCount: visible.length,
                      itemBuilder: (context, row) {
                        final i = visible[row];
                        return ListTile(
                          key: ValueKey('book-content-line-$i'),
                          dense: true,
                          selected: index == i,
                          selectedTileColor: AppColors.surfaceInset,
                          leading: Text(
                            '${i + 1}',
                            style: AppTextStyles.caption,
                          ),
                          title: Text(
                            lines[i].qualifiedName,
                            style: AppTextStyles.body,
                          ),
                          subtitle: Text(
                            formatNumberedSans(lines[i].moves),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.mono.copyWith(
                              color: AppColors.onSurfaceMuted,
                            ),
                          ),
                          onTap: () {
                            if (mounted) setState(() => _lineIndex = i);
                          },
                        );
                      },
                    ),
                  ),
          ),
          const Divider(height: 1),
        ],
        if (_matchingOnly &&
            report.playedSan != null &&
            !report.differentOpening)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
            child: Row(
              children: [
                OpeningPositionPreview(
                  pathSans: report.pathSans,
                  playedSan: report.playedSan,
                  expectedSans: [?_bookMoveAt(line, bookPly)],
                  byMe: report.byMe == true,
                  bookEnded: report.bookEnded,
                  flipped: !_meWhite,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _DivergenceNote(report: report, line: line),
                ),
              ],
            ),
          ),
        if (report.inBook && _matchingOnly)
          _hint(
            'In book the whole way (${report.matchedPlies} plies matched).',
          ),
        if (report.differentOpening)
          _hint('Different opening — browse this book below.'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: _matchingOnly
                    ? ChoiceField<int>(
                        key: const ValueKey('book-line'),
                        value: index,
                        hint: 'Search lines',
                        compact: true,
                        items: [
                          for (var i = 0; i < lines.length; i++)
                            ChoiceItem(
                              value: i,
                              label: lines[i].qualifiedName,
                              subtitle:
                                  _matchingOnly &&
                                      _bookMoveAt(lines[i], bookPly) != null
                                  ? 'Book plays ${formatMoveAtPly(bookPly, _bookMoveAt(lines[i], bookPly)!)}'
                                  : null,
                            ),
                        ],
                        onChanged: (i) {
                          if (!mounted) return;
                          setState(() => _lineIndex = i);
                        },
                      )
                    : Text(line.name, style: AppTextStyles.bodyStrong),
              ),
              IconButton(
                tooltip: 'Previous book line',
                icon: const Icon(Icons.chevron_left),
                onPressed: visible.indexOf(index) > 0
                    ? () {
                        if (!mounted) return;
                        setState(
                          () =>
                              _lineIndex = visible[visible.indexOf(index) - 1],
                        );
                      }
                    : null,
              ),
              Text(
                '${index + 1} / ${lines.length}',
                style: AppTextStyles.caption,
              ),
              IconButton(
                tooltip: 'Next book line',
                icon: const Icon(Icons.chevron_right),
                onPressed:
                    visible.contains(index) &&
                        visible.indexOf(index) + 1 < visible.length
                    ? () {
                        if (!mounted) return;
                        setState(
                          () =>
                              _lineIndex = visible[visible.indexOf(index) + 1],
                        );
                      }
                    : null,
              ),
            ],
          ),
        ),
        Expanded(
          flex: 2,
          child: PgnViewerWidget(
            key: ValueKey('book-${line.id}-$index-$_matchingOnly'),
            pgnText: line.fullPgn,
            showReadingOptions: false,
            bookFormatting: true,
            controller: widget.lineController,
            moveNumber: landingMoveNumber,
            isWhiteToPlay: bookPly.isEven,
            onPositionChanged: widget.onShowPosition,
          ),
        ),
      ],
    );
  }

  Widget _hint(String message) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Text(
      message,
      style: AppTextStyles.body.copyWith(
        fontSize: 12,
        color: AppColors.onSurfaceSoft,
      ),
    ),
  );
}

/// The move the book plays at [ply], or null when the line stops there.
///
/// Every line the loader returns shares the deviation's matched prefix (see
/// `matchingBookLines`), so this ply is exactly where they part company with the
/// game — and with each other.
String? _bookMoveAt(RepertoireLine line, int ply) =>
    ply < line.moves.length ? line.moves[ply] : null;

/// The one sentence the Line tab exists to say, pinned above the movetext: what
/// you played at the fork, and what this line plays instead.
///
/// A note rather than a comment written into the movetext: the chapter's own
/// comments are the author's and get saved; this is about *your* game and is
/// true only while that game is on the board. Parking both boards at the same
/// ply already puts the two moves side by side — this names them, so you don't
/// have to work out which move the cursor is sitting on.
class _DivergenceNote extends StatelessWidget {
  const _DivergenceNote({required this.report, required this.line});

  final DeviationReport report;
  final RepertoireLine line;

  @override
  Widget build(BuildContext context) {
    final played = report.playedSan;
    if (played == null) return const SizedBox.shrink();
    final bookMove = _bookMoveAt(line, report.pathSans.length);
    final who = report.byMe == true ? 'You' : 'They';
    final message = bookMove == null
        ? '$who played ${formatMoveAtPly(report.matchedPlies, played)} — this '
              'line stops here.'
        : '$who played ${formatMoveAtPly(report.matchedPlies, played)} — this '
              'line plays ${formatMoveAtPly(report.pathSans.length, bookMove)}.';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '$who played '),
                  TextSpan(
                    text: formatMoveAtPly(report.matchedPlies, played),
                    style: TextStyle(
                      color: report.byMe == true && !report.bookEnded
                          ? AppColors.danger
                          : AppColors.onSurfaceMuted,
                    ),
                  ),
                  TextSpan(
                    text: bookMove == null
                        ? ' — this line stops here.'
                        : ' — this line plays ',
                  ),
                  if (bookMove != null) ...[
                    TextSpan(
                      text: formatMoveAtPly(report.pathSans.length, bookMove),
                      style: const TextStyle(color: AppColors.success),
                    ),
                    const TextSpan(text: '.'),
                  ],
                ],
              ),
              style: AppTextStyles.bodyStrong.copyWith(color: AppColors.ink),
              semanticsLabel: message,
            ),
          ),
        ],
      ),
    );
  }
}

/// One book's verdict on the game: stayed in book, ran out of prep, or left it
/// at a named move.
class _ReportTile extends StatelessWidget {
  const _ReportTile({
    required this.bookName,
    required this.report,
    required this.isOpen,
    required this.onShowLine,
    required this.onEditInBuilder,
  });

  final String bookName;
  final DeviationReport report;
  final bool isOpen;
  final VoidCallback? onShowLine;
  final VoidCallback? onEditInBuilder;

  @override
  Widget build(BuildContext context) {
    final ply = report.matchedPlies;
    String at(String san) => formatMoveAtPly(ply, san);
    final (icon, color, verdict) = switch (report) {
      DeviationReport(differentOpening: true) => (
        Icons.menu_book_outlined,
        AppColors.onSurfaceMuted,
        'Different opening — this game did not enter this book. No repertoire mistake.',
      ),
      DeviationReport(inBook: true) => (
        Icons.check_circle_outline,
        AppColors.successMuted,
        'In book the whole way (${report.matchedPlies} plies matched).',
      ),
      DeviationReport(bookEnded: true) => (
        Icons.more_horiz,
        AppColors.onSurfaceSoft,
        'Book ends after ${report.pathSans.isEmpty ? 'the start' : formatMoveAtPly(ply - 1, report.pathSans.last)}'
            ' — the game continued ${at(report.playedSan!)}.',
      ),
      DeviationReport(byMe: true) => (
        Icons.alt_route,
        AppColors.warning,
        'You left book at move ${report.moveNumber}: '
            '${at(report.playedSan!)} instead of '
            '${report.expectedSans.map(at).join(' / ')}.'
            '${report.mentionedAlternative ? ' The book mentions ${at(report.playedSan!)} without recommending it.' : ''}',
      ),
      _ => (
        Icons.info_outline,
        AppColors.onSurfaceSoft,
        'Not in your book: ${at(report.playedSan!)} at move '
            '${report.moveNumber} — it covers '
            '${report.expectedSans.map(at).join(' / ')}.',
      ),
    };
    final place = report.lineName ?? report.chapterName;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(
          color: isOpen ? AppColors.outline : AppColors.divider,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '$bookName · $place',
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.body.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (onShowLine != null)
                TextButton(
                  onPressed: onShowLine,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(isOpen ? 'Hide line' : 'Show line'),
                ),
              if (onEditInBuilder != null)
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 15),
                  tooltip: 'Edit this chapter in the Repertoire Builder',
                  visualDensity: VisualDensity.compact,
                  onPressed: onEditInBuilder,
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            verdict,
            style: AppTextStyles.body.copyWith(
              fontWeight: FontWeight.w600,
              color: AppColors.ink,
            ),
          ),
          if (report.pathSans.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              formatNumberedSans(report.pathSans),
              style: AppTextStyles.mono.copyWith(
                fontSize: 12,
                color: AppColors.onSurfaceMuted,
              ),
            ),
          ],
          // The game got here by another order than the book writes: say
          // so, or the movetext above looks like a different game.
          if (report.gamePathSans case final gameOrder?) ...[
            const SizedBox(height: 4),
            Text(
              'Reached by transposition — you played '
              '${formatNumberedSans(gameOrder)}.',
              style: AppTextStyles.body.copyWith(
                fontSize: 12,
                color: AppColors.onSurfaceMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Detect which side the configured user played, from the game's headers.
/// Null when neither name matches — the panel then starts on White and lets
/// the user say.
bool? detectMySide({
  required Map<String, String> headers,
  required Iterable<String?> myUsernames,
}) {
  final names = {
    for (final u in myUsernames)
      if (u != null && u.trim().isNotEmpty) u.trim().toLowerCase(),
  };
  if (names.isEmpty) return null;
  if (names.contains((headers['White'] ?? '').trim().toLowerCase())) {
    return true;
  }
  if (names.contains((headers['Black'] ?? '').trim().toLowerCase())) {
    return false;
  }
  return null;
}
