import 'package:dartchess/dartchess.dart' show Chess, Position;
import 'package:flutter/material.dart';

import '../../../models/repertoire_line.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/chess_board_widget.dart';
import '../../../widgets/pgn_viewer_widget.dart';
import '../models/recent_game.dart';
import '../services/opening_review.dart';

enum _DetailTab { game, book }

/// One opening mistake, reviewable in place: a board with a Game / Your book
/// tab pair, both opened at the exact position where the game left the
/// repertoire. The Game tab steps through the actual game (the wrong move is
/// the next move from the landing position); the Your book tab steps through
/// the repertoire line(s) that pass through the same position, comments and
/// all — so "what should I have played, and why" is one tab flip away.
///
/// The dialog never pops itself for navigation: [onEditInBuilder] and
/// [onOpenGame] are expected to close the whole review stack (this dialog
/// and the list under it) before switching screens.
class OpeningReviewDetailDialog extends StatefulWidget {
  const OpeningReviewDetailDialog({
    super.key,
    required this.entry,
    required this.bookEnd,
    required this.onEditInBuilder,
    required this.onOpenGame,
    this.loadLines = loadBookLinesForEntry,
  });

  final OpeningReviewEntry entry;
  final bool bookEnd;
  final VoidCallback onEditInBuilder;
  final ValueChanged<RecentGame> onOpenGame;

  /// Injectable for tests — production uses [loadBookLinesForEntry].
  final Future<List<RepertoireLine>> Function(OpeningReviewEntry) loadLines;

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

  OpeningReviewEntry get _entry => widget.entry;

  /// Both viewers open at the position where the deviating move is about to
  /// be played — the decision point the user failed at the board.
  int get _landingMoveNumber => _entry.matchedPlies ~/ 2 + 1;
  bool get _landingIsWhiteToPlay => _entry.matchedPlies.isEven;

  bool get _flipped =>
      _entry.games.isNotEmpty && _entry.games.first.meWhite == false;

  @override
  void initState() {
    super.initState();
    widget.loadLines(_entry).then((lines) {
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
                            flipped: _flipped,
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
        ? 'Your book ends here — the game continued ${_entry.playedDisplay}.'
        : 'You played ${_entry.playedDisplay} — book plays '
              '${_entry.expectedDisplay}.';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_entry.chapterName} · move ${_entry.moveNumber}',
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
    if (_entry.games.isEmpty) return const SizedBox.shrink();
    final game = _entry.games[_gameIndex];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_entry.games.length > 1)
          _buildSelectorRow(
            value: _gameIndex,
            labels: [
              for (final g in _entry.games)
                'vs ${g.meWhite == true ? g.black : g.white} '
                    '(${g.dateDisplayShort})',
            ],
            onChanged: (i) => setState(() => _gameIndex = i),
          ),
        Expanded(
          child: PgnViewerWidget(
            key: ValueKey('game-${game.record.dedupKey}'),
            pgnText: game.record.pgn,
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
            'Could not match this line inside ${_entry.chapterName} '
            '(it may start from a custom position). '
            'Use "Edit in Builder" below to open the chapter.',
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
          TextButton.icon(
            onPressed: widget.onEditInBuilder,
            icon: const Icon(Icons.edit, size: 16),
            label: const Text('Edit in Builder'),
          ),
          if (_entry.games.isNotEmpty)
            TextButton.icon(
              onPressed: () => widget.onOpenGame(_entry.games[_gameIndex]),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Open game in viewer'),
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
