import 'dart:async';

import 'package:flutter/material.dart';

import '../diagnostics/log.dart';

/// What the user said about a draft that is not reaching the disk.
enum DraftChoice {
  /// Give the save more time; the window stays open.
  keepWaiting,

  /// Close now, knowing the words typed since the last save are lost.
  closeAnyway,
}

/// Decides whether the window may close while a draft is still on its way to
/// the file.
///
/// The wait is bounded. Another copy of the app can hold the repertoires
/// folder, and a save that waits for a lock it will not get waits for ever;
/// waiting on it unbounded is a window that ignores its own close button and
/// has to be killed. So the draft is given [wait], and after that the user is
/// asked and answers: keep waiting, or close and lose it. Nothing is thrown
/// away without being asked, and an answer that never comes keeps the window
/// open, which is the outcome that loses nothing.
final class ExitGuard {
  ExitGuard({
    required Future<void> Function() flush,
    required Future<DraftChoice?> Function() ask,
    this.wait = const Duration(seconds: 5),
  }) : _flush = flush,
       _ask = ask;

  final Future<void> Function() _flush;
  final Future<DraftChoice?> Function() _ask;

  /// How long the draft is given before the user is asked about it.
  final Duration wait;

  /// Whether the window may close now.
  Future<bool> mayClose() async {
    while (true) {
      if (await _landed()) return true;
      switch (await _ask()) {
        case DraftChoice.closeAnyway:
          log.w('close the window', 'a draft never reached the file');
          return true;
        case DraftChoice.keepWaiting:
          continue;
        case null:
          return false;
      }
    }
  }

  Future<bool> _landed() async {
    try {
      await _flush().timeout(wait);
      return true;
    } on Object catch (error) {
      log.e('save the draft before the window closes', error);
      return false;
    }
  }
}

/// Tells the user in plain words why the window did not close, and takes
/// their answer. Escape and a click outside keep the window open with the
/// save still going, which is the answer that loses nothing.
Future<DraftChoice?> askAboutUnsavedDraft(BuildContext context) =>
    showDialog<DraftChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Still saving'),
        content: const Text(
          'Your last changes have not reached the file yet. This usually '
          'means another copy of Chess Auto Prep is using your repertoires '
          'folder. Keep waiting and they will be saved as soon as it lets '
          'go, or close now and lose what you typed since the last save.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(DraftChoice.closeAnyway),
            child: const Text('Close and lose changes'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(DraftChoice.keepWaiting),
            child: const Text('Keep waiting'),
          ),
        ],
      ),
    );
