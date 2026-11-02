import 'package:flutter/widgets.dart';

import '../diagnostics/log.dart';

/// A [State] that does one slow piece of work at a time and says, in one
/// sentence, when it could not: the busy flag, the problem line and the
/// retry that a dialog or field otherwise writes out by hand.
///
/// [busy] and [problem] feed a `FormDialog` directly, or turn the state's
/// own controls off and fill its `ProblemLine`.
mixin Attempting<T extends StatefulWidget> on State<T> {
  bool _busy = false;

  /// Work started by [attempt] is under way.
  bool get busy => _busy;

  /// What could not be done, as a sentence; [attempt] clears it, and the
  /// state sets it for a failure its work reports as a value.
  String? problem;

  /// Runs [work] unless earlier work is still going, which refuses it.
  ///
  /// Clears [problem] and holds [busy] until [work] ends. When [work]
  /// throws, the log gets [action] with the error and [problem] says
  /// [failure]. Answers what [work] returned, or null when it was refused,
  /// threw, or this state has gone meanwhile.
  @protected
  Future<R?> attempt<R>(
    String action,
    Future<R> Function() work, {
    required String failure,
  }) async {
    if (_busy) return null;
    setState(() {
      _busy = true;
      problem = null;
    });
    try {
      final result = await work();
      return mounted ? result : null;
    } on Object catch (error) {
      log.e(action, error);
      if (mounted) setState(() => problem = failure);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
