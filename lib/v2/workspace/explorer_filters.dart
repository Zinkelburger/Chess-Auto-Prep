import 'package:flutter/material.dart';

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
    final narrowable = choice.source != ExplorerSource.masters;
    final unfolded = narrowable && _unfolded;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.m, Space.xs, Space.s, 0),
          child: Row(
            children: [
              SegmentedButton<ExplorerSource>(
                segments: [
                  for (final source in _explorer.sources)
                    ButtonSegment(value: source, label: Text(source.title)),
                ],
                selected: {choice.source},
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                onSelectionChanged: (picked) =>
                    _explorer.choose(choice.copyWith(source: picked.single)),
              ),
              const Spacer(),
              if (narrowable)
                Flexible(
                  child: TextButton(
                    onPressed: () => setState(() => _unfolded = !_unfolded),
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
              ExplorerSource.masters => const SizedBox.shrink(),
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
