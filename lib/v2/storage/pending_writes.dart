import 'dart:async';

/// Tracks accepted durable work across feature lifetimes. A feature may go
/// away while its write remains pending; application shutdown still owns the
/// obligation. Failures remain visible until that owner successfully retries.
final class PendingWrites {
  final _pending = <Future<void>>{};
  final _failures = <Object, String>{};

  Future<T> track<T>(
    Object owner,
    Future<T> work, {
    required String label,
    String? Function(T value)? problem,
  }) {
    late final Future<void> watched;
    watched = work
        .then<void>(
          (value) {
            final failure = problem?.call(value);
            if (failure == null) {
              _failures.remove(owner);
            } else {
              _failures[owner] = '$label: $failure';
            }
          },
          onError: (Object error, StackTrace stack) {
            _failures[owner] = '$label: $error';
          },
        )
        .whenComplete(() => _pending.remove(watched));
    _pending.add(watched);
    return work;
  }

  /// Drains work accepted while earlier writes finish, not just a snapshot.
  Future<String?> settle() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
    return _failures.isEmpty ? null : _failures.values.join('\n');
  }
}
