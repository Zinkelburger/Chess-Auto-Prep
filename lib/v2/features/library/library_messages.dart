import 'dart:async';

import 'package:flutter/material.dart';

import '../../storage/training_records.dart' as records;
import '../../workspace/session_results.dart';
import 'library_state.dart';

/// What to tell the user about [result], or null when the change did what it
/// said and there is nothing to add.
///
/// [thing] is what changed, `repertoire` or `chapter`; [name] is what it is
/// called; [failed] is the sentence for a failure the user can do nothing
/// about, which the caller writes because only it knows what was attempted.
String? libraryMessage(
  LibraryResult result, {
  required String thing,
  required String name,
  required String failed,
}) => switch (result) {
  LibraryDone(:final training) => _stillPointingAtTheOldName(training),
  LibraryAdded() => null,
  LibraryNothingToImport() => 'That PGN has no moves to train.',
  LibraryFileUnreadable() => 'Could not read that file.',
  LibraryNameTaken() => 'A $thing named "$name" already exists.',
  LibraryStale() =>
    'That $thing changed on disk. The list has been refreshed; try again.',
  LibraryConflicted() =>
    'That $thing changed on disk while it was open. Reload it to take the '
        'version on disk, then try again.',
  LibraryBusy() => 'Another change is still running.',
  LibraryFailure() => failed,
  LibraryStoppedAt(:final chapter) => '$failed It stopped at "$chapter".',
};

/// The file moved but its training rows did not, which is worth saying: the
/// schedule and history are still there, under the name the chapter left.
String? _stillPointingAtTheOldName(records.RepointResult result) =>
    switch (result) {
      records.Repointed() || records.NothingToRepoint() => null,
      records.Malformed(:final file, :final line) =>
        'Your training records still point at the old name: $file could not '
            'be read at line $line.',
      records.IoFailure() =>
        'Your training records still point at the old name.',
    };

/// Runs [command] and says what became of it, when there is anything to say.
///
/// The messenger is taken before the await: the row that asked for the change
/// is rebuilt by the refresh that follows it, and a widget that is gone
/// cannot be asked for its scaffold.
///
/// [reload] is offered beside the sentence when the change refused because
/// the open chapter changed on disk, because telling the user to reload
/// without giving them the button is telling them to go and find it.
Future<LibraryResult> announce(
  BuildContext context,
  Future<LibraryResult> command, {
  required String thing,
  required String name,
  required String failed,
  Future<OpenResult> Function()? reload,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final result = await command;
  final message = libraryMessage(
    result,
    thing: thing,
    name: name,
    failed: failed,
  );
  if (message == null) return result;
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      action: result is LibraryConflicted && reload != null
          ? SnackBarAction(
              label: 'Reload',
              onPressed: () => unawaited(_reloaded(messenger, reload)),
            )
          : null,
    ),
  );
  return result;
}

/// Runs [reload] and says why when the chapter could not be read again: a
/// Reload that fails without a word looks like one that was never pressed.
Future<void> _reloaded(
  ScaffoldMessengerState messenger,
  Future<OpenResult> Function() reload,
) async {
  final result = await reload();
  if (result case OpenFailed(:final reason) when messenger.mounted) {
    messenger.showSnackBar(SnackBar(content: Text(reason)));
  }
}
