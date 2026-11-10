import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import '../document/document_session.dart';
import 'comment_field.dart';

/// The Notes tab: the note on the move under the cursor — the chapter's
/// introduction at the start — with the whole pane to write in, as a page
/// rather than a line. It is the same note the moves show under the move,
/// so what is written here is read there, laid out. Nothing shows while
/// part of the game is hidden: a note is often the answer.
class NotesPane extends StatelessWidget {
  const NotesPane({super.key, required this.session});

  final DocumentSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => session.shownTo != null
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.all(Space.m),
            child: CommentField(session: session, fill: true),
          ),
  );
}
