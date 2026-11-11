import 'package:flutter/material.dart';

import '../../ui/app_icons.dart';
import '../../ui/app_keys.dart';
import '../../ui/theme.dart';
import '../../ui/tool_button.dart';
import '../document/document_session.dart';

/// The four buttons under the moves that walk the line: start, back,
/// forward, end. Each says its key, because each has one.
class NavRow extends StatelessWidget {
  const NavRow({super.key, required this.session, this.book, this.leading});

  final DocumentSession session;

  /// Before the buttons, at the row's start: `Read | Edit`, where the mode
  /// has one.
  final Widget? leading;

  /// Whether the opening book shows under the moves; its button leads the
  /// row, as Lichess's does, where the layout offers it.
  final ValueNotifier<bool>? book;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: navRowHeight,
      child: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final open = session.chapter != null;
          final buttons = Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (book case final book?)
                ValueListenableBuilder<bool>(
                  valueListenable: book,
                  builder: (context, open, _) => ToolButton(
                    icon: open ? AppIcons.bookOpen : AppIcons.book,
                    tooltip: open
                        ? 'Hide the opening book'
                        : 'Show the opening book under the moves',
                    selected: open,
                    onPressed: () => book.value = !open,
                  ),
                ),
              _button(
                AppIcons.first,
                AppKey.start.tip('Start'),
                open,
                session.cursor.toStart,
              ),
              _button(
                AppIcons.previous,
                AppKey.back.tip('Back'),
                open,
                session.cursor.back,
              ),
              _button(
                AppIcons.next,
                AppKey.forward.tip('Forward'),
                open,
                session.cursor.forward,
              ),
              _button(
                AppIcons.last,
                AppKey.end.tip('End'),
                open,
                session.cursor.toEnd,
              ),
            ],
          );
          final leading = this.leading;
          if (leading == null) return buttons;
          return Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(left: Space.m),
                child: leading,
              ),
              Expanded(child: buttons),
            ],
          );
        },
      ),
    );
  }

  Widget _button(IconData icon, String tooltip, bool on, VoidCallback run) =>
      ToolButton(icon: icon, tooltip: tooltip, onPressed: on ? run : null);
}
