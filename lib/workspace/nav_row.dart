import 'package:flutter/material.dart';

import '../ui/app_keys.dart';
import '../ui/theme.dart';
import 'document_session.dart';

/// The four buttons under the moves that walk the line: start, back,
/// forward, end. Each says its key, because each has one.
class NavRow extends StatelessWidget {
  const NavRow({super.key, required this.session, this.book});

  final DocumentSession session;

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
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (book case final book?)
                ValueListenableBuilder<bool>(
                  valueListenable: book,
                  builder: (context, open, _) => IconButton(
                    icon: Icon(
                      open ? Icons.menu_book : Icons.menu_book_outlined,
                      size: IconSize.action,
                    ),
                    tooltip: open
                        ? 'Hide the opening book'
                        : 'Show the opening book under the moves',
                    isSelected: open,
                    onPressed: () => book.value = !open,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              _button(
                Icons.first_page,
                AppKey.start.tip('Start'),
                open,
                session.cursor.toStart,
              ),
              _button(
                Icons.chevron_left,
                AppKey.back.tip('Back'),
                open,
                session.cursor.back,
              ),
              _button(
                Icons.chevron_right,
                AppKey.forward.tip('Forward'),
                open,
                session.cursor.forward,
              ),
              _button(
                Icons.last_page,
                AppKey.end.tip('End'),
                open,
                session.cursor.toEnd,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _button(IconData icon, String tooltip, bool on, VoidCallback run) =>
      IconButton(
        icon: Icon(icon, size: IconSize.action),
        tooltip: tooltip,
        onPressed: on ? run : null,
        visualDensity: VisualDensity.compact,
      );
}
