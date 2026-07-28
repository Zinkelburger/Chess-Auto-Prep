/// Tour ordering and identity for traps.
///
/// The trap tour, the traps browser, and the PGN title of a loaded trap line
/// all have to agree on "which trap is #3" — so the ordering has to be one
/// definition, not three. It used to be a pair of statics hanging off
/// [TrapTourBar], which meant callers reached through a widget to sort a list.
library;

import 'package:chess_auto_prep/models/trap_line_info.dart';

/// Tour order: most trick surplus first (matches the traps browser default).
List<TrapLineInfo> sortTrapsForTour(List<TrapLineInfo> traps) {
  final sorted = List<TrapLineInfo>.from(traps);
  sorted.sort((a, b) => b.trickSurplus.compareTo(a.trickSurplus));
  return sorted;
}

/// Whether two trap records describe the same trap.
///
/// Traps are re-read from disk and rebuilt by generation, so instances are not
/// stable — identity is the position when both know it, and the move sequence
/// otherwise.
bool isSameTrap(TrapLineInfo a, TrapLineInfo b) {
  if (identical(a, b)) return true;
  if (a.fen != null && b.fen != null && a.fen == b.fen) return true;
  if (a.movesSan.length != b.movesSan.length) return false;
  for (var i = 0; i < a.movesSan.length; i++) {
    if (a.movesSan[i] != b.movesSan[i]) return false;
  }
  return true;
}

/// Index of [trap] within an already-[sortTrapsForTour]ed list, or -1.
int indexOfTrap(List<TrapLineInfo> sorted, TrapLineInfo trap) {
  for (var i = 0; i < sorted.length; i++) {
    if (isSameTrap(sorted[i], trap)) return i;
  }
  return -1;
}

/// Human label for a trap's place in the tour: `Trap #3 · Sicilian Defense`.
///
/// [allTraps] may be in any order — it is sorted here — so callers cannot
/// number a trap against a list the tour would have ordered differently.
String trapTourTitle(List<TrapLineInfo> allTraps, TrapLineInfo trap) {
  final index = indexOfTrap(sortTrapsForTour(allTraps), trap);
  final number = index >= 0 ? 'Trap #${index + 1}' : 'Trap';
  final opening = trap.openingName;
  return opening != null ? '$number · $opening' : number;
}
