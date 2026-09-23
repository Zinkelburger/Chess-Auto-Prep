import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/log.dart';
import '../workspace/document_saver.dart';

/// What the user said about words that are not on disk.
enum DraftChoice {
  /// Stay where they are until the file catches up.
  keepWaiting,

  /// Write them somewhere else first.
  saveACopy,

  /// Go now, knowing the words typed since the last save are lost.
  closeAnyway,
}

/// The question as the user sees it: what is known about the file, and what
/// the button that goes anyway says.
typedef DraftPrompt = ({String body, String leave, bool offerCopy});

/// Where the question about unsaved words is put to the user.
abstract interface class DraftQuestion {
  /// Asks [prompt] and answers what the user chose — null when they
  /// answered nothing.
  Future<DraftChoice?> put(DraftPrompt prompt);

  /// Takes the question down; it no longer needs an answer.
  void withdraw();
}

/// Whether the workspace may go where it was asked to.
sealed class LeaveAnswer {
  const LeaveAnswer();
}

/// Stay where it is: the user chose to, or a copy they asked for was not
/// written.
final class Stay extends LeaveAnswer {
  const Stay();
}

/// Go on. [copy] names the file the words were written to first when the
/// user answered by saving a copy, for the screen to say so once it has
/// gone where it was going; null when nothing had to be kept elsewhere.
final class Go extends LeaveAnswer {
  const Go({this.copy});

  final String? copy;
}

/// What the user is walking away from.
enum _Away {
  window('close the window', 'Close and lose the words'),
  document('leave this document', 'Leave and lose the words');

  const _Away(this.action, this.button);

  /// For the log.
  final String action;

  final String button;
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
    Future<String?> Function()? saveCopy,
    this.wait = const Duration(seconds: 5),
  }) : _saver = saver,
       _question = question,
       _saveCopy = saveCopy;

  final DocumentSaver _saver;
  final DraftQuestion _question;

  /// Writes the words somewhere else and answers the file it wrote, or null
  /// when it wrote none. Null itself when this guard has nowhere to write
  /// them, and then the question does not offer it.
  final Future<String?> Function()? _saveCopy;

  /// How long the file is given before the user is asked about it.
  final Duration wait;

  /// One decision at a time per kind. Sharing one across both would let the
  /// answer to a question about leaving the document grant a close nobody
  /// asked about.
  final _deciding = <_Away, Future<LeaveAnswer>>{};

  /// Whether the window may close now.
  ///
  /// Asked again while the first answer is still being worked out — a second
  /// click on the close button, or one made while the question is up — every
  /// caller gets that one answer rather than a second dialog and a second
  /// way out.
  Future<bool> mayClose() async => await _mayGo(_Away.window) is Go;

  /// Whether the workspace may put another document on the screen now.
  ///
  /// Opening one takes the saver off this file, and a draft it never wrote
  /// goes with it. The same question, the same three answers: it is the
  /// document being left rather than the window, and that is the whole
  /// difference. Callers asking while one answer is being worked out share
  /// it, copy and all.
  Future<LeaveAnswer> mayLeaveDocument() => _mayGo(_Away.document);

  Future<LeaveAnswer> _mayGo(_Away kind) {
    final asked = _deciding[kind];
    if (asked != null) return asked;
    // A question already on screen is answered first: two at once, and the
    // button pressed on one would decide the other.
    final decided = _afterTheOthers(kind);
    _deciding[kind] = decided;
    return decided.whenComplete(() => _deciding.remove(kind));
  }

  Future<LeaveAnswer> _afterTheOthers(_Away kind) async {
    for (final other in [..._deciding.values]) {
      await other;
    }
    return _decide(kind);
  }

  Future<LeaveAnswer> _decide(_Away kind) async {
    // Nothing to wait for and nothing to ask about, so no clock is started:
    // a timer left running is a timer a widget test waits on for nothing.
    if (_saver.settled) return const Go();
    final settling = _settle();
    if (await Future.any([settling, _clock()])) return const Go();
    log.w(kind.action, '${_saver.documentPath} is not saved yet');
    return _answered(settling, kind);
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

  Future<LeaveAnswer> _answered(Future<bool> settling, _Away kind) async {
    final saved = Completer<_Answer>();
    // _settle never fails, so this only ever completes with an answer.
    unawaited(
      settling.then((landed) {
        if (landed && !saved.isCompleted) saved.complete(_Answer.saved);
      }),
    );
    final asked = _question
        .put((
          body: _body(kind),
          leave: kind.button,
          offerCopy: _saveCopy != null,
        ))
        .then((choice) => _answerFor(choice));
    switch (await Future.any([asked, saved.future])) {
      case _Answer.saved:
        // The file caught up while the question was on screen, so there is
        // nothing left to ask about.
        _question.withdraw();
        return const Go();
      case _Answer.copy:
        return _copied();
      case _Answer.close:
        log.w('${kind.action} with unsaved words', _saver.documentPath);
        return const Go();
      case _Answer.stay:
        return const Stay();
    }
  }

  /// Writes the words beside the original and goes on when they are there.
  /// A copy nobody wrote leaves the user where they were.
  Future<LeaveAnswer> _copied() async {
    final copy = _saveCopy;
    if (copy == null) return const Stay();
    final written = await copy();
    return written == null ? const Stay() : Go(copy: written);
  }

  _Answer _answerFor(DraftChoice? choice) => switch (choice) {
    DraftChoice.closeAnyway => _Answer.close,
    DraftChoice.saveACopy => _Answer.copy,
    DraftChoice.keepWaiting || null => _Answer.stay,
  };

  /// What is known about why the file is behind and what the answers mean.
  String _body(_Away kind) => '${_trouble()}\n\n${_ways(kind)}';

  /// What waiting, copying and going will do.
  ///
  /// Waiting is worth naming only when the saver is still writing this
  /// document. It is the saver that says so, not the name of the state: a
  /// conflicted file and a frozen one both take no more words, and telling
  /// the user to wait for a save that is never coming is telling them to
  /// wait for ever.
  String _ways(_Away kind) {
    final going = kind == _Away.window ? 'Closing now' : 'Leaving now';
    if (_saver.takesWords) {
      return 'You can stay until it is saved, or save a copy. $going loses '
          'what you typed since the last save.';
    }
    return '${_whyNoMore()} Save a copy to keep the words. $going loses them.';
  }

  /// Why nothing more is going to be written, as the user would say it.
  String _whyNoMore() => switch (_saver.state) {
    SaveConflict() =>
      'Nothing more will be written until you reload or save a copy.',
    _ => 'Nothing more will be written to that file, so waiting will not help.',
  };

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
      SaveStopped() =>
        'The last save of $file was stopped because the app would have '
            'changed a line you did not edit. Your words are still on '
            'screen.',
      _ =>
        'The save of $file has not finished after ${wait.inSeconds} '
            'seconds.',
    };
  }
}

/// Which of the things being waited for happened first.
enum _Answer { saved, copy, close, stay }

/// The question as a dialog over the app.
final class DraftDialog implements DraftQuestion {
  DraftDialog(this._navigator);

  final GlobalKey<NavigatorState> _navigator;
  bool _open = false;

  @override
  Future<DraftChoice?> put(DraftPrompt prompt) async {
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
        builder: (context) => _UnsavedWordsDialog(prompt),
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
  const _UnsavedWordsDialog(this.prompt);

  final DraftPrompt prompt;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Not saved yet'),
    content: Text(prompt.body),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(DraftChoice.closeAnyway),
        child: Text(prompt.leave),
      ),
      if (prompt.offerCopy)
        TextButton(
          onPressed: () => Navigator.of(context).pop(DraftChoice.saveACopy),
          child: const Text('Save a copy…'),
        ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(DraftChoice.keepWaiting),
        child: const Text('Stay here'),
      ),
    ],
  );
}
