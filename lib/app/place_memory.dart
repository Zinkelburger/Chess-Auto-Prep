import 'dart:async';

import '../storage/saved_place.dart';
import '../storage/settings_store.dart';
import '../workspace/document/document_session.dart';
import 'workspace_requests.dart';

/// Keeps where the window is — the mode and the file on the board — in the
/// settings, so the next launch opens there ([WorkspaceRequests.resume]).
/// Written when the place changes, not on every move within a game.
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
    if (place == _kept) return;
    _kept = place;
    unawaited(settings.update(settings.value.copyWith(lastPlace: place)));
  }

  void dispose() {
    if (!_watching) return;
    requests.removeListener(_changed);
    session.anyChange.removeListener(_changed);
  }
}
