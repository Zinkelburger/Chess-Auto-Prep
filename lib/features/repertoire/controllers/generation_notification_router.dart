/// Decides what the repertoire screen should do when the generation
/// controller notifies.
///
/// Generation notifies many times per second while a build runs, and the
/// screen's response is not "rebuild" — it is seven different things, only
/// some of which may happen on any given tick. Two of those decisions are
/// stateful and were previously inline in the screen's listener, where they
/// could not be tested:
///
///  * **Coherence re-clustering** must run when a *new* tree appears or the
///    run completes — not on every progress tick. It used to, which meant
///    re-extracting itemsets over every repertoire line several times a second
///    for the whole build.
/// This class retains only one-shot UI effects; the generation owner bounds
/// progress notifications for all listeners.
library;

/// What the screen should do in response to one notification.
class GenerationScreenActions {
  const GenerationScreenActions({
    required this.justFinished,
    required this.shouldRunCoherence,
  });

  /// The run ended on this notification (it was generating, now it is not).
  /// Gates the one-shot end-of-run work: outcome snackbar, switching back to
  /// the lines surface.
  final bool justFinished;

  /// A tree worth re-clustering has appeared, or the run just ended.
  final bool shouldRunCoherence;
}

class GenerationNotificationRouter {
  bool _wasGenerating = false;

  /// The tree the last coherence pass ran against. Compared by identity: a
  /// build mutates its tree in place, so equality would not distinguish "the
  /// same tree, further along" from "a new tree".
  Object? _lastCoherenceTree;

  /// True between the start of a run and its end, as last observed.
  bool get wasGenerating => _wasGenerating;

  GenerationScreenActions onNotified({
    required bool isGenerating,
    required Object? generatedTree,
  }) {
    final justFinished = !isGenerating && _wasGenerating;
    _wasGenerating = isGenerating;

    final shouldRunCoherence =
        generatedTree != null &&
        (justFinished || !identical(generatedTree, _lastCoherenceTree));
    if (shouldRunCoherence) _lastCoherenceTree = generatedTree;

    return GenerationScreenActions(
      justFinished: justFinished,
      shouldRunCoherence: shouldRunCoherence,
    );
  }
}
