part of 'document_session.dart';

sealed class ExternalEditPreparation {
  const ExternalEditPreparation();
}

/// A refusal leaves the shown chapter and its inspection draft untouched.
final class ExternalEditRefused extends ExternalEditPreparation {
  const ExternalEditRefused(this.detail);
  final String detail;
}

/// The immutable primary input of an accepted edit spanning two documents.
/// Its owner retains only retry/adoption state; callers retain the secondary
/// input and operation id with their pending-write obligation.
final class PreparedDocumentEdit extends ExternalEditPreparation {
  PreparedDocumentEdit._(
    this._owner,
    this.primary,
    this.landing,
    this._shown,
    this._generation,
  );

  final ExternalDocumentEdits _owner;
  final store.DocumentEdit primary;
  final Landing landing;
  final ShownDocument _shown;
  final int _generation;
  bool _started = false;
  bool _uncertain = false;
  store.Saved? _completed;
  Future<store.SaveResult>? _running;
}

/// Prepares an edit without displaying it, then adopts one compound receipt.
/// The caller owns retirement/access for both paths and the retained retry.
final class ExternalDocumentEdits {
  ExternalDocumentEdits(this._session);
  final DocumentSession _session;

  Future<ExternalEditPreparation> prepare(
    edits.ChapterEdit Function(Chapter chapter) edit,
  ) async {
    final session = _session;
    final shown = session._shown;
    final ref = session._source;
    final generation = session._opens;
    if (session._disposed ||
        shown == null ||
        ref == null ||
        session._opening != null ||
        session._restoring ||
        session._readOnly != null ||
        session._held != null ||
        session._saver.referencesPending) {
      return const ExternalEditRefused('Keep or discard pending edits first.');
    }
    await session._saver.flush();
    if (!_sameEditor(shown, generation, ref) || !session._saver.settled) {
      return const ExternalEditRefused(
        'The source editor changed or is not saved.',
      );
    }
    final revision = session._saver.revision!;
    final changed = edit(shown.chapter);
    if (changed is! edits.ChapterEdited) {
      return ExternalEditRefused(
        changed is edits.ChapterEditRefused
            ? changed.reason
            : 'The edit changes no games.',
      );
    }
    final landed = landing(
      shown.chapter,
      shown.view,
      changed.chapter,
      changed.games,
    );
    if (landed == null) {
      return const ExternalEditRefused(
        'The edited chapter could not be put back in its file.',
      );
    }
    return PreparedDocumentEdit._(
      this,
      store.DocumentEdit(
        ref: ref,
        text: landed.text,
        expected: revision,
        scope: landed.scope,
      ),
      landed,
      shown,
      generation,
    );
  }

  bool _sameEditor(ShownDocument shown, int generation, DocumentRef ref) =>
      !_session._disposed &&
      _session._opens == generation &&
      _session._opening == null &&
      !_session._restoring &&
      _session._held == null &&
      _session._source == ref &&
      _session._shown == shown;

  Future<store.SaveResult> commit(
    PreparedDocumentEdit prepared,
    Future<store.SaveResult> Function(store.DocumentEdit primary) publish,
  ) {
    if (!identical(prepared._owner, this)) {
      return Future.value(
        const store.SaveRefused('The edit belongs to another session.'),
      );
    }
    final completed = prepared._completed;
    if (completed != null) return Future.value(completed);
    return prepared._running ??= _commit(prepared, publish).whenComplete(() {
      prepared._running = null;
    });
  }

  bool _matches(PreparedDocumentEdit command) {
    final current = _session._saver.revision;
    return _sameEditor(
          command._shown,
          command._generation,
          command.primary.ref,
        ) &&
        current == command.primary.expected &&
        current?.nativeIdentity == command.primary.expected.nativeIdentity;
  }

  Future<store.SaveResult> _publish(
    PreparedDocumentEdit command,
    Future<store.SaveResult> Function(store.DocumentEdit) publish,
  ) async {
    store.SaveResult result;
    try {
      result = await publish(command.primary);
      if (result case store.Saved(:final receipt)) {
        if (receipt.compound?.secondary == null ||
            receipt.compound!.documentAfter != command.primary.text ||
            receipt.beforeRevision != command.primary.expected ||
            (command.primary.expected.nativeIdentity != null &&
                receipt.beforeRevision.nativeIdentity != null &&
                receipt.beforeRevision.nativeIdentity !=
                    command.primary.expected.nativeIdentity)) {
          result = const store.IoFailure(
            'The compound receipt does not match the accepted edit.',
          );
        }
      }
    } on Object catch (error) {
      log.e('publish compound edit ${command.primary.ref.path}', error);
      result = store.IoFailure('$error');
    }
    if (result is store.IoFailure) command._uncertain = true;
    if (result is store.Saved) command._completed = result;
    return result;
  }

  Future<bool> _currentAfter(
    PreparedDocumentEdit command,
    store.Receipt receipt,
  ) async {
    try {
      final current = await _session._store.open(command.primary.ref);
      return current is store.Opened &&
          current.text == command.primary.text &&
          current.revision == receipt.committed &&
          current.revision.nativeIdentity == receipt.committed.nativeIdentity &&
          (command.primary.expected.nativeIdentity == null ||
              receipt.committed.nativeIdentity != null);
    } on Object catch (error) {
      log.e('verify compound edit ${command.primary.ref.path}', error);
      return false;
    }
  }

  Future<store.SaveResult> _commit(
    PreparedDocumentEdit command,
    Future<store.SaveResult> Function(store.DocumentEdit) publish,
  ) async {
    const stale = store.SaveRefused(
      'The source editor changed before publication.',
    );
    // Once admitted, an exact retained command can finish after navigation or
    // disposal. Its receipt must never be inserted into a later editor.
    if (!_matches(command)) {
      return command._started ? _publish(command, publish) : stale;
    }
    final saver = _session._saver;
    final result = await saver.holdStill<store.SaveResult>((_) async {
      if (!_matches(command)) return stale;
      if (!saver.beginExternal(command, command.primary.expected)) return stale;
      if (!_matches(command)) {
        saver.endExternal(
          command,
          stale,
          command.primary.scope,
          uncertain: command._uncertain,
        );
        return stale;
      }
      command._started = true;
      final result = await _publish(command, publish);
      // A historical acknowledgement settles the operation, not the current
      // editor. Another writer may already have replaced or removed its output.
      final currentAfter =
          result is store.Saved &&
          _matches(command) &&
          await _currentAfter(command, result.receipt);
      if (result is store.Saved && _matches(command) && currentAfter) {
        saver.adoptExternal(command, result.receipt, command.primary.scope, () {
          final session = _session;
          session._shown = (
            chapter: command.landing.chapter,
            view: command.landing.view,
          );
          session._follow(command.landing.view);
          session._clearRefusal();
          session._cursor.value = samePathIn(
            command._shown.chapter.tree,
            command.landing.chapter.tree,
            session.cursor,
          );
          session.notifyListeners();
        });
      } else {
        saver.endExternal(
          command,
          result is store.Saved && _matches(command)
              ? const store.Conflict(null)
              : result,
          command.primary.scope,
          uncertain: result is! store.Saved && command._uncertain,
        );
      }
      return result;
    }, continuing: command);
    return result ??
        const store.SaveRefused('The source editor is busy or not saved.');
  }
}
