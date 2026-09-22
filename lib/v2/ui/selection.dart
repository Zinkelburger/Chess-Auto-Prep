import 'package:flutter/foundation.dart';

/// Which one of many keyed things is selected, told only to the two a
/// change concerns.
///
/// A move list highlights the move the cursor is on. Were each of a
/// thousand moves to listen to the cursor, every arrow key would call a
/// thousand listeners to change two highlights. Each thing asks [of] for its
/// own flag instead, and a change of the source flips the flag of the key
/// it left and of the key it reached, and no other.
final class Selection<K> {
  ValueListenable<K>? _source;
  var _flags = <K, ValueNotifier<bool>>{};
  Object? _at;

  /// Follows [source] from now on, forgetting the flags handed out for the
  /// one before.
  void follow(ValueListenable<K> source) {
    _source?.removeListener(_moved);
    _source = source..addListener(_moved);
    _at = source.value;
    _flags = {};
  }

  /// Whether [key] is the selected one, notifying when that changes.
  ValueListenable<bool> of(K key) =>
      _flags.putIfAbsent(key, () => ValueNotifier(key == _at));

  /// Forgets the flags handed out so far, for a list built again whose keys
  /// may no longer name the same things. The flags already handed out stop
  /// changing; the things holding them are being replaced.
  void reset() => _flags = {};

  void _moved() {
    final to = _source?.value;
    if (to == _at) return;
    _flags[_at]?.value = false;
    _flags[to]?.value = true;
    _at = to;
  }

  void dispose() {
    _source?.removeListener(_moved);
    _source = null;
  }
}
