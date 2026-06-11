/// Scrollable, searchable list of PGN game lines with hover board preview.
///
/// Shows matched lines from a PGN collection with fuzzy search, virtualized
/// scrolling, and [HoverableMoveChips] per row for floating board preview.
library;

import 'package:flutter/material.dart';

import '../core/board_preview_controller.dart';
import '../models/pgn_filter_models.dart';
import 'hoverable_move_chips.dart';

/// A browseable list of PGN game lines with search and hover board preview.
class LinesPreviewPanel extends StatefulWidget {
  /// All games in the collection.
  final List<GameRecord> allGames;

  /// Indices of games matching the current filter (null = show all).
  final List<int>? matchedIndices;

  /// Whether a slice computation is in progress.
  final bool computing;

  /// Board preview controller for hover previews.
  final BoardPreviewController? boardPreview;

  /// Opaque tag for owning the floating board preview.
  final Object? ownerTag;

  /// Called when a game is tapped (index into [allGames]).
  final ValueChanged<int>? onGameTapped;

  /// Maximum height for the panel (default: expands to fill).
  final double? maxHeight;

  const LinesPreviewPanel({
    super.key,
    required this.allGames,
    this.matchedIndices,
    this.computing = false,
    this.boardPreview,
    this.ownerTag,
    this.onGameTapped,
    this.maxHeight,
  });

  @override
  State<LinesPreviewPanel> createState() => _LinesPreviewPanelState();
}

class _LinesPreviewPanelState extends State<LinesPreviewPanel> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<int> get _effectiveIndices {
    final base =
        widget.matchedIndices ?? List.generate(widget.allGames.length, (i) => i);
    if (_searchQuery.isEmpty) return base;

    final query = _searchQuery.toLowerCase();
    return base.where((i) {
      final game = widget.allGames[i];
      final headers = game.headers;
      final white = (headers['White'] ?? '').toLowerCase();
      final black = (headers['Black'] ?? '').toLowerCase();
      final event = (headers['Event'] ?? '').toLowerCase();
      final opening = (headers['Opening'] ?? '').toLowerCase();
      if (white.contains(query) ||
          black.contains(query) ||
          event.contains(query) ||
          opening.contains(query)) {
        return true;
      }
      // Search in move text (first 80 chars for perf)
      final moveSnippet = game.pgnText.length > 80
          ? game.pgnText.substring(0, 80).toLowerCase()
          : game.pgnText.toLowerCase();
      return moveSnippet.contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    if (widget.computing) {
      return Container(
        constraints: widget.maxHeight != null
            ? BoxConstraints(maxHeight: widget.maxHeight!)
            : const BoxConstraints(),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.3)),
          color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(height: 12),
              Text(
                'Computing matches\u2026',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    final indices = _effectiveIndices;
    final total = widget.allGames.length;
    final matchCount = widget.matchedIndices?.length ?? total;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Status bar + search
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: Row(
            children: [
              Icon(Icons.format_list_numbered,
                  size: 16, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(
                '$matchCount / $total games',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: matchCount == 0 ? cs.error : cs.primary,
                ),
              ),
              if (_searchQuery.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  '(${indices.length} shown)',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ],
              const Spacer(),
              SizedBox(
                width: 160,
                height: 28,
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search...',
                    hintStyle:
                        TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                    prefixIcon:
                        Icon(Icons.search, size: 14, color: cs.onSurfaceVariant),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? GestureDetector(
                            onTap: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                            child: Icon(Icons.close,
                                size: 14, color: cs.onSurfaceVariant),
                          )
                        : null,
                    suffixIconConstraints:
                        const BoxConstraints(minWidth: 24, minHeight: 24),
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6)),
                  ),
                  style: const TextStyle(fontSize: 11),
                  onChanged: (v) => setState(() => _searchQuery = v.trim()),
                ),
              ),
            ],
          ),
        ),
        // Line list
        Flexible(
          child: Container(
            constraints: widget.maxHeight != null
                ? BoxConstraints(maxHeight: widget.maxHeight!)
                : const BoxConstraints(),
            decoration: BoxDecoration(
              border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.3)),
              borderRadius:
                  const BorderRadius.vertical(bottom: Radius.circular(8)),
            ),
            child: indices.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Center(
                      child: Text(
                        _searchQuery.isNotEmpty
                            ? 'No games match "$_searchQuery"'
                            : 'No games match the current filters',
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: indices.length,
                    shrinkWrap: widget.maxHeight == null,
                    itemBuilder: (context, listIdx) {
                      final gameIdx = indices[listIdx];
                      final game = widget.allGames[gameIdx];
                      return _GameLineRow(
                        game: game,
                        gameIndex: gameIdx,
                        listIndex: listIdx,
                        boardPreview: widget.boardPreview,
                        ownerTag: widget.ownerTag,
                        onTap: widget.onGameTapped != null
                            ? () => widget.onGameTapped!(gameIdx)
                            : null,
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

class _GameLineRow extends StatelessWidget {
  final GameRecord game;
  final int gameIndex;
  final int listIndex;
  final BoardPreviewController? boardPreview;
  final Object? ownerTag;
  final VoidCallback? onTap;

  const _GameLineRow({
    required this.game,
    required this.gameIndex,
    required this.listIndex,
    this.boardPreview,
    this.ownerTag,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final headers = game.headers;
    final white = headers['White'] ?? '?';
    final black = headers['Black'] ?? '?';
    final result = headers['Result'] ?? '';
    final event = headers['Event'];

    // Extract mainline moves (first 10 for preview)
    final moves = _extractMainlineMoves(game.pgnText, maxMoves: 10);

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: Border(
            bottom:
                BorderSide(color: cs.outlineVariant.withValues(alpha: 0.2)),
          ),
          color: listIndex % 2 == 0
              ? Colors.transparent
              : cs.surfaceContainerHighest.withValues(alpha: 0.3),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Player names + result
            Row(
              children: [
                Text(
                  '${listIndex + 1}.',
                  style: TextStyle(
                      fontSize: 10, color: cs.onSurfaceVariant),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '$white vs $black',
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (result.isNotEmpty)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      result,
                      style: TextStyle(
                          fontSize: 9, color: cs.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
            if (event != null && event.isNotEmpty && event != '?') ...[
              Padding(
                padding: const EdgeInsets.only(left: 20, top: 1),
                child: Text(
                  event,
                  style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            if (moves.isNotEmpty) ...[
              const SizedBox(height: 3),
              Padding(
                padding: const EdgeInsets.only(left: 20),
                child: HoverableMoveChips(
                  moves: moves,
                  maxMoves: 10,
                  fontSize: 10,
                  boardPreview: boardPreview,
                  ownerTag: ownerTag,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Extract mainline SAN moves from raw PGN movetext.
List<String> _extractMainlineMoves(String pgnText, {int maxMoves = 10}) {
  // Strip headers if present
  var text = pgnText;
  final headerEnd = text.lastIndexOf(']');
  if (headerEnd >= 0) {
    text = text.substring(headerEnd + 1);
  }

  // Remove comments and variations
  text = text.replaceAll(RegExp(r'\{[^}]*\}'), '');
  text = text.replaceAll(RegExp(r'\([^)]*\)'), '');

  // Tokenize: strip move numbers, result tokens
  final tokens = text
      .replaceAll(RegExp(r'\d+\.+'), '')
      .replaceAll(RegExp(r'(1-0|0-1|1/2-1/2|\*)'), '')
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty && !t.startsWith('\$'))
      .take(maxMoves)
      .toList();

  return tokens;
}
