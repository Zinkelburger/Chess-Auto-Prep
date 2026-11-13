import 'dart:async';

import '../storage/saved_place.dart';
import '../storage/settings_store.dart';
import '../workspace/document/document_session.dart';
import 'workspace_requests.dart';

/// Keeps where the window is — the mode and the file on the board — in the
/// settings, so the next launch opens there ([WorkspaceRequests.resume]).
/// Written when the place changes, not on every move within a game; a step
/// to another game of the same file waits for the stepping to stop
/// ([gameSettle]), so holding ↓ through a file writes once.
final class PlaceMemory {
  PlaceMemory({
    required this.settings,
    required this.requests,
    required this.session,
  });

  final SettingsStore settings;
  final WorkspaceRequests requests;
  final DocumentSession session;
  SavedPlace? _kept;
  bool _watching = false;
  Timer? _settling;

  /// How long a new game of the same file waits before it is written.
  static const gameSettle = Duration(seconds: 1);

  /// Starts keeping the place, from the one the launch resumed.
  void start() {
    if (_watching) return;
    _watching = true;
    _kept = settings.value.lastPlace;
    requests.addListener(_changed);
    session.anyChange.addListener(_changed);
  }

  void _changed() {
    final place = requests.place;
    final kept = _kept;
    if (place == kept) return _settling?.cancel();
    final sameFile =
        kept != null &&
        place.mode == kept.mode &&
        place.path == kept.path &&
        place.section == kept.section;
    _settling?.cancel();
    _settling = sameFile ? Timer(gameSettle, flush) : null;
    if (!sameFile) flush();
  }

  /// Writes the place now, rather than when the stepping stops: the window
  /// is closing or losing focus.
  void flush() {
    _settling?.cancel();
    _settling = null;
    if (!_watching) return;
    final place = requests.place;
    if (place == _kept) return;
    _kept = place;
    unawaited(settings.update(settings.value.copyWith(lastPlace: place)));
  }

  void dispose() {
    _settling?.cancel();
    if (!_watching) return;
    _watching = false;
    requests.removeListener(_changed);
    session.anyChange.removeListener(_changed);
  }
}
