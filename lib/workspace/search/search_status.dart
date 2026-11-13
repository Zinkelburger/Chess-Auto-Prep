import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../chess/generation/evaluation_source.dart';
import '../../chess/generation/expectimax_options.dart';
import '../../storage/settings_store.dart';
import '../../ui/app_icons.dart';
import '../../ui/app_keys.dart';
import '../../ui/theme.dart';
import '../document/document_session.dart';
import 'fill_gaps.dart';
import 'fill_states.dart';
import 'finds.dart';

/// The Expectimax panel's status: one line of fixed height with the side,
/// then what will run, how far the search has got, what it did, or what
/// went wrong. While a search with no depth runs, the way to let it finish
/// the depth it is on sits at the line's end.
class SearchStatusLine extends StatelessWidget {
  const SearchStatusLine({
    super.key,
    required this.fill,
    required this.session,
    required this.settings,
    this.problem,
    this.onShowPositions,
  });

  final FillGaps fill;
  final DocumentSession session;
  final SettingsStore settings;

  /// Why the last press did nothing, or what is typed and cannot be taken;
  /// said instead of the search's own state.
  final String? problem;

  final VoidCallback? onShowPositions;

  ExpectimaxOptions get _options => settings.value.expectimax;

  static String _positions(int n) => n == 1 ? '1 position' : '$n positions';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = fill.state;
    final problem = this.problem;
    final (words, error) = switch (state) {
      _ when problem != null => (problem, true),
      FillIdle() => (_summary, false),
      FillRunning(:final lastPly?, :final nodes, stopping: false) => (
        'Pausing after depth $lastPly · ${_positions(nodes)}',
        false,
      ),
      FillRunning(
        :final depth,
        :final of,
        :final nodes,
        :final stopping,
        :final levelShare,
      ) =>
        (
          '${stopping ? 'Pausing at depth' : 'Depth'} $depth'
              '${of == null || stopping ? '' : ' of $of'}'
              '${levelShare == null || stopping ? '' : ' (${(levelShare * 100).floor()}%)'}'
              ' · ${_positions(nodes)}',
          false,
        ),
      FillDone(
        :final depth,
        :final nodes,
        :final complete,
        :final sourceLost,
        :final stoppedBy,
      ) =>
        (
          '${complete ? 'Finished depth' : 'Stopped at depth'} $depth · '
              '${_positions(nodes)}'
              '${sourceLost ? ' · ChessDB stopped answering' : ''}'
              '${stoppedBy == null ? '' : ' · $stoppedBy'}${_findsWords()}',
          false,
        ),
      FillFailed(:final reason) => (reason, true),
    };
    return SizedBox(
      height: searchStatusHeight,
      child: Padding(
        padding: const EdgeInsets.only(left: Space.xs, right: Space.xs),
        child: Row(
          children: [
            _sideButton(),
            const SizedBox(width: Space.s),
            // The line is one line; resting on it says the rest.
            Expanded(
              child: Tooltip(
                message: words,
                child: Text(
                  words,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: error ? theme.colorScheme.error : null,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            _statusEnd(state),
          ],
        ),
      ),
    );
  }

  /// What the next search will be.
  String get _summary {
    if (_options.method == SearchMethod.mainline) {
      return 'ChessDB\'s best moves, master replies';
    }
    final e = _options;
    final maia = 'Maia ${settings.value.opponentElo}';
    return [
      if (e.replies == ReplySource.maia)
        maia
      else if (e.maiaFallback)
        '$maia under ${e.fallbackUnder} games',
      'best ${e.rootMoves}, then ${e.candidateMoves}',
      if (e.bothSides) 'both sides',
      if (e.source != EvaluationSource.stockfish) e.source.label,
    ].join(' · ');
  }

  /// The side the search prepares, which is the bottom of the board, as a
  /// button that turns the board to the other. Held while a search runs,
  /// as the rest of its settings are.
  Widget _sideButton() {
    final white = session.orientation == Side.white;
    return Tooltip(
      message: AppKey.flip.tip(
        'Search for ${white ? 'Black' : 'White'} and turn the board',
      ),
      child: TextButton.icon(
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: Space.s),
        ),
        onPressed: fill.running ? null : session.flip,
        icon: const Icon(AppIcons.flip, size: IconSize.action),
        label: Text(white ? 'White' : 'Black'),
      ),
    );
  }

  /// The status line's end: `Finish depth N` while a search with no depth
  /// runs, `N found` after a run that found something, else a gap.
  Widget _statusEnd(FillState state) {
    if (state case FillRunning(
      of: null,
      lastPly: null,
      stopping: false,
      :final depth,
    )) {
      return Tooltip(
        message:
            'Score every position at this depth, then pause and '
            'keep the tree',
        child: TextButton(
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          onPressed: fill.finishLevel,
          child: Text('Finish depth ${depth < 1 ? 1 : depth}'),
        ),
      );
    }
    if (_found case final count?) {
      return Tooltip(
        message: 'Show the positions this search found',
        child: TextButton(
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          onPressed: onShowPositions,
          child: Text('$count found'),
        ),
      );
    }
    return const SizedBox(width: Space.s);
  }

  /// What went wrong keeping what the run pointed out.
  String _findsWords() => switch (fill.finds?.recorded) {
    FindsUnsaved() => ' · search positions not saved',
    _ => '',
  };

  /// How many positions the last run pointed out, once kept and when the
  /// Positions can be shown; the button at the status line's end.
  int? get _found => switch (fill.finds?.recorded) {
    FindsKept(:final count)
        when count > 0 && onShowPositions != null && fill.state is FillDone =>
      count,
    _ => null,
  };
}
