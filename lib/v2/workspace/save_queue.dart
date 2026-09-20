import '../storage/edit_scope.dart';

/// Words waiting for the disk and the games the edits that made them wrote.
typedef Draft = ({String text, EditScope scope});

/// The one draft waiting to be written, and what it is allowed to change.
///
/// Only one write goes out at a time, so edits made during one collapse into
/// a single draft of the newest words. The scope has to collapse with them:
/// the earlier edit is in those words too, and the store checks a save
/// against the file, not against the draft that never reached it.
final class SaveQueue {
  Draft? _waiting;

  bool get isEmpty => _waiting == null;

  /// Words the user has just typed. They are the newest there are, so they
  /// are what gets written, under a scope covering this edit and whatever
  /// was already waiting.
  void typed(String text, EditScope scope) {
    final waiting = _waiting;
    _waiting = (
      text: text,
      scope: waiting == null ? scope : scopeOfBoth(waiting.scope, scope),
    );
  }

  /// A draft the store did not take, coming back. Words typed while it was
  /// out are newer and win, and they take this draft's scope with them: the
  /// file still holds the version both of them were typed over.
  void returned(Draft draft) {
    final waiting = _waiting;
    _waiting = waiting == null
        ? draft
        : (text: waiting.text, scope: scopeOfBoth(waiting.scope, draft.scope));
  }

  /// The draft to write now, and the queue is empty again; null when nothing
  /// is waiting.
  Draft? take() {
    final waiting = _waiting;
    _waiting = null;
    return waiting;
  }

  /// Lets go of whatever is waiting: another document was opened, or nothing
  /// more will be written to this one until the user decides what to do.
  void clear() => _waiting = null;
}
