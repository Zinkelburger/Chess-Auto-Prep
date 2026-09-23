import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../chess/bughouse/table.dart';
import '../../storage/bughouse_books.dart';
import 'bughouse_lab.dart';

/// The FICS archive under the lab's tables: whether this machine has it,
/// whether the user has it open, and what it recorded from the table on
/// screen. Shut by default; the lab offers it only when the file is there.
final class ArchiveMoves extends ChangeNotifier {
  ArchiveMoves({required this.lab, required FicsBook book}) : _book = book {
    lab.addListener(_labChanged);
  }

  final BughouseLab lab;
  final FicsBook _book;

  bool _available = false;
  bool _shown = false;
  FicsLookup? _lookup;
  TablePosition? _asked;
  bool _disposed = false;

  bool get available => _available;
  bool get shown => _shown;

  /// What the archive answered for the table on screen, while open.
  FicsLookup? get lookup => _shown ? _lookup : null;

  /// Looks for the archive: the mode is on screen.
  Future<void> open() async {
    final available = await _book.available();
    if (_disposed) return;
    _available = available;
    notifyListeners();
    if (_shown) unawaited(_refresh());
  }

  void toggle() {
    if (!_available) return;
    _shown = !_shown;
    notifyListeners();
    if (_shown) unawaited(_refresh());
  }

  void _labChanged() {
    if (_shown && lab.position != _asked) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final position = _asked = lab.position;
    final lookup = await _book.explore(position);
    if (_disposed || !identical(lab.position, position)) return;
    _lookup = lookup;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    lab.removeListener(_labChanged);
    super.dispose();
  }
}
