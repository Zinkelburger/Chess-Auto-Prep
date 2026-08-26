/// The editable state behind [SkeletonPlanCard], plus the veto palette the
/// card offers.
///
/// Lives outside the widget for the same reason the eval sources do: the card
/// sits behind a collapsed expander, and the form reads the plan at Start.
library;

import 'package:flutter/widgets.dart';

import '../../services/generation/skeleton_plan.dart';

/// One toggleable structure veto offered in the UI, with the feature it emits.
class StructureVeto {
  final String label;
  final String tooltip;
  final StructureFeature Function() build;

  const StructureVeto(this.label, this.tooltip, this.build);
}

/// The vetoes the card offers, in display order. A plan's features are
/// matched back onto this list by value, so the order is not persisted.
const List<StructureVeto> kStructureVetoes = [
  StructureVeto(
    'Avoid a pawn on d5',
    'Drops lines where we end up with a pawn on d5 — the symmetric, QGD-ish '
        'structures. Chosen for a fighting, asymmetric repertoire (e.g. Benko).',
    _pawnD5,
  ),
  StructureVeto(
    'Avoid a pawn on e5',
    'Drops lines where we commit a pawn to e5.',
    _pawnE5,
  ),
  StructureVeto(
    'Avoid an early queen trade',
    'Drops lines where the queens come off early (e.g. the dry 4.Qxd4 d5 '
        '5.cxd5 Qxd5 lines) — the trade leaves little to play for.',
    _earlyQueens,
  ),
];

StructureFeature _pawnD5() => const PawnOnSquare(square: 'd5');
StructureFeature _pawnE5() => const PawnOnSquare(square: 'e5');
StructureFeature _earlyQueens() => const EarlyQueenTrade();

/// The lines the player has typed and the structures they have vetoed.
///
/// Notifies on every keystroke as well as on veto changes, so the card's live
/// feedback ("5 pinned moves across 1 line") needs no state of its own.
class SkeletonPlanController extends ChangeNotifier {
  /// One line per row, PGN or bare SAN. The source of truth for the plan —
  /// the card re-parses it rather than caching a [SkeletonPlan].
  final TextEditingController lines = TextEditingController();

  final Set<int> _vetoes = {};

  SkeletonPlanController() {
    lines.addListener(notifyListeners);
  }

  /// Indices into [kStructureVetoes] that are currently on.
  Set<int> get activeVetoes => Set.unmodifiable(_vetoes);

  bool isVetoed(int index) => _vetoes.contains(index);

  void setVeto(int index, {required bool on}) {
    final changed = on ? _vetoes.add(index) : _vetoes.remove(index);
    if (changed) notifyListeners();
  }

  /// Loads an existing plan back into the editor (resume / preset).
  void loadPlan(SkeletonPlan plan) {
    _vetoes
      ..clear()
      ..addAll(_matchVetoes(plan.features));
    // Assigning the text notifies through the field listener, so the vetoes
    // must already be in place when it does.
    lines.text = plan.sourceLines.join('\n');
    notifyListeners();
  }

  /// The plan the form should build with. Empty text and no vetoes → empty
  /// plan (the classic build).
  SkeletonPlan currentPlan({required bool playAsWhite}) {
    return SkeletonPlan.fromLines(
      lines.text.split('\n'),
      playAsWhite: playAsWhite,
      features: [
        for (final i in _vetoes)
          if (i >= 0 && i < kStructureVetoes.length)
            kStructureVetoes[i].build(),
      ],
    );
  }

  @override
  void dispose() {
    lines.removeListener(notifyListeners);
    lines.dispose();
    super.dispose();
  }

  Set<int> _matchVetoes(List<StructureFeature> features) {
    return {
      for (final feature in features)
        for (var i = 0; i < kStructureVetoes.length; i++)
          if (_sameFeature(kStructureVetoes[i].build(), feature)) i,
    };
  }

  bool _sameFeature(StructureFeature a, StructureFeature b) {
    if (a is PawnOnSquare && b is PawnOnSquare) {
      return a.square == b.square && a.ours == b.ours && a.avoid == b.avoid;
    }
    return a is EarlyQueenTrade && b is EarlyQueenTrade;
  }
}
