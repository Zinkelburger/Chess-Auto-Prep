import 'package:flutter/material.dart';

import 'theme.dart';

/// The top row of a list column or pane: its name in the label style, the
/// few controls that act on the whole list, and the host's control (the
/// `«` that hides the column) in the corner.
///
/// One shape for every column, so a name and its controls are always in
/// the same place whatever mode is open.
class PaneHeader extends StatelessWidget {
  const PaneHeader(
    this.title, {
    super.key,
    this.leading,
    this.actions = const [],
    this.trailing,
  });

  final String title;

  /// Before the name: the way back to the list this one was opened from.
  final Widget? leading;

  /// After the name, at the end of the row.
  final List<Widget> actions;

  /// In the corner, after [actions].
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      leading == null ? Space.m : 0,
      Space.s,
      Space.s,
      0,
    ),
    child: Row(
      children: [
        ?leading,
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.labelSmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        ...actions,
        ?trailing,
      ],
    ),
  );
}

/// A heading inside a list: `Recent files`, a repertoire's name over its
/// deleted chapters. The label style, lined up with the rows under it.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Space.m, Space.m, Space.m, Space.xs),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelSmall,
      overflow: TextOverflow.ellipsis,
    ),
  );
}

/// How many a list holds, or how many of how many pass its filters
/// (`12 of 340`), on one line over the rows, with the one control that
/// changes it (the way to the filters) at its end.
class CountLine extends StatelessWidget {
  const CountLine(this.words, {super.key, this.action});

  final String words;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      Space.m,
      Space.xs,
      action == null ? Space.m : Space.xs,
      Space.xs,
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            words,
            style: Theme.of(context).textTheme.labelSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        ?action,
      ],
    ),
  );
}
