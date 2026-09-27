import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../workspace/document_session.dart';

/// The PGN Viewer's autoplay: the game on the board played forward along
/// its main line, one move a second, as the old viewer's Space plays it.
///
/// The first move comes a moment after the key, so the press reads as the
/// start rather than a jump. It stops at the end of the line, and at
/// anything else that moves the cursor or changes the document — a click
/// on a move, an arrow key, another game — since that is the user taking
/// the board back.
final class AutoPlay extends ChangeNotifier {
  AutoPlay(this._session);

  static const firstStep = Duration(milliseconds: 300);
  static const step = Duration(seconds: 1);

  final DocumentSession _session;
  Timer? _timer;

  /// Set while this moves the cursor itself, so its own step is not taken
  /// for the user's.
  bool _stepping = false;

  bool get playing => _timer != null;

  void toggle() => playing ? stop() : _start();

  void stop() {
    final timer = _timer;
    if (timer == null) return;
    timer.cancel();
    _timer = null;
    _session.cursorListenable.removeListener(_tookOver);
    _session.removeListener(_tookOver);
    notifyListeners();
  }

  void _start() {
    if (_atEnd) return;
    _session.cursorListenable.addListener(_tookOver);
    _session.addListener(_tookOver);
    _timer = Timer(firstStep, _step);
    notifyListeners();
  }

  void _step() {
    final before = _session.cursor;
    _stepping = true;
    _session.forward();
    _stepping = false;
    // A move the session would not go to — a hidden answer — ends it too.
    if (_session.cursor == before || _atEnd) return stop();
    _timer = Timer(step, _step);
  }

  /// Whether there is no next move on the main line from the cursor, or
  /// nothing on the board.
  bool get _atEnd => _session.tree?.nodeAt(_session.cursor.mainChild) == null;

  void _tookOver() {
    if (!_stepping) stop();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _session.cursorListenable.removeListener(_tookOver);
    _session.removeListener(_tookOver);
    super.dispose();
  }
}
