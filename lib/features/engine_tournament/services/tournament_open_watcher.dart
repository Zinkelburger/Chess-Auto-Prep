/// Turns an open-request file into a navigation inside the running app.
///
/// Checks once on start — which is what makes a request written while the app
/// was closed still work — and then watches the directory so a request
/// written by an agent mid-session lands immediately.
///
/// Deliberately timer-free: a periodic poll in the always-mounted host screen
/// would leak into every widget test that pumps it. The directory watch covers
/// the live case, and [check] is called again on app resume and on entering
/// the tournament screen, which covers the rest.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'tournament_open_request.dart';

class TournamentOpenWatcher {
  TournamentOpenWatcher({required this.directory, required this.onRequest})
    : _requests = TournamentOpenRequests(directory);

  /// `Documents/engine_tournaments`.
  final Directory directory;

  /// Called with the id of the tournament to open. Never called for a stale
  /// or malformed request.
  final void Function(String tournamentId) onRequest;

  final TournamentOpenRequests _requests;
  StreamSubscription<FileSystemEvent>? _subscription;
  bool _stopped = false;

  /// True once the directory watch is live. False means [check] is the only
  /// path — the request still arrives, just not until something asks.
  bool get isWatching => _subscription != null;

  /// Consume anything already waiting, then watch for more.
  ///
  /// Never throws: the app must start whether or not the documents directory
  /// exists, is watchable, or is reachable at all (a widget test with no
  /// path_provider is the common case).
  Future<void> start() async {
    await check();
    if (_stopped) return;
    try {
      if (!await directory.exists()) await directory.create(recursive: true);
      _subscription = directory
          .watch(events: FileSystemEvent.all)
          .listen(
            (event) {
              if (p.basename(event.path) != kOpenRequestFileName) return;
              unawaited(check());
            },
            onError: (Object _) {
              // inotify limits, a removed directory — fall back to [check].
              unawaited(stop());
            },
            cancelOnError: true,
          );
    } catch (_) {
      _subscription = null;
    }
  }

  /// Read and clear any pending request, delivering it if it is fresh.
  Future<void> check() async {
    if (_stopped) return;
    try {
      final request = await _requests.take();
      if (request == null || _stopped) return;
      onRequest(request.tournamentId);
    } catch (_) {
      // A request that cannot be read is not worth breaking navigation over.
    }
  }

  Future<void> stop() async {
    _stopped = true;
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }
}
