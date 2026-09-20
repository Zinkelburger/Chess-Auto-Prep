import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import '../workspace/document_saver.dart';
import '../workspace/save_state.dart';

/// What the user said about words that are not on disk.
enum DraftChoice {
  /// Leave the window open until they are.
  keepWaiting,

  /// Close now, knowing the words typed since the last save are lost.
  closeAnyway,
}

/// Where the question about unsaved words is put to the user.
abstract interface class DraftQuestion {
  /// Asks, with [trouble] saying what is known about the file, and answers
  /// what the user chose — null when they answered nothing.
  Future<DraftChoice?> put(String trouble);

  /// Takes the question down; it no longer needs an answer.
  void withdraw();
}

/// Decides whether the window may close while the file is behind the screen.
///
/// The wait is bounded. A save can be queued behind the other copy of the
/// app, which holds the folder for up to two minutes before giving up, and a
/// save that was refused or failed is not going to land at all; waiting on
/// any of them without a bound is a window that ignores its own close button
/// and has to be killed. So the words get [wait], and after that the user is
/// told what is known and answers. Nothing is thrown away without being
/// asked, and an answer that never comes leaves the window open, which is
/// the outcome that loses nothing.
final class ExitGuard {
  ExitGuard({
    required DocumentSaver saver,
    required DraftQuestion question,
    this.wait = const Duration(seconds: 5),
  }) : _saver = saver,
       _question = question;

  final DocumentSaver _saver;
  final DraftQuestion _question;

  /// How long the file is given before the user is asked about it.
  final Duration wait;

  Future<bool>? _deciding;

  /// Whether the window may close now.
  ///
  /// Asked again while the first answer is still being worked out — a second
  /// click on the close button, or one made while the question is up — every
  /// caller gets that one answer rather than a second dialog and a second
  /// way out.
  Future<bool> mayClose() =>
      _deciding ??= _decide().whenComplete(() => _deciding = null);

  Future<bool> _decide() async {
    final settling = _settle();
    if (await Future.any([settling, _clock()])) return true;
    log.w('close the window', '${_saver.documentPath} is not saved yet');
    return _answered(settling);
  }

  /// False when [wait] runs out. Losing that race is an outcome, not a
  /// failure: the write may still land, and the user is the one who decides
  /// what to do about it.
  Future<bool> _clock() => Future<bool>.delayed(wait, () => false);

  /// Waits for the file to catch up with the screen, and answers whether it
  /// did. Flushing only says that nothing is on its way; the saver says
  /// whether anything arrived.
  Future<bool> _settle() async {
    try {
      await _saver.flush();
    } on Object catch (error) {
      // The saver turns a store that throws into a failed save, so anything
      // arriving here is a failure nobody planned for at all.
      log.e('save ${_saver.documentPath} before the window closes', error);
      return false;
    }
    return _saver.settled;
  }

  Future<bool> _answered(Future<bool> settling) async {
    final saved = Completer<_Answer>();
    // _settle never fails, so this only ever completes with an answer.
    unawaited(
      settling.then((landed) {
        if (landed && !saved.isCompleted) saved.complete(_Answer.saved);
      }),
    );
    final asked = _question
        .put(_trouble())
        .then((choice) => _answerFor(choice));
    switch (await Future.any([asked, saved.future])) {
      case _Answer.saved:
        // The file caught up while the question was on screen, so there is
        // nothing left to ask about.
        _question.withdraw();
        return true;
      case _Answer.close:
        log.w('close the window with unsaved words', _saver.documentPath);
        return true;
      case _Answer.stay:
        return false;
    }
  }

  _Answer _answerFor(DraftChoice? choice) =>
      choice == DraftChoice.closeAnyway ? _Answer.close : _Answer.stay;

  /// What is known about why the file is behind, as a sentence. Only what is
  /// known: a save that has not finished may be waiting for anything.
  String _trouble() {
    final path = _saver.documentPath;
    final file = path == null ? 'your chapter' : p.basename(path);
    return switch (_saver.state) {
      SaveFailed(:final detail) =>
        'The last save of $file did not go through: $detail.',
      SaveConflict() =>
        '$file was changed somewhere else, so your version of it has not '
            'been saved.',
      _ =>
        'The save of $file has not finished after ${wait.inSeconds} '
            'seconds.',
    };
  }
}

/// Which of the two things being waited for happened first.
enum _Answer { saved, close, stay }

/// The question as a dialog over the app.
final class DraftDialog implements DraftQuestion {
  DraftDialog(this._navigator);

  final GlobalKey<NavigatorState> _navigator;
  bool _open = false;

  @override
  Future<DraftChoice?> put(String trouble) async {
    final context = _navigator.currentContext;
    if (context == null) {
      // No window, so nobody to ask. The words stay where they are and the
      // close button can be pressed again.
      log.e('ask about the unsaved words', 'the window is not on screen');
      return null;
    }
    _open = true;
    try {
      return await showDialog<DraftChoice>(
        context: context,
        builder: (context) => _UnsavedWordsDialog(trouble),
      );
    } finally {
      _open = false;
    }
  }

  @override
  void withdraw() {
    if (_open) _navigator.currentState?.pop();
  }
}

/// Escape and a click outside leave the window open with the save still
/// going, which is the answer that loses nothing.
class _UnsavedWordsDialog extends StatelessWidget {
  const _UnsavedWordsDialog(this.trouble);

  /// What is known about the file, in plain words.
  final String trouble;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Not saved yet'),
    content: Text(
      '$trouble\n\nYou can leave the window open until it is saved, or '
      'close now and lose what you typed since the last save.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(DraftChoice.closeAnyway),
        child: const Text('Close and lose changes'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(DraftChoice.keepWaiting),
        child: const Text('Leave it open'),
      ),
    ],
  );
}
