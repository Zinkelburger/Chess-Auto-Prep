import 'package:flutter/material.dart';

import '../diagnostics/log.dart';
import 'theme.dart';

/// A button beside the sentence in the [ErrorBar]: the way out the sentence
/// names, such as Reload.
typedef StatusAction = ({String label, VoidCallback onPressed});

/// One line across the window under the top bar, in the error colour: what
/// the last action could not do, until the next thing said replaces it or
/// the user closes it.
///
/// This is the app's one place for a sentence about an action. There are no
/// snackbars: they cover the board and stay up after the user has read them.
class ErrorBar extends StatelessWidget {
  const ErrorBar(this.text, {super.key, this.action, required this.onClose});

  final String text;
  final StatusAction? action;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = scheme.onErrorContainer;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.only(left: Space.l, right: Space.s),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.s),
              child: Text(text, style: TextStyle(color: ink)),
            ),
          ),
          if (action case final action?)
            TextButton(
              onPressed: () {
                onClose();
                action.onPressed();
              },
              style: TextButton.styleFrom(foregroundColor: ink),
              child: Text(action.label),
            ),
          IconButton(
            onPressed: onClose,
            icon: Icon(Icons.close, size: IconSize.action, color: ink),
            tooltip: 'Close',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

/// Where a list or panel below the window puts a sentence for the
/// [ErrorBar]: the window supplies it once, above every mode.
class StatusScope extends InheritedWidget {
  const StatusScope({super.key, required this.say, required super.child});

  final void Function(String sentence, {StatusAction? action}) say;

  /// The window's [say], taken now: a caller about to await takes it first,
  /// because the row that asked can be gone when the answer comes. Outside a
  /// window — a widget test of one panel — the sentence goes to the log.
  static void Function(String sentence, {StatusAction? action}) of(
    BuildContext context,
  ) =>
      context.getInheritedWidgetOfExactType<StatusScope>()?.say ??
      (sentence, {action}) => log.w('said with no window', sentence);

  @override
  bool updateShouldNotify(StatusScope oldWidget) => false;
}
