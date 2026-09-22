import 'dart:async';

import 'package:flutter/material.dart';

import 'document_session.dart';
import 'save_state.dart';

/// How long a deletion's notice stays, with the way back on it. The delete
/// itself asks nothing first: undo is the answer, so the offer has to
/// outlast the surprise.
const undoOffer = Duration(seconds: 8);

/// Says what was deleted and offers the way back.
///
/// Undo steps the document back one version, so the offer only stands while
/// that version is still the deletion. The next edit — a move played, a note
/// typed, another line deleted — takes the notice away, because pressing it
/// then would take *that* back and leave the deletion where it is.
void showDeletionNotice(
  BuildContext context,
  DocumentSession session,
  String message,
) {
  final messenger = ScaffoldMessenger.of(context);
  final deleted = session.chapter;
  final notice = messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: undoOffer,
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => unawaited(_undo(messenger, session)),
      ),
    ),
  );
  // One subscription, gone when the notice goes, whatever took it away.
  // The first edit takes it away, and only once: closing a notice twice
  // would close whichever one came up after it.
  void whenEdited() {
    if (identical(session.chapter, deleted)) return;
    session.removeListener(whenEdited);
    notice.close();
  }

  session.addListener(whenEdited);
  unawaited(notice.closed.then((_) => session.removeListener(whenEdited)));
}

/// Takes the deletion back, and says so when it could not: an undo that does
/// nothing quietly reads as a lost click.
Future<void> _undo(ScaffoldMessengerState messenger, DocumentSession session) {
  return session.undo().then((result) {
    if (result case UndoRefused(:final reason)) {
      messenger.showSnackBar(
        SnackBar(content: Text(reason ?? 'There is nothing to undo.')),
      );
    }
  });
}
