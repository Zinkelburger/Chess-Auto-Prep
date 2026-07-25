/// Plans a draft → repertoire merge against the FULL repertoire (every line),
/// and applies the user's per-conflict decisions.
///
/// The repertoire's source of truth is the multi-game PGN file; merging means
/// *appending new line entries*, never rewriting existing ones. So the plan is
/// expressed in file terms:
///   • [DraftMergePlan.newLines] – draft root-to-leaf lines the repertoire
///     does not already contain (each becomes one appended PGN game).
///   • [DraftMergePlan.conflicts] – positions where the draft plays a
///     different *my* move than the existing prep. The user decides per
///     conflict: keep the prep (drop that draft branch) or import the
///     alternative as extra lines. Nothing is ever removed either way.
///
/// Conflicts are SAN-sequence based — they must stay valid after the review
/// pane's board previews mutate the controller's working tree, so they carry
/// no [TreePath]s into live state.
///
/// Pure / synchronous / no I/O — fully unit-testable.
library;

import '../../models/move_tree.dart';
import 'draft_repertoire_writer.dart' show enumerateLines;
import 'repertoire_merge.dart';

/// A position where the draft's *my* move differs from the existing prep.
class DraftConflict {
  const DraftConflict({
    required this.prefixSans,
    required this.draftSan,
    required this.repertoireSans,
  });

  /// SAN moves from the repertoire root to the position (always fully inside
  /// the existing repertoire — a conflict can only arise on covered ground).
  final List<String> prefixSans;

  /// The move the user's games played here.
  final String draftSan;

  /// The answer(s) the repertoire already has here.
  final List<String> repertoireSans;
}

/// What a merge would add, and which decisions it needs first.
class DraftMergePlan {
  DraftMergePlan({required this.newLines, required this.conflicts});

  /// Draft root-to-leaf lines not already contained in the repertoire.
  final List<List<String>> newLines;

  /// Decision points needing a keep-prep / import-alternative choice.
  final List<DraftConflict> conflicts;

  bool get hasConflicts => conflicts.isNotEmpty;
  bool get isEmpty => newLines.isEmpty;
}

/// Whether [repertoire] contains the exact SAN sequence [sans] from its root.
bool repertoireHasPath(MoveTree repertoire, List<String> sans) {
  var siblings = repertoire.roots;
  for (final san in sans) {
    MoveNode? match;
    for (final node in siblings) {
      if (node.san == san) {
        match = node;
        break;
      }
    }
    if (match == null) return false;
    siblings = match.children;
  }
  return true;
}

/// Plan merging [draft] into [repertoire] (the union of every repertoire
/// line — build it with `RepertoireController.buildRepertoireMoveTree`).
/// Neither tree is mutated.
DraftMergePlan planDraftMerge({
  required MoveTree repertoire,
  required MoveTree draft,
  required bool isWhite,
}) {
  final newLines = enumerateLines(
    draft,
  ).where((line) => !repertoireHasPath(repertoire, line)).toList();

  // Conflict detection reuses the tested union walk on a throwaway copy.
  final scratch = repertoire.copyWithFreshIds();
  final result = RepertoireMerge.merge(
    target: scratch,
    draft: draft,
    isWhite: isWhite,
  );
  final conflicts = [
    for (final c in result.conflicts)
      DraftConflict(
        prefixSans: scratch.sanSequenceAt(c.parentPath),
        draftSan: c.draftSan,
        repertoireSans: c.existingSans,
      ),
  ];

  return DraftMergePlan(newLines: newLines, conflicts: conflicts);
}

/// The lines to actually append, given which conflicts the user chose to
/// import ([importAlternatives], by index into [DraftMergePlan.conflicts]).
/// A skipped conflict drops every planned line passing through its draft
/// move; the prefix above a conflict is always existing prep, so nothing
/// else is lost with it.
List<List<String>> applyConflictDecisions(
  DraftMergePlan plan, {
  required Set<int> importAlternatives,
}) {
  final skippedPrefixes = <List<String>>[
    for (var i = 0; i < plan.conflicts.length; i++)
      if (!importAlternatives.contains(i))
        [...plan.conflicts[i].prefixSans, plan.conflicts[i].draftSan],
  ];
  if (skippedPrefixes.isEmpty) return plan.newLines;

  bool startsWith(List<String> line, List<String> prefix) {
    if (line.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (line[i] != prefix[i]) return false;
    }
    return true;
  }

  return plan.newLines
      .where((line) => !skippedPrefixes.any((p) => startsWith(line, p)))
      .toList();
}
