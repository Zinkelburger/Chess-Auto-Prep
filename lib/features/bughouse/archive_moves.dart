import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../chess/bughouse/table.dart';
import '../../storage/bughouse_books.dart';
import 'bughouse_lab.dart';

/// The FICS archive under the lab's tables: whether this machine has it,
/// and what it recorded from the table on screen. Shown whenever the file
/// is there.
final class ArchiveMoves extends ChangeNotifier {
  ArchiveMoves({required this.lab, required FicsBook book}) : _book = book {
    lab.addListener(_labChanged);
  }

  final BughouseLab lab;
  final FicsBook _book;

  bool _available = false;
  FicsLookup? _lookup;
  TablePosition? _asked;
  bool _disposed = false;

  bool get available => _available;

  /// What the archive answered for the table on screen.
  FicsLookup? get lookup => _available ? _lookup : null;

  /// Looks for the archive: the mode is on screen.
  Future<void> open() async {
    final available = await _book.available();
    if (_disposed) return;
    _available = available;
    notifyListeners();
    if (available) unawaited(_refresh());
  }

  void _labChanged() {
    if (_available && lab.position != _asked) unawaited(_refresh());
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
