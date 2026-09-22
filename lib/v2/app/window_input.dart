import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../diagnostics/log.dart';
import '../workspace/side_dialog.dart';

/// What the workspace's requests read from the person at the window: the
/// answer to a question, or the text they copied. An interface because it
/// is the edge between the owner and the screen, so the requests can be
/// tested with scripted answers.
abstract interface class WindowInput {
  /// Which side the chapter called [chapter] is for; null when the user
  /// dismissed the question.
  Future<Side?> sideFor(String chapter);

  /// The text on the clipboard; null when there is none.
  Future<String?> clipboard();
}

/// The questions as dialogs over the app, and the system clipboard.
final class DialogInput implements WindowInput {
  DialogInput(this._navigator);

  final GlobalKey<NavigatorState> _navigator;

  @override
  Future<Side?> sideFor(String chapter) async {
    final context = _navigator.currentContext;
    if (context == null) {
      // No window, so nobody to ask; the chapter is asked about the next
      // time it opens.
      log.w('ask which side $chapter is for', 'the window is not on screen');
      return null;
    }
    return showSideDialog(context, chapter: chapter);
  }

  @override
  Future<String?> clipboard() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;
}
