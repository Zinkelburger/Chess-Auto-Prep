import 'package:flutter/material.dart';

import '../diagnostics/log.dart';
import 'theme.dart';

/// A button beside the sentence in the [StatusBar]: the way out the sentence
/// names, such as Reload.
typedef StatusAction = ({String label, VoidCallback onPressed});

/// Puts a sentence in the [StatusBar]; [problem] false for one that reports
/// an outcome the user asked for.
typedef Say =
    void Function(String sentence, {StatusAction? action, bool problem});

/// The window's sentence about the last action, in the top bar's empty
/// middle: what the action could not do, in the error colour, or where the
/// result of one that worked went (a copy saved, chapters added to a
/// study) in the text colour, until the next thing said replaces it or the
/// user closes it. One line, its whole text on hover; it takes no room of
/// its own, so a sentence coming or going moves nothing on the page.
///
/// This is the app's one place for a sentence about an action. There are no
/// snackbars: they cover the board and stay up after the user has read them.
class StatusBar extends StatelessWidget {
  const StatusBar(
    this.text, {
    super.key,
    this.action,
    this.problem = true,
    required this.onClose,
  });

  final String text;
  final StatusAction? action;

  /// Whether [text] says what could not be done; false for an outcome the
  /// user asked for, which gets no alarm colour.
  final bool problem;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = problem ? scheme.error : scheme.onSurface;
    return Row(
      children: [
        Flexible(
          child: Tooltip(
            message: text,
            child: Semantics(
              liveRegion: true,
              child: Text(
                text,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: ink),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        if (action case final action?)
          TextButton(
            onPressed: () {
              onClose();
              action.onPressed();
            },
            child: Text(action.label),
          ),
        IconButton(
          onPressed: onClose,
          icon: Icon(
            Icons.close,
            size: IconSize.menu,
            color: scheme.onSurfaceVariant,
          ),
          tooltip: 'Close',
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

/// Where a list or panel below the window puts a sentence for the
/// [StatusBar]: the window supplies it once, above every mode.
class StatusScope extends InheritedWidget {
  const StatusScope({super.key, required this.say, required super.child});

  final Say say;

  /// The window's [say], taken now: a caller about to await takes it first,
  /// because the row that asked can be gone when the answer comes. Outside a
  /// window — a widget test of one panel — the sentence goes to the log.
  static Say of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<StatusScope>()?.say ??
      (sentence, {action, problem = true}) =>
          log.w('said with no window', sentence);

  @override
  bool updateShouldNotify(StatusScope oldWidget) => false;
}
