import 'dart:async';

import 'package:dartchess/dartchess.dart' show Position;
import 'package:flutter/material.dart';

import '../../../models/repertoire_line.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/pgn_viewer_widget.dart';
import '../services/game_deviation_service.dart';
import '../services/my_repertoire_settings.dart';
import '../services/opening_review.dart';
import 'my_repertoires_panel.dart';

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
    setState(() => _reports = null);
    final reports = await _service.analyzeGameByRepertoire(
      gameSans: widget.sans,
      meWhite: _meWhite,
    );
    if (!mounted) return;
    setState(() => _reports = reports);
    // One book, one deviation: open it without making the user click twice.
    final only = reports.length == 1 ? reports.entries.first : null;
    if (only != null && !only.value.inBook)
      unawaited(_openLine(only.key, only.value));
  }

  void _setColour(bool meWhite) {
    if (_meWhite == meWhite) return;
    setState(() => _meWhite = meWhite);
    _closeLine();
    unawaited(_run());
  }

  void _closeLine() {
    setState(() {
      _openFolder = null;
      _openLines = null;
      _lineIndex = 0;
    });
  }

  Future<void> _openLine(String folder, DeviationReport report) async {
    setState(() {
      _openFolder = folder;
      _openLines = null;
      _lineIndex = 0;
    });
    final lines = await widget.loadLines(
      chapterPath: report.chapterPath,
      prefixSans: report.pathSans,
    );
    if (!mounted || _openFolder != folder) return;
    setState(() => _openLines = lines);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildColourRow(),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: _buildResults(),
          ),
        ),
        if (_openFolder != null) ...[
          const Divider(height: 1),
          Expanded(flex: 2, child: _buildLinePane()),
        ],
      ],
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
              bookName: folder.split(RegExp(r'[/\\]')).last,
              report: report,
              isOpen: _openFolder == folder,
              onShowLine: report.inBook
                  ? null
                  : () => _openFolder == folder
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
            'Could not match this line inside ${report.chapterName} (it may '
            'start from a custom position). Open the chapter in the builder '
            'to look at it.',
            textAlign: TextAlign.center,
            style: AppTextStyles.body.copyWith(
              fontSize: 12,
              color: AppColors.onSurfaceSoft,
            ),
          ),
        ),
      );
    }
    final index = _lineIndex.clamp(0, lines.length - 1);
    final line = lines[index];
    // Both the game and this line are parked at the move that went wrong: the
    // decision point, not the aftermath.
    final landingMoveNumber = report.matchedPlies ~/ 2 + 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
          child: Row(
            children: [
              const Icon(
                Icons.menu_book,
                size: 15,
                color: AppColors.onSurfaceMuted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  lines.length == 1
                      ? line.name
                      : '${lines.length} book lines reach move '
                            '$landingMoveNumber',
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.body.copyWith(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                tooltip: 'Hide this line',
                visualDensity: VisualDensity.compact,
                onPressed: _closeLine,
              ),
            ],
          ),
        ),
        _DivergenceNote(report: report, line: line),
        if (lines.length > 1)
          _LineChoices(
            lines: lines,
            selected: index,
            splitPly: report.matchedPlies,
            onSelect: (i) => setState(() => _lineIndex = i),
          ),
        Expanded(
          child: PgnViewerWidget(
            key: ValueKey('book-${line.id}-$index'),
            pgnText: line.fullPgn,
            controller: widget.lineController,
            moveNumber: landingMoveNumber,
            isWhiteToPlay: report.matchedPlies.isEven,
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
    final bookMove = _bookMoveAt(line, report.matchedPlies);
    final message = bookMove == null
        ? 'You played ${formatMoveAtPly(report.matchedPlies, played)} — this '
              'line stops here.'
        : 'You played ${formatMoveAtPly(report.matchedPlies, played)} — this '
              'line plays ${formatMoveAtPly(report.matchedPlies, bookMove)}.';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Row(
        children: [
          const Icon(Icons.fork_right, size: 14, color: AppColors.warning),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body.copyWith(
                fontSize: 12,
                color: AppColors.onSurfaceSoft,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Every book line through the deviation point, as one row each.
///
/// A dropdown hid the only thing worth comparing: the lines are identical up to
/// the fork, so what distinguishes them is the move they play *at* it. That move
/// is the label, with the line's name beside it — pick by the move, not by
/// remembering which chapter name meant what.
class _LineChoices extends StatelessWidget {
  const _LineChoices({
    required this.lines,
    required this.selected,
    required this.splitPly,
    required this.onSelect,
  });

  final List<RepertoireLine> lines;
  final int selected;

  /// Ply the game left the book at — the one move that differs between these.
  final int splitPly;

  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 108),
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.divider),
        borderRadius: BorderRadius.circular(6),
      ),
      child: ListView.builder(
        padding: EdgeInsets.zero,
        shrinkWrap: true,
        itemCount: lines.length,
        itemBuilder: (context, i) {
          final line = lines[i];
          final move = _bookMoveAt(line, splitPly);
          final isSelected = i == selected;
          return InkWell(
            onTap: () => onSelect(i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              color: isSelected ? AppColors.chipActiveBg : null,
              child: Row(
                children: [
                  SizedBox(
                    width: 62,
                    child: Text(
                      move == null
                          ? 'ends'
                          : formatMoveAtPly(splitPly, move).split(' ').last,
                      style: AppTextStyles.mono.copyWith(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: move == null
                            ? AppColors.onSurfaceMuted
                            : AppColors.ink,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      line.name,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.body.copyWith(
                        fontSize: 12,
                        color: AppColors.onSurfaceSoft,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${line.moves.length - splitPly} more',
                    style: AppTextStyles.body.copyWith(
                      fontSize: 11,
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
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
    final (icon, color, verdict) = switch (report) {
      DeviationReport(inBook: true) => (
        Icons.check_circle_outline,
        AppColors.successMuted,
        'In book the whole way (${report.matchedPlies} plies matched).',
      ),
      DeviationReport(bookEnded: true) => (
        Icons.more_horiz,
        AppColors.onSurfaceSoft,
        'Prep ends at move ${report.moveNumber} — the game continued '
            '${formatMoveAtPly(report.matchedPlies, report.playedSan!)}.',
      ),
      _ => (
        report.byMe == true ? Icons.warning_amber : Icons.info_outline,
        report.byMe == true ? AppColors.warning : AppColors.info,
        '${report.byMe == true ? 'You' : 'They'} left book at move '
            '${report.moveNumber}: '
            '${formatMoveAtPly(report.matchedPlies, report.playedSan!)} '
            'instead of ${report.expectedSans.join(' / ')}.',
      ),
    };

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
                  '$bookName · ${report.chapterName}',
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
              fontSize: 11,
              color: AppColors.onSurfaceSoft,
            ),
          ),
          if (report.pathSans.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              formatNumberedSans(report.pathSans),
              style: AppTextStyles.mono.copyWith(
                fontSize: 11,
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
