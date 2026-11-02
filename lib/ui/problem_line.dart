import 'package:flutter/material.dart';

import 'theme.dart';

/// What could not be done, in one fixed-height line in the error colour,
/// with the one thing that fixes it (usually `Try again` or `Retry save`)
/// at its end. Screen readers say it when it appears.
///
/// With no [text] it keeps its height empty, for a place where a problem
/// may come and go without moving what is under it.
class ProblemLine extends StatelessWidget {
  const ProblemLine(this.text, {super.key, this.action});

  final String? text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = this.text;
    return SizedBox(
      height: problemLineHeight,
      child: text == null
          ? null
          : Semantics(
              liveRegion: true,
              child: Row(
                children: [
                  Expanded(
                    child: Tooltip(
                      message: text,
                      child: Text(
                        text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ),
                  if (action case final action?) ...[
                    const SizedBox(width: Space.s),
                    action,
                  ],
                ],
              ),
            ),
    );
  }
}
