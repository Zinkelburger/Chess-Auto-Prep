import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'explorer.dart';

/// The gear at the tab strip's edge: the one control the Explorer tab owns.
/// It opens the menu of databases and their chips.
class ExplorerGear extends StatelessWidget {
  const ExplorerGear({super.key, required this.explorer});

  final Explorer explorer;

  @override
  Widget build(BuildContext context) {
    return ExplorerMenu(
      explorer: explorer,
      builder: (context, controller) => IconButton(
        icon: const Icon(Icons.tune, size: IconSize.action),
        tooltip: 'Choose the database',
        onPressed: controller.isOpen ? controller.close : controller.open,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

/// The menu behind the gear and behind the summary line: the databases,
/// one ticked, and under the chosen one its chips. Choosing a database
/// closes the menu; a chip does not, so several can be set in one visit.
class ExplorerMenu extends StatelessWidget {
  const ExplorerMenu({
    super.key,
    required this.explorer,
    required this.builder,
  });

  final Explorer explorer;
  final Widget Function(BuildContext, MenuController) builder;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: explorer,
      builder: (context, _) => MenuAnchor(
        menuChildren: _items(context),
        builder: (context, controller, _) => builder(context, controller),
      ),
    );
  }

  List<Widget> _items(BuildContext context) {
    final choice = explorer.choice;
    return [
      for (final source in explorer.sources)
        MenuItemButton(
          leadingIcon: source == choice.source
              ? const Icon(Icons.check, size: IconSize.menu)
              : const SizedBox(width: IconSize.menu),
          onPressed: () => explorer.choose(choice.copyWith(source: source)),
          child: Text(source.title),
        ),
      if (choice.source == ExplorerSource.lichess) ...[
        const Divider(height: 1),
        _LichessChips(explorer: explorer),
      ],
      if (choice.source == ExplorerSource.twic) ...[
        const Divider(height: 1),
        CheckboxMenuButton(
          value: choice.classicalOnly,
          closeOnActivate: false,
          onChanged: (on) =>
              explorer.choose(choice.copyWith(classicalOnly: on ?? false)),
          child: const Text('Classical OTB only'),
        ),
      ],
    ];
  }
}

/// The speeds and the rating bands the Lichess database is narrowed by.
/// The last chip of a row cannot be turned off: a request for no speed or
/// no rating is one Lichess answers with nothing.
class _LichessChips extends StatelessWidget {
  const _LichessChips({required this.explorer});

  final Explorer explorer;

  @override
  Widget build(BuildContext context) {
    final choice = explorer.choice;
    final label = Theme.of(context).textTheme.labelSmall;
    return Padding(
      padding: const EdgeInsets.all(Space.m),
      child: SizedBox(
        width: explorerMenuWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Speed', style: label),
            const SizedBox(height: Space.xs),
            Wrap(
              spacing: Space.xs,
              runSpacing: Space.xs,
              children: [
                for (final speed in LichessSpeed.values)
                  FilterChip(
                    label: Text(speed.name),
                    selected: choice.speeds.contains(speed),
                    visualDensity: VisualDensity.compact,
                    onSelected: (on) => _speed(choice, speed, on),
                  ),
              ],
            ),
            const SizedBox(height: Space.s),
            Text('Rating', style: label),
            const SizedBox(height: Space.xs),
            Wrap(
              spacing: Space.xs,
              runSpacing: Space.xs,
              children: [
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
        ),
      ),
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
