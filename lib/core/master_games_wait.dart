/// A generation run parked on the master-games download it asked for.
///
/// A build that wants master practice against an empty master-games
/// database fills it first, before the engine is claimed (holding Stockfish
/// across a multi-gigabyte download would strand it for nothing). This
/// object owns that wait: joining or starting the sync, mirroring its
/// status, and releasing the run when the download ends, the user says
/// "start now without them", or the build is cancelled.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/master_games/master_games_service.dart';
import '../utils/log.dart';

/// The slice of [MasterGamesService] the wait needs, so the wait can be
/// exercised without TWIC downloads. [MasterGamesServiceSync] adapts the
/// real service.
abstract interface class MasterGamesSync {
  /// Whether a download is already in flight (started elsewhere).
  bool get isSyncing;

  /// The service's own progress line, mirrored into the build status.
  String get status;

  /// Start a download. Completes when it ends — finished, cancelled or
  /// failed.
  Future<void> sync();

  /// Completes when the download in flight ends.
  Future<void> get syncCompletion;

  /// Stop the download in flight.
  void cancel();

  void addListener(VoidCallback listener);
  void removeListener(VoidCallback listener);
}

/// [MasterGamesSync] over the real service.
class MasterGamesServiceSync implements MasterGamesSync {
  const MasterGamesServiceSync(this._service);

  final MasterGamesService _service;

  @override
  bool get isSyncing => _service.isSyncing;

  @override
  String get status => _service.status;

  @override
  Future<void> sync() => _service.sync();

  @override
  Future<void> get syncCompletion => _service.syncCompletion;

  @override
  void cancel() => _service.cancel();

  @override
  void addListener(VoidCallback listener) => _service.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _service.removeListener(listener);
}

class MasterGamesWait {
  /// Status shown while the service has no progress line of its own yet.
  static const String downloadingStatus = 'Downloading master games…';

  /// Set once the user answers "start now without them". Sticky on purpose:
  /// a plan run builds one chapter after another, and being asked to wait
  /// again for every chapter would make the answer meaningless.
  bool _declined = false;

  /// Completes when the run stops waiting — because the user said so, or
  /// because the build was cancelled. Null whenever no run is parked here.
  Completer<void>? _gate;

  /// The sync being waited on, while parked.
  MasterGamesSync? _sync;

  /// Whether the sync being waited on was started by this wait (so stopping
  /// the wait may stop the download) rather than joined.
  bool _startedSync = false;

  /// True once the user declined the wait this session.
  bool get declined => _declined;

  /// True while a run is parked on the download.
  bool get isWaiting => _gate != null;

  /// Park until [sync] ends or the wait is released by [stopWaiting] or
  /// [decline]. A sync already in flight (the startup auto-sync, or one
  /// started from Settings) is joined rather than duplicated — and, because
  /// it is not ours, is left running when we stop waiting. A failed download
  /// is not fatal: it is logged and the run proceeds without a book.
  ///
  /// [onStatus] receives the service's progress line on every change (or
  /// [downloadingStatus] while it has none).
  Future<void> park(
    MasterGamesSync sync, {
    required void Function(String status) onStatus,
  }) async {
    _sync = sync;
    _startedSync = !sync.isSyncing;
    final gate = _gate = Completer<void>();
    void mirror() {
      final status = sync.status;
      onStatus(status.isEmpty ? downloadingStatus : status);
    }

    sync.addListener(mirror);
    try {
      final done = (_startedSync ? sync.sync() : sync.syncCompletion)
          .catchError((Object e) {
            log.w(
              'master games download failed',
              name: 'GenerationSession',
              error: e,
            );
          });
      // Whichever comes first: the sync ending, or the user (or a cancel)
      // deciding not to wait for it.
      await Future.any([done, gate.future]);
    } finally {
      sync.removeListener(mirror);
      _gate = null;
      _sync = null;
    }
  }

  /// Stop waiting. The download itself is cancelled only when this wait
  /// started it — a sync the user kicked off from Settings is theirs, and
  /// keeps going. Cancelled or not, issues already imported are kept and the
  /// next sync resumes from there.
  void stopWaiting() {
    final gate = _gate;
    if (gate == null || gate.isCompleted) return;
    if (_startedSync) _sync?.cancel();
    gate.complete();
  }

  /// "Start now without them": release the wait and remember the answer for
  /// the rest of the session.
  void decline() {
    _declined = true;
    stopWaiting();
  }
}
