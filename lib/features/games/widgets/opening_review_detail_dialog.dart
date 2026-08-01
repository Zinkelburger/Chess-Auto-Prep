import 'package:dartchess/dartchess.dart' show Chess, Position;
import 'package:flutter/material.dart';

import '../../../models/repertoire_line.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/chess_board_widget.dart';
import '../../../widgets/pgn_viewer_widget.dart';
import '../services/opening_review.dart';

enum _DetailTab { game, book }

/// One game in the review, as this dialog needs it: something to call it and
/// the movetext to step through.
///
/// A plain record rather than a `RecentGame`: the same dialog reviews an
/// arbitrary PGN opened in the viewer, which has no cache path, no platform
/// and no rating headers to speak of.
class ReviewGameSource {
  const ReviewGameSource({
    required this.label,
    required this.pgn,
    this.stableKey,
  });

  /// Menu/selector label, e.g. "vs Bob (Jul 12)".
  final String label;
  final String pgn;

  /// Seeds the viewer's [ValueKey] so switching games rebuilds it. Falls back
  /// to the label, which is unique enough for a selector.
  final String? stableKey;
}

/// One opening deviation, reviewable in place: a board with a Game / Your book
/// tab pair, both opened at the exact position where the game left the
/// repertoire. The Game tab steps through the actual game (the wrong move is
/// the next move from the landing position); the Your book tab steps through
/// the repertoire line(s) that pass through the same position, comments and
/// all — so "what should I have played, and why" is one tab flip away.
///
/// The dialog never pops itself for navigation: [onEditInBuilder] and
/// [onOpenGame] are expected to close the whole review stack (this dialog
/// and whatever list is under it) before switching screens.
class OpeningReviewDetailDialog extends StatefulWidget {
  const OpeningReviewDetailDialog({
    super.key,
    required this.chapterName,
    required this.matchedPlies,
    required this.playedDisplay,
    required this.expectedDisplay,
    required this.games,
    required this.bookEnd,
    required this.loadLines,
    this.flipped = false,
    this.onEditInBuilder,
    this.onOpenGame,
  });

  /// Build the dialog for an aggregate-review entry (the recent-games queue).
  factory OpeningReviewDetailDialog.forEntry({
    Key? key,
    required OpeningReviewEntry entry,
    required bool bookEnd,
    required List<ReviewGameSource> games,
    bool flipped = false,
    VoidCallback? onEditInBuilder,
    ValueChanged<int>? onOpenGame,
    Future<List<RepertoireLine>> Function(OpeningReviewEntry) loadLines =
        loadBookLinesForEntry,
  }) {
    return OpeningReviewDetailDialog(
      key: key,
      chapterName: entry.chapterName,
      matchedPlies: entry.matchedPlies,
      playedDisplay: entry.playedDisplay,
      expectedDisplay: entry.expectedDisplay,
      games: games,
      bookEnd: bookEnd,
      flipped: flipped,
      onEditInBuilder: onEditInBuilder,
      onOpenGame: onOpenGame,
      loadLines: () => loadLines(entry),
    );
  }

  final String chapterName;

  /// Plies matched before the game left book — the landing ply for both tabs.
  final int matchedPlies;

  /// "3... Nf6" and "3... cxd4 / 3... e6", already numbered.
  final String playedDisplay;
  final String expectedDisplay;

  final List<ReviewGameSource> games;

  /// Whether the prep simply ran out here (as opposed to a wrong move).
  final bool bookEnd;

  /// Board orientation: true when the reviewing player had Black.
  final bool flipped;

  /// The book lines through the deviation point, comments included.
  final Future<List<RepertoireLine>> Function() loadLines;

  final VoidCallback? onEditInBuilder;

  /// Open the selected game (by index into [games]) elsewhere, or null to
  /// omit the action — an arbitrary PGN is already open in the viewer.
  final ValueChanged<int>? onOpenGame;

  @override
  State<OpeningReviewDetailDialog> createState() =>
      _OpeningReviewDetailDialogState();
}

class _OpeningReviewDetailDialogState extends State<OpeningReviewDetailDialog> {
  _DetailTab _tab = _DetailTab.game;
  int _gameIndex = 0;
  int _lineIndex = 0;
  Position _gamePosition = Chess.initial;
  Position _bookPosition = Chess.initial;
  List<RepertoireLine>? _bookLines;

  /// Both viewers open at the position where the deviating move is about to
  /// be played — the decision point the user failed at the board.
  int get _landingMoveNumber => widget.matchedPlies ~/ 2 + 1;
  bool get _landingIsWhiteToPlay => widget.matchedPlies.isEven;

  @override
  void initState() {
    super.initState();
    widget.loadLines().then((lines) {
      if (mounted) setState(() => _bookLines = lines);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 940, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(context),
            const Divider(height: 1),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 5,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: ChessBoardWidget(
                            position: _tab == _DetailTab.game
                                ? _gamePosition
                                : _bookPosition,
                            enableUserMoves: false,
                            flipped: widget.flipped,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(flex: 4, child: _buildRightPane()),
                ],
              ),
            ),
            const Divider(height: 1),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final subtitle = widget.bookEnd
        ? 'Your book ends here — the game continued ${widget.playedDisplay}.'
        : 'You played ${widget.playedDisplay} — book plays '
              '${widget.expectedDisplay}.';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${widget.chapterName} · move $_landingMoveNumber',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.body.copyWith(
                    fontSize: 12,
                    color: AppColors.onSurfaceSoft,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildRightPane() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: SegmentedButton<_DetailTab>(
            segments: const [
              ButtonSegment(
                value: _DetailTab.game,
                label: Text('Game'),
                icon: Icon(Icons.sports_esports_outlined, size: 16),
              ),
              ButtonSegment(
                value: _DetailTab.book,
                label: Text('Your book'),
                icon: Icon(Icons.menu_book, size: 16),
              ),
            ],
            selected: {_tab},
            showSelectedIcon: false,
            onSelectionChanged: (selection) =>
                setState(() => _tab = selection.first),
          ),
        ),
        Expanded(
          // Both panes stay mounted so each tab keeps its board position
          // while the user flips between game and book.
          child: IndexedStack(
            index: _tab == _DetailTab.game ? 0 : 1,
            children: [_buildGamePane(), _buildBookPane()],
          ),
        ),
      ],
    );
  }

  Widget _buildGamePane() {
    if (widget.games.isEmpty) return const SizedBox.shrink();
    final game = widget.games[_gameIndex];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.games.length > 1)
          _buildSelectorRow(
            value: _gameIndex,
            labels: [for (final g in widget.games) g.label],
            onChanged: (i) => setState(() => _gameIndex = i),
          ),
        Expanded(
          child: PgnViewerWidget(
            key: ValueKey('game-${game.stableKey ?? game.label}'),
            pgnText: game.pgn,
            moveNumber: _landingMoveNumber,
            isWhiteToPlay: _landingIsWhiteToPlay,
            onPositionChanged: (position) =>
                setState(() => _gamePosition = position),
          ),
        ),
      ],
    );
  }

  Widget _buildBookPane() {
    final lines = _bookLines;
    if (lines == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (lines.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: Text(
            'Could not match this line inside ${widget.chapterName} '
            '(it may start from a custom position). '
            'Open the chapter in the builder to look at it.',
            textAlign: TextAlign.center,
            style: AppTextStyles.body.copyWith(
              fontSize: 13,
              color: AppColors.onSurfaceSoft,
            ),
          ),
        ),
      );
    }
    final line = lines[_lineIndex];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (lines.length > 1)
          _buildSelectorRow(
            value: _lineIndex,
            labels: [for (final l in lines) l.name],
            onChanged: (i) => setState(() => _lineIndex = i),
          ),
        Expanded(
          child: PgnViewerWidget(
            key: ValueKey('book-${line.id}-$_lineIndex'),
            pgnText: line.fullPgn,
            moveNumber: _landingMoveNumber,
            isWhiteToPlay: _landingIsWhiteToPlay,
            onPositionChanged: (position) =>
                setState(() => _bookPosition = position),
          ),
        ),
      ],
    );
  }

  Widget _buildSelectorRow({
    required int value,
    required List<String> labels,
    required ValueChanged<int> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: DropdownButton<int>(
        value: value,
        isExpanded: true,
        isDense: true,
        style: AppTextStyles.body.copyWith(fontSize: 13),
        items: [
          for (var i = 0; i < labels.length; i++)
            DropdownMenuItem(
              value: i,
              child: Text(labels[i], overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (i) {
          if (i != null) onChanged(i);
        },
      ),
    );
  }

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          // Reviewing comes first: the viewer shows this game with the Line tab
          // beside it, on a full-size board. Editing the book is the deliberate
          // second step, and says so.
          if (widget.onOpenGame != null && widget.games.isNotEmpty)
            FilledButton.icon(
              onPressed: () => widget.onOpenGame!(_gameIndex),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Open in viewer'),
            ),
          const SizedBox(width: 8),
          if (widget.onEditInBuilder != null)
            TextButton.icon(
              onPressed: widget.onEditInBuilder,
              icon: const Icon(Icons.edit, size: 16),
              label: const Text('Edit in Builder'),
            ),
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
