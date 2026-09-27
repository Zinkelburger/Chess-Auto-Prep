import 'package:flutter/foundation.dart';

/// A mode's visible games, addressed by their original file indices. The
/// counter and keyboard use the same ordering as the list without owning it.
abstract interface class GameOrdering implements Listenable {
  List<int> get gameOrder;
}
