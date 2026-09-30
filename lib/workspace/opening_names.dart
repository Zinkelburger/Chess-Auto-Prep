import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../chess/openings.dart';
import '../diagnostics/log.dart';

/// The bundled opening book, read once, the first time a name is wanted.
///
/// Replaying some 3,800 lines takes longer than a frame, so the text is
/// parsed on another isolate; until it is, and for good when the book cannot
/// be read, there are no names and nothing waits for them. Listeners hear
/// once, when the names arrive.
final class OpeningNames extends ChangeNotifier {
  OpeningNames(this._read);

  /// The text of each volume of the book: the bundled TSV assets.
  final Future<List<String>> Function() _read;

  Openings _book = Openings.none;
  Future<Openings>? _loading;
  bool _disposed = false;

  /// The names as read so far. The first call starts the reading.
  Openings get book {
    unawaited(load());
    return _book;
  }

  /// The names, once read; [Openings.none] when the book could not be.
  Future<Openings> load() => _loading ??= _load();

  Future<Openings> _load() async {
    try {
      final volumes = await _read();
      if (volumes.isEmpty) return Openings.none;
      final book = await Isolate.run(() => Openings.parse(volumes));
      if (_disposed) return book;
      _book = book;
      notifyListeners();
      return book;
    } on Object catch (error) {
      log.w('Read the opening names', error);
      return Openings.none;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
