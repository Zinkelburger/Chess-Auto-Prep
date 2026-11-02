import 'package:flutter/material.dart';

import 'theme.dart';

/// Words in place of a list or a table, at its top left where the first
/// row would be: why it is empty or could not be read, and the one thing
/// that fixes it under them when there is one. While the list is read it
/// says so ([ListMessage.loading]: `Reading repertoires…`), not a spinner.
///
/// One sentence. An empty list's button names what it makes (`New
/// repertoire…`); a list that could not be read offers `Try again` and says
/// `Could not read …` without asking the player to try again.
///
/// [inset] is the gap to the edge: [Space.l] in a list column, [Space.m] in
/// a tool pane, none inside a list that is already inset.
class ListMessage extends StatelessWidget {
  const ListMessage(this.text, {super.key, this.action, this.inset = Space.l})
    : _live = false;

  /// What is being read, said while it is: `Reading puzzles…`.
  const ListMessage.loading(this.text, {super.key, this.inset = Space.l})
    : action = null,
      _live = true;

  final String text;
  final Widget? action;
  final double inset;
  final bool _live;

  @override
  Widget build(BuildContext context) {
    final words = Semantics(
      liveRegion: _live,
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
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
