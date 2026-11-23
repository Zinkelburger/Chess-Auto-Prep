part of 'document_session.dart';

/// Reads another document in for a [DocumentSession]: which request is the
/// newest, the saver's handover from the file up to the one arriving, and
/// the read itself. The session puts up what this hands it.
final class _DocumentReads {
  _DocumentReads(this._session);

  final DocumentSession _session;
  final parsed = ParsedFiles();
  final _opens = Latest();

  /// Pending navigation ticket. Undo waits so it cannot restore a previous
  /// file's contents under the arriving file's identity.
  Ticket? pending;

  Ticket get now => _opens.now;
  Ticket begin() => _opens.begin();

  /// Overtakes whatever is being read; the request up stays pending.
  void drop() => _opens.cancel();
  void close() => _opens.close();

  /// A newer navigation intent supersedes a read even if it stays here.
  void cancel() {
    _opens.cancel();
    pending = null;
  }

  /// Reads [ref] in and puts it up, unless a newer request overtakes it.
  Future<OpenResult> read(ChapterRef ref, int? game) {
    final ticket = _opens.begin();
    return switching(ticket, () => _opened(ref, game, ticket));
  }

  /// Runs [change], which puts another document up, with undo held off
  /// until it is over.
  Future<T> switching<T>(Ticket ticket, Future<T> Function() change) async {
    pending = ticket;
    try {
      return await change();
    } finally {
      if (pending == ticket) pending = null;
    }
  }

  Future<OpenResult> _opened(ChapterRef ref, int? game, Ticket ticket) async {
    // A rename, move or delete of this document may still be running, with a
    // draft behind it that belongs to the file it was typed into: it goes out
    // before this document takes the saver over, and before the read below,
    // which must not answer with text older than that write.
    await _session._saver.flush();
    if (ticket.overtaken) return const OpenOvertaken();
    await _session.access.settled(ref.path);
    if (ticket.overtaken) return const OpenOvertaken();
    final version = _session.access.versionOf(ref.path);
    final receipt = _session._saver.lastReceipt;
    final (leftAsIs, drafts) = (
      !_session._saver.settled,
      _session._saver.drafts,
    );
    final read = await readDocument(
      _session._store,
      ref,
      game: game,
      parsed: parsed,
    );
    if (ticket.overtaken) return const OpenOvertaken();
    if (_session.access.versionOf(ref.path) != version) {
      return _opened(ref, game, ticket);
    }
    final DocumentShown shown;
    switch (read) {
      case DocumentUnread(:final reason):
        log.w('open ${ref.path}', reason);
        return OpenFailed(reason);
      case DocumentShown():
        shown = read;
    }
    _session._editors.commit();
    if ((!leftAsIs || _session._saver.drafts != drafts) &&
        !_session._saver.settled) {
      // Words typed during the read, a Save among them, go to their file
      // before the handover. If the file will not take them, it stays up.
      final into = _session._saver.documentPath;
      await _session._saver.flush();
      if (ticket.overtaken || !_session._saver.settled) {
        return const OpenOvertaken();
      }
      // A flush to the file being opened supersedes the read.
      if (into == ref.path) return _opened(ref, game, ticket);
    }
    // A same-file autosave may already have settled while the read was out.
    if (_session.access.versionOf(ref.path) != version ||
        (_session._saver.documentPath == ref.path &&
            _session._saver.lastReceipt != receipt)) {
      return _opened(ref, game, ticket);
    }
    _session._show(
      shown.chapter,
      ref,
      shown.revision,
      shown.readOnly,
      view: shown.view,
    );
    return const DocumentOpened();
  }
}
