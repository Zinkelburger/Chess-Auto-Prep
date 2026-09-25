import 'dart:async';

/// Tracks accepted durable work across feature lifetimes. A feature may go
/// away while its write remains pending; application shutdown still owns the
/// obligation. Only the same obligation's retry or an explicitly superseding
/// snapshot or explicit user discard can clear a failure; another successful
/// command cannot.
final class PendingWrites {
  final _pending = <Future<void>, Object>{};
  final _failures = <Object, String>{};
  final _versions = <Object, int>{};
  final _obligations = <PendingObligation<Object?>>{};

  Future<T> track<T>(
    Object owner,
    Future<T> work, {
    required String label,
    String? Function(T value)? problem,
    Object? obligation,
  }) {
    final identity = obligation ?? Object();
    final version = (_versions[identity] ?? 0) + 1;
    if (obligation != null) _versions[identity] = version;
    bool current() => obligation == null || _versions[identity] == version;
    late final Future<void> watched;
    watched = work
        .then<void>(
          (value) {
            if (!current()) return;
            final failure = problem?.call(value);
            if (failure == null) {
              _failures.remove(identity);
            } else {
              _failures[identity] = '$label: $failure';
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!current()) return;
            _failures[identity] = '$label: $error';
          },
        )
        .whenComplete(() => _pending.remove(watched));
    _pending[watched] = owner;
    return work;
  }

  /// A queued command belongs to its resource even before it constructs its
  /// final rows. Reads of that resource wait through presentation replacement.
  void watch(Object resource, Future<Object?> work) {
    late final Future<void> watched;
    watched = work
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(() => _pending.remove(watched));
    _pending[watched] = resource;
  }

  PendingObligation<T> accept<T>({
    required Object resource,
    required String label,
    required Future<T> Function() work,
    required String? Function(T) problem,
    T Function()? blocked,
  }) {
    final entry = PendingObligation<T>._(
      this,
      resource,
      label,
      work,
      problem,
      blocked,
    );
    _obligations.add(entry);
    return entry;
  }

  List<PendingObligation<Object?>> unfinished(Object resource) => [
    for (final entry in _obligations)
      if (entry.resource == resource) entry,
  ];

  Future<bool> _preceding(PendingObligation<Object?> current) async {
    final earlier = _obligations
        .takeWhile((entry) => entry != current)
        .where((entry) => entry.resource == current.resource)
        .toList();
    for (final entry in earlier) {
      final running = entry._running;
      if (running != null) {
        await running.then<void>((_) {}, onError: (Object _) {});
      }
      if (!entry.committed) return false;
    }
    return true;
  }

  /// A resource barrier, never a global drain inside another accepted command.
  Future<void> settleFor(Object resource) async {
    while (true) {
      final pending = [
        for (final entry in _pending.entries)
          if (entry.value == resource) entry.key,
      ];
      if (pending.isEmpty) return;
      await Future.wait(pending);
    }
  }

  /// Retry in acceptance order and stop at the first unresolved operation.
  Future<void> retry(Object resource) async {
    await settleFor(resource);
    for (final entry in unfinished(resource)) {
      await entry.run();
      if (!entry.committed) return;
    }
  }

  /// Drains work accepted while earlier writes finish, not just a snapshot.
  Future<String?> settle() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.keys.toList());
    }
    final failures = [
      ..._failures.values,
      for (final entry in _obligations) '${entry.label}: ${entry.detail}',
    ];
    return failures.isEmpty ? null : failures.join('\n');
  }
}

/// One accepted mutation. Its immutable payload and any store retry token live
/// in its work closure, not in the screen which happened to initiate it. Successful entries
/// leave the registry; their original caller can still safely ask again.
final class PendingObligation<T> {
  PendingObligation._(
    this._registry,
    this.resource,
    this.label,
    this._work,
    this._problem,
    this._blocked,
  );

  final PendingWrites _registry;
  final Object resource;
  final String label;
  final Future<T> Function() _work;
  final String? Function(T) _problem;
  final T Function()? _blocked;
  Future<T>? _running;
  T? _result;
  String? _detail;
  bool _committed = false;
  bool _discarded = false;

  bool get discarded => _discarded;

  /// Explicitly abandon a failed, idle save. This never undoes disk writes,
  /// claims a commit, or releases ownership of an in-flight operation.
  bool discard() {
    if (_running != null || _detail == null || committed || discarded)
      return false;
    _discarded = true;
    _registry._obligations.remove(this);
    return true;
  }

  T? get result => _result;

  /// Resolved with no persistence left pending. A caller may also resolve a
  /// confirmed refusal that made no changes, such as an initial name collision.
  bool get committed => _committed;

  String get detail => _detail ?? 'Not saved yet.';

  Future<T> run() {
    if (discarded) return Future.error(StateError('This save was discarded.'));
    if (committed) return Future.value(result as T);
    if (_running case final running?) return running;
    final running = _perform();
    _running = running;
    _registry.watch(resource, running);
    return running;
  }

  Future<T> _perform() async {
    try {
      final blocked = _blocked;
      final value = blocked != null && !await _registry._preceding(this)
          ? blocked()
          : await Future<T>.sync(_work);
      _result = value;
      _detail = _problem(value);
      _committed = _detail == null;
      if (committed) _registry._obligations.remove(this);
      return value;
    } on Object catch (error) {
      _detail = '$error';
      rethrow;
    } finally {
      _running = null;
    }
  }
}
