import 'dart:async';

enum DocumentCloseDisposition { approved, cancelled, changed, failed }

class DocumentCloseResult {
  const DocumentCloseResult(this.disposition, [this.error]);
  final DocumentCloseDisposition disposition;
  final Object? error;
}

/// An approval names the exact revision the user or save operation resolved.
/// Later edits invalidate it; closing a different editor cannot discard them.
class DocumentCloseApproval {
  const DocumentCloseApproval(this.revision);
  final Object revision;
}

/// App-lifetime coordination only: each document owns its save/confirmation UI.
/// No participant may close the native window or change the close policy.
class DocumentCloseCoordinator {
  final _participants = <Object, _Participant>{};
  Future<DocumentCloseResult>? _pending;
  int _membership = 0;
  bool _disposed = false;

  void Function() register({
    required Object key,
    required Object Function() revision,
    required Future<DocumentCloseApproval?> Function() prepare,
  }) {
    if (_disposed) throw StateError('Close coordinator is disposed');
    if (_participants.containsKey(key)) {
      throw StateError('Duplicate close owner');
    }
    final participant = _Participant(revision, prepare);
    _participants[key] = participant;
    _membership++;
    return () {
      if (identical(_participants[key], participant)) {
        _participants.remove(key);
        _membership++;
      }
    };
  }

  /// Repeated native events share one attempt and never stack confirmations.
  Future<DocumentCloseResult> prepareClose() {
    if (_disposed) {
      return Future.value(
        const DocumentCloseResult(DocumentCloseDisposition.cancelled),
      );
    }
    return _pending ??= Future<void>.value()
        .then((_) => _prepare())
        .whenComplete(() => _pending = null);
  }

  Future<DocumentCloseResult> _prepare() async {
    final membership = _membership;
    final approvals = <_Participant, Object>{};
    try {
      for (final participant in List.of(_participants.values)) {
        final approval = await participant.prepare();
        if (_disposed || approval == null) {
          return const DocumentCloseResult(DocumentCloseDisposition.cancelled);
        }
        approvals[participant] = approval.revision;
      }
      if (membership != _membership ||
          approvals.entries.any(
            (entry) => entry.key.revision() != entry.value,
          )) {
        return const DocumentCloseResult(DocumentCloseDisposition.changed);
      }
      return const DocumentCloseResult(DocumentCloseDisposition.approved);
    } catch (error) {
      return DocumentCloseResult(DocumentCloseDisposition.failed, error);
    }
  }

  void dispose() {
    _disposed = true;
    _participants.clear();
    _membership++;
  }
}

class _Participant {
  const _Participant(this.revision, this.prepare);
  final Object Function() revision;
  final Future<DocumentCloseApproval?> Function() prepare;
}
