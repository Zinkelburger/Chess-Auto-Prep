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
///  * **Rebuilds must be coalesced** while generating. A progress tick is not
///    worth a full-screen repaint, and the screen keeps receiving them while
///    it sits hidden in the IndexedStack.
///
/// This class is pure state — no widgets, no timers — so both rules are
/// checkable. The screen owns the actual Timer and setState.
library;

/// What the screen should do in response to one notification.
class GenerationScreenActions {
  const GenerationScreenActions({
    required this.justFinished,
    required this.shouldRunCoherence,
    required this.shouldCoalesceRebuild,
  });

  /// The run ended on this notification (it was generating, now it is not).
  /// Gates the one-shot end-of-run work: outcome snackbar, switching back to
  /// the lines surface.
  final bool justFinished;

  /// A tree worth re-clustering has appeared, or the run just ended.
  final bool shouldRunCoherence;

  /// Rebuild through the throttle rather than immediately. False once the run
  /// ends, so the final state paints without waiting out a timer.
  final bool shouldCoalesceRebuild;
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
      shouldCoalesceRebuild: isGenerating,
    );
  }
}
