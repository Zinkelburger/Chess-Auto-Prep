import 'package:flutter/foundation.dart';

import '../features/trainer/trainer.dart';
import 'mode.dart';
import 'workspace_requests.dart';

/// Keeps the Train tab's sitting beside its controls: in the mode it was
/// started in, with the Train tab open. Anywhere else the board would go on
/// showing the lesson and taking moves for it with nothing to answer or
/// leave it by, so the sitting ends.
final class SittingInView {
  SittingInView({
    required Trainer trainer,
    required WorkspaceRequests requests,
    required bool Function() trainTabOpen,
  }) : _trainer = trainer,
       _requests = requests,
       _trainTabOpen = trainTabOpen {
    for (final owner in _owners) {
      owner.addListener(check);
    }
  }

  final Trainer _trainer;
  final WorkspaceRequests _requests;

  /// Whether the mode on screen has its Train tab open: the tabs are the
  /// shell's, one set per mode.
  final bool Function() _trainTabOpen;

  /// The mode the sitting runs in, while one does.
  Mode? _mode;

  List<Listenable> get _owners => [_trainer, _requests];

  /// Ends the sitting if it is out of view; also listens to the tabs.
  void check() {
    if (_trainer.lesson == null) {
      _mode = null;
      return;
    }
    final mode = _mode ??= _requests.mode;
    if (_requests.mode != mode || !_trainTabOpen()) _trainer.leave();
  }

  void dispose() {
    for (final owner in _owners) {
      owner.removeListener(check);
    }
  }
}
