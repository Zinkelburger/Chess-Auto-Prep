import 'package:flutter/widgets.dart';

/// A [State] that runs [changed] whenever the listenable its widget names
/// notifies, for a state that does more with a change than rebuild — moves
/// a caret, commits a field, scrolls — where a [ListenableBuilder] would
/// not do.
///
/// The subscription follows the widget: rebuilt with another listenable, the
/// state leaves the old one, joins the new one and runs [changed] once,
/// because what it follows may now say something else. It leaves in
/// [dispose], or earlier with [stopListening], so [changed] never runs on a
/// state that is going.
mixin ListeningState<T extends StatefulWidget> on State<T> {
  Listenable? _followed;

  /// What to follow for [widget].
  Listenable listenableOf(T widget);

  /// Runs on each notification while the state is listening.
  void changed();

  @override
  void initState() {
    super.initState();
    _followed = listenableOf(widget)..addListener(_changed);
  }

  @override
  void didUpdateWidget(T old) {
    super.didUpdateWidget(old);
    final now = listenableOf(widget);
    if (_followed == null || _followed == now) return;
    _followed!.removeListener(_changed);
    _followed = now..addListener(_changed);
    changed();
  }

  /// Stops [changed] before [dispose] does, for a state whose own clean-up
  /// changes what it follows: a field that writes its words as it goes must
  /// not hear them come back.
  @protected
  void stopListening() {
    _followed?.removeListener(_changed);
    _followed = null;
  }

  @override
  void dispose() {
    stopListening();
    super.dispose();
  }

  void _changed() {
    if (mounted) changed();
  }
}
