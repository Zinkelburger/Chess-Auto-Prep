import 'package:flutter/material.dart';

import '../chess/explorer_choice.dart';
import '../ui/theme.dart';
import 'explorer.dart';

/// The top of the Explorer tab: the databases side by side, the chosen one
/// pressed, and at the end `Filters` for the one that can be narrowed.
/// The filters fold away under it so the table keeps the room; what they
/// are set to shows beside the button while they are folded.
class ExplorerSourceBar extends StatefulWidget {
  const ExplorerSourceBar({super.key, required this.explorer});

  final Explorer explorer;

  @override
  State<ExplorerSourceBar> createState() => _ExplorerSourceBarState();
}

class _ExplorerSourceBarState extends State<ExplorerSourceBar> {
  bool _unfolded = false;

  Explorer get _explorer => widget.explorer;

  @override
  Widget build(BuildContext context) {
    final choice = _explorer.choice;
    final narrowable =
        choice.source == ExplorerSource.lichess ||
        choice.source == ExplorerSource.twic;
    final unfolded = narrowable && _unfolded;
    final summary = _explorer.summary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.m, Space.xs, Space.s, 0),
          // The end of the row goes under the databases when the card is
          // too narrow for both, and the databases scroll sideways when it
          // is too narrow for them alone: nothing is cut off.
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: _Sources(explorer: _explorer),
              ),
              if (summary != null)
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: explorerTrailingMaxWidth,
                  ),
                  child: _Summary(summary),
                ),
              if (narrowable)
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: explorerTrailingMaxWidth,
                  ),
                  child: TextButton(
                    onPressed: () {
                      if (!mounted) return;
                      setState(() => _unfolded = !_unfolded);
                    },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            unfolded ? 'Filters' : _folded(choice),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(
                          unfolded ? Icons.expand_less : Icons.expand_more,
                          size: IconSize.menu,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (unfolded)
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.m, 0),
            child: switch (choice.source) {
              ExplorerSource.lichess => _LichessFilters(explorer: _explorer),
              ExplorerSource.twic => _TwicFilters(explorer: _explorer),
              ExplorerSource.masters ||
              ExplorerSource.thisFile ||
              ExplorerSource.myGames => const SizedBox.shrink(),
            },
          ),
        const SizedBox(height: Space.xs),
      ],
    );
  }

  /// The folded button's words: what the filters are set to.
  String _folded(ExplorerChoice choice) {
    final narrowing = choice.narrowing;
    return narrowing.isEmpty ? 'Filters' : narrowing;
  }
}

/// The databases side by side, the chosen one pressed.
class _Sources extends StatelessWidget {
  const _Sources({required this.explorer});

  final Explorer explorer;

  @override
  Widget build(BuildContext context) {
    final choice = explorer.choice;
    return SegmentedButton<ExplorerSource>(
      segments: [
        for (final source in explorer.sources)
          ButtonSegment(value: source, label: Text(source.title)),
      ],
      selected: {choice.source},
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: Space.s),
        ),
      ),
      onSelectionChanged: (picked) =>
          explorer.choose(choice.copyWith(source: picked.single)),
    );
  }
}

/// What a source on this machine answers over, in muted words where the
/// filters of the online databases would be.
class _Summary extends StatelessWidget {
  const _Summary(this.words);

  final String words;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: Space.s, right: Space.s),
      child: Text(
        words,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.right,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// TWIC's one narrowing.
class _TwicFilters extends StatelessWidget {
  const _TwicFilters({required this.explorer});

  final Explorer explorer;

  @override
  Widget build(BuildContext context) {
    final choice = explorer.choice;
    return Align(
      alignment: Alignment.centerLeft,
      child: FilterChip(
        label: const Text('Classical OTB only'),
        selected: choice.classicalOnly,
        visualDensity: VisualDensity.compact,
        onSelected: (on) => explorer.choose(choice.copyWith(classicalOnly: on)),
      ),
    );
  }
}

/// The speeds and the rating bands the Lichess database is narrowed by.
/// The last chip of a row cannot be turned off: a request for no speed or
/// no rating is one Lichess answers with nothing.
class _LichessFilters extends StatelessWidget {
  const _LichessFilters({required this.explorer});

  final Explorer explorer;

  @override
  Widget build(BuildContext context) {
    final choice = explorer.choice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ChipRow(
          label: 'Speed',
          chips: [
            for (final speed in LichessSpeed.values)
              FilterChip(
                label: Text(speed.name),
                selected: choice.speeds.contains(speed),
                visualDensity: VisualDensity.compact,
                onSelected: (on) => _speed(choice, speed, on),
              ),
          ],
        ),
        const SizedBox(height: Space.xs),
        _ChipRow(
          label: 'Rating',
          chips: [
            for (final rating in lichessRatings)
              FilterChip(
                label: Text('$rating'),
                selected: choice.ratings.contains(rating),
                visualDensity: VisualDensity.compact,
                onSelected: (on) => _rating(choice, rating, on),
              ),
          ],
        ),
      ],
    );
  }

  void _speed(ExplorerChoice choice, LichessSpeed speed, bool on) {
    final speeds = {...choice.speeds};
    if (on) {
      speeds.add(speed);
    } else if (speeds.length > 1) {
      speeds.remove(speed);
    }
    explorer.choose(choice.copyWith(speeds: speeds));
  }

  void _rating(ExplorerChoice choice, int rating, bool on) {
    final ratings = {...choice.ratings};
    if (on) {
      ratings.add(rating);
    } else if (ratings.length > 1) {
      ratings.remove(rating);
    }
    explorer.choose(choice.copyWith(ratings: ratings));
  }
}

/// A muted label in its own gutter, then the chips.
class _ChipRow extends StatelessWidget {
  const _ChipRow({required this.label, required this.chips});

  final String label;
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: explorerMoveWidth,
          height: explorerChipHeight,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        Expanded(
          child: Wrap(spacing: Space.xs, runSpacing: Space.xs, children: chips),
        ),
      ],
    );
  }
}
