import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'document_session.dart';

/// The four buttons under the moves that walk the line: start, back,
/// forward, end. Each says its key, because each has one.
class NavRow extends StatelessWidget {
  const NavRow({super.key, required this.session});

  final DocumentSession session;

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
              _button(Icons.first_page, 'Start (Home)', open, session.toStart),
              _button(Icons.chevron_left, 'Back (←)', open, session.back),
              _button(
                Icons.chevron_right,
                'Forward (→)',
                open,
                session.forward,
              ),
              _button(Icons.last_page, 'End (End)', open, session.toEnd),
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
