import 'package:flutter/material.dart';

import '../../storage/training_records.dart' as records;
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
  LibraryNameTaken() => 'A $thing named "$name" already exists.',
  LibraryStale() =>
    'That $thing changed on disk. The list has been refreshed; try again.',
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
Future<void> announce(
  BuildContext context,
  Future<LibraryResult> command, {
  required String thing,
  required String name,
  required String failed,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final message = libraryMessage(
    await command,
    thing: thing,
    name: name,
    failed: failed,
  );
  if (message == null) return;
  messenger.showSnackBar(SnackBar(content: Text(message)));
}
