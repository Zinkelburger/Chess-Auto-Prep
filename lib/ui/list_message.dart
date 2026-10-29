import 'package:flutter/material.dart';

import 'theme.dart';

/// Words in place of a list or a table: why it is empty or could not be
/// read, and the one thing that fixes it under them when there is one.
///
/// [inset] is the gap to the edge: [Space.l] in a list column, [Space.m] in
/// a tool pane, none inside a list that is already inset.
class ListMessage extends StatelessWidget {
  const ListMessage(this.text, {super.key, this.action, this.inset = Space.l});

  final String text;
  final Widget? action;
  final double inset;

  @override
  Widget build(BuildContext context) {
    final words = Text(text, style: Theme.of(context).textTheme.bodySmall);
    return Padding(
      padding: EdgeInsets.all(inset),
      child: switch (action) {
        null => words,
        final action => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            words,
            const SizedBox(height: Space.s),
            action,
          ],
        ),
      },
    );
  }
}
