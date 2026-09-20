/// What a change to the catalog leaves in the log.
///
/// The sentences live apart from the owner that makes the changes: the log
/// is for whoever reads a user's report of "it did not work", and there is
/// one line here for each way a change can fail.
library;

import '../../diagnostics/log.dart';
import 'library_state.dart';

void reportLibraryResult(String action, LibraryResult result) {
  switch (result) {
    case LibraryDone() || LibraryBusy():
      return;
    case LibraryNameTaken():
      log.w(action, 'the name is taken');
    case LibraryStale() || LibraryConflicted():
      log.w(action, 'the file changed on disk');
    case LibraryFailure(:final detail):
      log.e(action, detail);
    case LibraryStoppedAt(:final chapter, :final cause):
      log.e(action, 'stopped at $chapter');
      reportLibraryResult('$action: $chapter', cause);
  }
}
