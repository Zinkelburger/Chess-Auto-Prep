/// Which of an owner's requests still has a say once its awaits are over.
///
/// A request takes a [Ticket] as it starts and asks it after each await: a
/// newer request, a [cancel] or the owner's [close] overtakes it, and what
/// it brings back late is dropped instead of shown. Closing folds the
/// owner's disposal into the same question, so a check cannot remember the
/// one and forget the other.
final class Latest {
  int _count = 0;
  bool _closed = false;

  /// A ticket for a request starting now, overtaking every earlier one.
  Ticket begin() => Ticket._(this, ++_count);

  /// A ticket for the work under way, overtaking nothing: work that only
  /// has to notice the next [begin] or [cancel], as two answers about the
  /// same move do.
  Ticket get now => Ticket._(this, _count);

  /// Overtakes every ticket handed out, starting nothing in their place.
  void cancel() => _count++;

  /// The owner is gone: no ticket is current again, not even one taken
  /// after this.
  void close() => _closed = true;
}

/// One request's place in its [Latest].
final class Ticket {
  const Ticket._(this._of, this._count);

  final Latest _of;
  final int _count;

  /// No newer request, cancel or close has come since this was taken.
  bool get current => !_of._closed && _count == _of._count;

  /// What this request brings back is late and is dropped.
  bool get overtaken => !current;
}
