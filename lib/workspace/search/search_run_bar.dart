import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../chess/generation/expectimax_options.dart';
import '../../chess/generation/mainline_book.dart' show MainlineConfig;
import '../../chess/generation/search_node.dart';
import '../../storage/settings_store.dart';
import '../../ui/app_icons.dart';
import '../../ui/choice_field.dart';
import '../../ui/theme.dart';
import '../../ui/tool_button.dart';
import 'fill_gaps.dart';
import 'fill_states.dart';
import 'search_settings.dart';

/// The Expectimax panel's bar: the one button that starts, pauses and
/// resumes the search, its depth, where replies come from, and the gear,
/// each where it always is whatever the search is doing. A field that
/// does not fit the bar moves to a row under it.
class SearchRunBar extends StatelessWidget {
  const SearchRunBar({
    super.key,
    required this.fill,
    required this.settings,
    required this.settingsOpen,
    required this.onToggleSettings,
    required this.onProblem,
    required this.onSearch,
    required this.onDeeper,
    this.onShowPositions,
  });

  final FillGaps fill;
  final SettingsStore settings;

  /// The gear's settings are shown where the results are.
  final bool settingsOpen;
  final VoidCallback onToggleSettings;

  /// What is typed in a box and cannot be taken, or null once it can.
  final ValueChanged<String?> onProblem;

  /// Starts or resumes the search from the board.
  final VoidCallback onSearch;

  /// Searches one half-move deeper than the depth given.
  final ValueChanged<int> onDeeper;

  final VoidCallback? onShowPositions;

  ExpectimaxOptions get _options => settings.value.expectimax;

  bool get _book => _options.method == SearchMethod.mainline;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final replies = _book ? null : _repliesField();
      final fontSize = Theme.of(context).textTheme.labelLarge!.fontSize!;
      final scale = math.max(
        1.0,
        MediaQuery.textScalerOf(context).scale(fontSize) / fontSize,
      );
      final positions = onShowPositions == null
          ? 0.0
          : kMinInteractiveDimension;
      final available = size.maxWidth - Space.m - Space.xs - positions;
      final runWidth = math.min(
        searchRunWidth * scale,
        available - kMinInteractiveDimension,
      );
      final depthWidth = searchDepthWidth * scale;
      final repliesWidth = searchRepliesWidth * scale;
      final withDepth =
          runWidth + Space.s + depthWidth + kMinInteractiveDimension;
      // Account for the gear's whole hit target and scaled labels before
      // keeping controls on the bar. Extra fields move to the next row.
      final depthInBar = available >= withDepth;
      final inline = available >= withDepth + Space.s + repliesWidth;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: searchBarHeight,
            child: Padding(
              padding: const EdgeInsets.only(left: Space.m, right: Space.xs),
              child: Row(
                children: [
                  SizedBox(width: runWidth, child: _runButton()),
                  if (depthInBar) ...[
                    const SizedBox(width: Space.s),
                    _depthBox(width: depthWidth),
                  ],
                  if (inline && replies != null) ...[
                    const SizedBox(width: Space.s),
                    SizedBox(width: repliesWidth, child: replies),
                  ],
                  const Spacer(),
                  if (onShowPositions case final show?)
                    ToolButton(
                      icon: AppIcons.positions,
                      tooltip: 'Show the positions the searches found',
                      onPressed: show,
                    ),
                  ToolButton(
                    icon: AppIcons.settings,
                    tooltip: settingsOpen
                        ? 'Show results'
                        : 'Expectimax settings',
                    selected: settingsOpen,
                    onPressed: onToggleSettings,
                  ),
                ],
              ),
            ),
          ),
          if (!depthInBar || (!inline && replies != null))
            SizedBox(
              height: searchRepliesRowHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.m),
                child: Row(
                  children: [
                    if (!depthInBar) _depthBox(width: depthWidth),
                    if (!depthInBar && replies != null)
                      const SizedBox(width: Space.s),
                    if (!inline && replies != null) Expanded(child: replies),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _depthBox({required double width}) => Tooltip(
    message: _book
        ? 'Follow the opponent\'s master replies this many '
              'half-moves from the board; past it every line runs '
              'on as ChessDB\'s mainline.'
        : 'Half-moves searched from the board. Empty goes on '
              'until paused.',
    child: SearchNumberBox(
      name: SearchSettingCopy.depth.$1,
      label: SearchSettingCopy.depth.$1,
      empty: _book ? '${MainlineConfig.defaultBranchPlies}' : 'No limit',
      value: _options.depth,
      min: ExpectimaxOptions.minDepth,
      max: ExpectimaxOptions.maxDepth,
      width: width,
      enabled: !fill.running,
      onProblem: onProblem,
      onChanged: (depth) => unawaited(
        settings.update(
          settings.value.copyWith(expectimax: _options.withDepth(depth)),
        ),
      ),
    ),
  );

  /// Where the opponent's replies come from: typed or picked, taken at once.
  Widget _repliesField() => Tooltip(
    message:
        'Where the opponent\'s replies and how often each is played '
        'come from.',
    child: ChoiceField(
      text: _options.replies.label,
      options: [for (final source in ReplySource.values) source.label],
      hint: 'Maia or a database',
      label: SearchSettingCopy.replies.$1,
      enabled: !fill.running,
      onSubmitted: (picked) {
        final source = ReplySource.values
            .where((source) => source.label == picked)
            .firstOrNull;
        if (source == null || source == _options.replies) return;
        unawaited(
          settings.update(
            settings.value.copyWith(
              expectimax: _options.copyWith(replies: source),
            ),
          ),
        );
      },
    ),
  );

  /// Start, Resume or Pause: one button in one place.
  Widget _runButton() {
    final running = switch (fill.state) {
      final FillRunning running => running,
      _ => null,
    };
    if (running != null) {
      return Tooltip(
        message: 'Finish the current position, then pause and keep the results',
        child: FilledButton.icon(
          icon: const Icon(AppIcons.pause, size: IconSize.action),
          onPressed: running.stopping ? null : fill.finish,
          label: const Text('Pause'),
        ),
      );
    }
    // A search with these settings covers the board: pressing goes on, or
    // when it already reaches the depth asked for, one half-move deeper.
    final request = FillRequest.of(settings.value);
    final node = fill.nodeAtBoard(request: request);
    final resumable = node is OurNode || node is OpponentNode;
    final depth = request.depthPlies;
    if (resumable &&
        depth != null &&
        depth < ExpectimaxOptions.maxDepth &&
        searchedTo(node!, depth)) {
      return Tooltip(
        message: 'Searched $depth half-moves deep here; search ${depth + 1}',
        child: FilledButton.icon(
          onPressed: fill.canStart ? () => onDeeper(depth) : null,
          icon: const Icon(AppIcons.run, size: IconSize.action),
          label: const Text('Deeper'),
        ),
      );
    }
    return Tooltip(
      message: resumable
          ? 'Go on from the search at this board'
          : 'Search from the board',
      child: FilledButton.icon(
        onPressed: fill.canStart ? onSearch : null,
        icon: const Icon(AppIcons.run, size: IconSize.action),
        label: Text(
          resumable
              ? 'Resume'
              : _book
              ? 'Build'
              : 'Expectimax',
        ),
      ),
    );
  }
}
