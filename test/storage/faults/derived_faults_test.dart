// Derived data written under a fault at every effect: a search tree kept
// beside its chapter in `.cap-generation/` (GenerationTrees), and a search
// run by its owner (FillGaps), which keeps that tree and its finds
// (`finds.db`, whose atomicity is SQLite's). For contract O10: a failed
// write of derived data never fails the command, the search shows its
// result whatever the disk does, and the retry the owner offers writes it
// once. The tree's own matrix checks that a tree write, whatever stops it,
// never locks the chapter or changes what the user owns. See
// fault_matrix.dart and owner_faults.dart for the families.
@TestOn('linux')
library;

import 'dart:io';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/finds_store.dart';
import 'package:chess_auto_prep/storage/generation_trees.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/engine_jobs.dart';
import 'package:chess_auto_prep/workspace/fill_gaps.dart';
import 'package:chess_auto_prep/workspace/fill_states.dart';
import 'package:chess_auto_prep/workspace/finds.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../chess/generation/scripted_sources.dart';
import '../../support/faulty_disk/contracts.dart';
import '../../support/faulty_disk/fault_matrix.dart';
import '../../support/faulty_disk/owner_faults.dart';
import '../../support/faulty_disk/scenario.dart';
import '../../support/faulty_disk/stores.dart';
import '../../support/profile/profile.dart';
import '../../support/profile/standard_profile.dart';
import '../../support/scripted_engine.dart';
import '../../support/session_fixture.dart';

/// White king and pawn against a bare king: few moves, so a run is small.
const _kingAndPawn = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';

const _tree = '{"version": 4, "tree": {"fen": "$_kingAndPawn"}}';

ChapterRef _main(Profile profile) => ChapterRef.at(profile.document(kidMain));

/// KID's main chapter's tree for one run; a retry keeps the same run.
Future<bool> _keepTree(Stores s) async {
  try {
    await GenerationTrees(
      s.documents.recovery,
    ).keep(_main(s.profile), _tree, runId: 'fault-run');
    return true;
  } on Exception {
    return false;
  }
}

Verdict _kept(bool kept) => kept ? Verdict.committed : Verdict.unknown;

/// Whether a search from the board finds the tree, as Resume looks for it.
Future<String> _latest(Stores s) async {
  final none = await GenerationTrees(
    s.documents.recovery,
  ).startingAt(_main(s.profile), const Fen(_kingAndPawn)).isEmpty;
  return 'tree ${!none}';
}

const _treeScenario = StorageScenario<Stores, bool>(
  name: 'keep a search tree',
  seed: seedStandardProfile,
  open: Stores.open,
  command: _keepTree,
  verdict: _kept,
  retry: _keepTree,
  firstRead: _latest,
  probes: standardProbes,
);

/// A search owner as the workspace wires it, on a scripted engine and a
/// session over a scripted store: only its tree and its finds reach the
/// disk, the tree beside KID's main chapter.
final class _Search {
  _Search(this.stores);

  final Stores stores;
  final pending = PendingWrites();
  late final SessionFixture session;
  late final EngineAnalysis analysis;
  late final Finds finds;
  late final FillGaps fill;
}

const _chapter =
    '''
// Color: White

[Event "Main"]
[Result "*"]
[FEN "$_kingAndPawn"]
[SetUp "1"]

1. e4 Kd8 *
''';

_Search _openSearch(Profile profile) => _Search(Stores.open(profile));

Future<void> _prepareSearch(_Search s) async {
  final profile = s.stores.profile;
  final trees = GenerationTrees(s.stores.documents.recovery);
  s.session = await openSession(_chapter);
  s.analysis = EngineAnalysis(
    s.session.session,
    () async => Started(ScriptedEngine()),
  );
  await s.analysis.enable();
  s.finds = Finds(
    store: () => FindsStore.open(Directory(profile.support)),
    pendingWrites: s.pending,
    clock: () => DateTime.utc(2026, 9, 29, 8),
  );
  s.fill = FillGaps(
    session: s.session.session,
    jobs: EngineJobs(s.analysis),
    documents: s.session.store,
    tools: (_) async => FillReady(
      evaluator: _onlyE4(),
      policy: const ScriptedPolicy({'e8d8': 1}),
      release: () async {},
    ),
    keepTree: (_, tree, {required runId}) =>
        trees.keep(_main(profile), tree, runId: runId),
    pendingWrites: s.pending,
    finds: s.finds,
    clock: () => DateTime.utc(2026, 9, 29, 8),
  );
}

/// An engine for which e4 holds the balance and every other move gives
/// two pawns away (each score is from the side to move), so the search
/// finds an only move at the board and has a position to keep.
ScriptedEvaluator _onlyE4() => ScriptedEvaluator(
  scores: {afterUci(positionOf(_kingAndPawn), 'e2e4').fen: 0},
  fallback: 200,
);

/// A one-ply search from the board; what the Search tab then shows.
Future<String> _search(_Search s) async {
  final refused = await s.fill.start(
    const FillRequest(elo: 2200, depthPlies: 1),
  );
  return refused ?? '${s.fill.state.runtimeType}';
}

/// The Search tab's retry of the tree and of the positions.
Future<void> _retrySearch(_Search s) async {
  await s.fill.retryTree();
  await s.finds.retry();
}

PendingWrites _searchPending(_Search s) => s.pending;

/// How many trees KID's main chapter has, and how many finds are kept.
Future<String> _searchLanded(Profile profile) async {
  final folder = Directory(
    profile.document('repertoires/KID/.cap-generation/Main.pgn'),
  );
  final trees = !folder.existsSync()
      ? 0
      : folder
            .listSync()
            .where((run) => File(p.join(run.path, 'tree.json')).existsSync())
            .length;
  final finds = FindsStore.open(Directory(profile.support)).all().length;
  return 'trees $trees, finds $finds';
}

const _searchSequence = OwnerSequence<_Search>(
  name: 'search and keep what it found',
  seed: seedStandardProfile,
  open: _openSearch,
  prepare: _prepareSearch,
  run: _search,
  pending: _searchPending,
  retry: _retrySearch,
  landed: _searchLanded,
  sameAnswer: true,
);

void main() {
  faultMatrix(
    _treeScenario,
    families: {
      Family.crash,
      Family.crashMidway,
      Family.transient,
      Family.lostAck,
    },
  );
  ownerFaults(_searchSequence);
}
