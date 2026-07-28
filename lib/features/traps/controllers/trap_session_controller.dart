/// The trap state a repertoire screen carries: the loaded traps, their
/// position index, and whether the trap tour is running.
///
/// This used to be four fields and four methods living inside
/// `_RepertoireScreenState`, where none of it could be exercised without
/// mounting the whole screen. The rules worth pinning are small but real:
/// traps are adopted from a finished build when one is in memory and re-read
/// from disk otherwise; a tour cannot open over an empty trap list; and a
/// repertoire switch must not leave the previous repertoire's tour on screen.
library;

import 'package:flutter/foundation.dart';

import 'package:chess_auto_prep/models/trap_line_info.dart';
import '../../../services/generation/trap_extractor.dart';
import '../../../utils/safe_change_notifier.dart';
import '../services/trap_index_service.dart';
import '../services/trap_tour_order.dart';

/// Reads a repertoire's trap sidecar file. Injectable so tests do not need
/// one on disk.
typedef TrapFileLoader = Future<List<TrapLineInfo>?> Function(String filePath);

class TrapSessionController extends ChangeNotifier with SafeChangeNotifier {
  TrapSessionController({TrapFileLoader? loadFile})
    : _loadFile = loadFile ?? TrapExtractor.loadFromFile;

  final TrapFileLoader _loadFile;

  List<TrapLineInfo> _traps = const [];
  TrapIndexService? _index;
  bool _tourVisible = false;
  TrapLineInfo? _tourInitialTrap;

  List<TrapLineInfo> get traps => _traps;
  bool get hasTraps => _traps.isNotEmpty;

  /// Position index for the loaded traps, or null when there are none.
  TrapIndexService? get index => _index;

  bool get tourVisible => _tourVisible;

  /// Trap the tour should open on, or null to start from the top.
  TrapLineInfo? get tourInitialTrap => _tourInitialTrap;

  /// Reads the trap sidecar next to [filePath] and replaces the current set.
  Future<void> loadFromFile(String filePath) async {
    final traps = await _loadFile(filePath);
    _setTraps(traps ?? const []);
  }

  /// Takes the trap index a finished build produced.
  ///
  /// A build's own bundle is consistent with the tree it just built, so it
  /// wins over the file. Repertoires loaded from disk have no bundle in
  /// memory, so [fallbackFilePath] re-reads the sidecar instead.
  Future<void> adoptFromBuild(
    TrapIndexService? bundleIndex, {
    String? fallbackFilePath,
  }) async {
    if (bundleIndex != null) {
      final traps = bundleIndex.allTraps;
      _traps = traps;
      _index = traps.isEmpty ? null : bundleIndex;
      notifyListeners();
      return;
    }
    if (fallbackFilePath != null) await loadFromFile(fallbackFilePath);
  }

  /// Opens the tour, optionally starting at [startTrap]. Returns false — and
  /// changes nothing — when there is no trap to tour.
  bool openTour({TrapLineInfo? startTrap}) {
    if (_index == null || _traps.isEmpty) return false;
    _tourVisible = true;
    _tourInitialTrap = startTrap;
    notifyListeners();
    return true;
  }

  /// Closes the tour. Returns whether it was open.
  bool closeTour() {
    if (!_tourVisible) return false;
    _tourVisible = false;
    _tourInitialTrap = null;
    notifyListeners();
    return true;
  }

  /// Drops the tour when the screen switches to another repertoire — a tour
  /// through the previous repertoire's traps means nothing here. The traps
  /// themselves are replaced by the load that follows.
  void endTourForRepertoireSwitch() {
    _tourVisible = false;
    _tourInitialTrap = null;
  }

  /// The trap at [fen], or null. Convenience over [index] for callers that
  /// only want the lookup.
  TrapLineInfo? trapAtFen(String fen) => _index?.trapAtFen(fen);

  /// "Trap #3 · Sicilian Defense" — numbered in tour order, so the browser,
  /// the tour bar, and the loaded PGN line all agree.
  String titleFor(TrapLineInfo trap) => trapTourTitle(_traps, trap);

  void _setTraps(List<TrapLineInfo> traps) {
    _traps = traps;
    _index = traps.isEmpty ? null : TrapIndexService(traps);
    notifyListeners();
  }
}
