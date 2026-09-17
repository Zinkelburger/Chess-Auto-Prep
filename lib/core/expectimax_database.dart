/// The expectimax database of one repertoire: the tree its last full build
/// produced plus every on-demand probe since, published as one
/// [GeneratedRepertoire] bundle.
///
/// Owned by [GenerationSessionController], which decides when the bundle
/// changes and tells its listeners; this class holds the bundle, lands
/// probes in it, and moves it to and from disk through a
/// [GenerationArtifacts]. Nothing here notifies anyone.
library;

import 'package:path/path.dart' as p;

import '../chess_core/generation/build_tree_node.dart';
import '../services/generation/expectimax_probe.dart';
import '../services/generation/fen_map.dart';
import '../services/generation/generation_config.dart';
import '../utils/fen_utils.dart';
import '../utils/log.dart';
import 'generated_repertoire.dart';
import '../features/generation/services/generation_artifacts.dart';

/// What [ExpectimaxDatabase.load] did.
enum ExpectimaxLoadOutcome {
  /// A newer load or a build that started meanwhile owns the bundle now;
  /// nothing changed.
  superseded,

  /// The saved tree and probes are the bundle now.
  loaded,

  /// The repertoire had nothing saved; the bundle is empty now.
  empty,
}

/// Where a grafted probe landed and what it added.
typedef ProbeLanding = ({int added, bool mainTreeChanged});

class ExpectimaxDatabase {
  ExpectimaxDatabase({required this.readSaved});

  final Future<SavedExpectimaxDatabase> Function(String) readSaved;

  /// Single source of truth for the generated tree and every artifact
  /// derived from it (FenMap, eval-tree snapshot, trap index).
  GeneratedRepertoire? _current;

  /// Probe trees for the repertoire at [path]: positions the main tree never
  /// reached, built one request at a time. Published through [current] as
  /// part of its FenMap.
  final List<BuildTree> _probes = [];

  /// The main tree of [current] is itself a probe — there was no full build
  /// when the first probe ran, so it stood in as the root of the bundle. A
  /// later full build moves it into [_probes] rather than dropping it.
  bool _mainTreeIsProbe = false;

  /// Repertoire file whose database is loaded, if any.
  String? _path;

  /// Guards [load] against an older load landing after a newer one —
  /// switching repertoires twice while the first file is still being parsed
  /// must show the second repertoire's tree.
  int _loadSeq = 0;

  GeneratedRepertoire? get current => _current;

  String? get path => _path;

  bool get mainTreeIsProbe => _mainTreeIsProbe;

  /// The probe trees as published, main-tree-origin probe excluded.
  List<BuildTree> get probes => List.unmodifiable(_probes);

  /// Whether the database loaded is the one saved beside [repertoireFilePath].
  bool isFor(String repertoireFilePath) {
    final loaded = _path;
    return loaded != null && p.equals(loaded, repertoireFilePath);
  }

  /// Publish [tree] as the main tree of the bundle.
  ///
  /// [probes] replaces the probe list when given; otherwise the probes
  /// already loaded stay. A main tree that was itself a probe (see
  /// [mainTreeIsProbe]) is demoted to the probe list rather than lost.
  /// Set [mainTreeChanged] to false only when the main tree is unchanged
  /// and just the probe set changed, so its derived artifacts can be reused.
  void publish(
    BuildTree tree, {
    List<BuildTree>? probes,
    bool mainIsProbe = false,
    bool mainTreeChanged = true,
  }) {
    if (probes != null) {
      _probes
        ..clear()
        ..addAll(probes);
    }
    final previous = _current?.tree;
    if (_mainTreeIsProbe &&
        previous != null &&
        !identical(previous, tree) &&
        !_probes.contains(previous)) {
      _probes.insert(0, previous);
    }
    _mainTreeIsProbe = mainIsProbe;
    final config = _configOf(tree);
    final playAsWhite =
        config?.playAsWhite ??
        tree.configSnapshot['play_as_white'] as bool? ??
        tree.root.isWhiteToMove;
    // A probe landing publishes the build's own tree unchanged with one more
    // probe. Only the transposition map spans the database, so that case
    // reuses the snapshot, the metric cache and the trap index instead of
    // recomputing three identical answers over the whole tree.
    final previousBundle = _current;
    if (!mainTreeChanged &&
        previousBundle != null &&
        identical(previousBundle.tree, tree) &&
        previousBundle.playAsWhite == playAsWhite) {
      _current = previousBundle.withProbes(_probes);
    } else {
      _current = GeneratedRepertoire.fromTree(
        tree,
        playAsWhite: playAsWhite,
        config: config,
        probes: _probes,
      );
    }
  }

  /// Drop the published tree ahead of a full build, keeping the probes: the
  /// build replaces the tree, and the probes rejoin it when it is published.
  void dropTree() {
    final previous = _current?.tree;
    if (_mainTreeIsProbe && previous != null && !_probes.contains(previous)) {
      _probes.insert(0, previous);
    }
    _current = null;
    _mainTreeIsProbe = false;
    _loadSeq++;
  }

  /// Drop the bundle. A load still in flight is superseded.
  void clear() {
    _current = null;
    _probes.clear();
    _mainTreeIsProbe = false;
    _path = null;
    _loadSeq++;
  }

  /// Replace the bundle with what is saved beside [repertoireFilePath].
  ///
  /// The read runs off the UI isolate; the result is applied only when no
  /// newer load or [clear] happened meanwhile and [canApply] still holds
  /// (the owner uses it to refuse while a build owns the bundle or after
  /// disposal).
  Future<ExpectimaxLoadOutcome> load(
    String repertoireFilePath, {
    required bool Function() canApply,
  }) async {
    final seq = ++_loadSeq;
    final saved = await readSaved(repertoireFilePath);
    if (seq != _loadSeq || !canApply()) {
      return ExpectimaxLoadOutcome.superseded;
    }
    // Loading replaces the whole database, including a previous probe-origin
    // main tree. It must not be demoted into the newly loaded repertoire.
    clear();
    _path = repertoireFilePath;
    final tree = saved.tree;
    if (tree != null) {
      tree.sortAllChildren();
      publish(tree, probes: saved.probes);
      return ExpectimaxLoadOutcome.loaded;
    }
    if (saved.probes.isNotEmpty) {
      // No full build yet: the first probe stands in as the main tree.
      publish(
        saved.probes.first,
        probes: saved.probes.sublist(1),
        mainIsProbe: true,
      );
      return ExpectimaxLoadOutcome.loaded;
    }
    _current = null;
    _probes.clear();
    _mainTreeIsProbe = false;
    return ExpectimaxLoadOutcome.empty;
  }

  /// Keep a bounded-database probe as a tree of its own, replacing any
  /// earlier bounded probe rooted at the same position.
  ///
  /// Each such probe has its own root history, horizon and truncated policy;
  /// mixing it into a Pure tree can corrupt normalized chance nodes.
  void addBoundedProbe(
    BuildTree probe, {
    required TreeBuildConfig config,
    required List<String> prefix,
  }) {
    probe.startMoves = prefix.join(' ');
    rescoreTree(probe, config, FenMap()..populate(probe.root));
    final bundle = _current;
    if (bundle == null) {
      publish(probe, probes: const [], mainIsProbe: true);
      return;
    }
    final probeRoot = canonicalizeFen(probe.root.fen);
    final retained = _probes.where(
      (old) =>
          old.configSnapshot['bounded_database'] != true ||
          canonicalizeFen(old.root.fen) != probeRoot,
    );
    publish(
      bundle.tree,
      probes: [...retained, probe],
      mainIsProbe: _mainTreeIsProbe,
      mainTreeChanged: false,
    );
  }

  /// Graft [probe] where the database already holds its root, or keep it as
  /// a tree of its own; re-score the tree it landed in and republish.
  ProbeLanding landProbe(
    BuildTree probe, {
    required TreeBuildConfig config,
    required List<String> prefix,
    required String repertoireFilePath,
  }) {
    final bundle = _current;
    final existing = <BuildTree>[if (bundle != null) ...bundle.allTrees];

    final at = bundle?.fenMap.getCanonical(probe.root.fen);
    final host = at == null ? null : treeOwning(at, existing);
    final int added;
    final BuildTree landed;
    if (at != null && host != null) {
      added = graftProbe(
        host: host,
        at: at,
        probe: probe,
        playAsWhite: config.playAsWhite,
      );
      landed = host;
    } else {
      added = probe.totalNodes;
      landed = probe;
      probe.startMoves = prefix.join(' ');
    }
    final landedIsProbe = identical(landed, probe);

    // Re-score with a map over the whole database so transposition leaves
    // resolve across trees.
    final scoringConfig = landedIsProbe ? config : (bundle?.config ?? config);
    final fenMap = FenMap();
    for (final tree in [...existing, if (landedIsProbe) probe]) {
      fenMap.populate(tree.root);
    }
    rescoreTree(landed, scoringConfig, fenMap);

    _path = repertoireFilePath;
    if (bundle == null) {
      publish(probe, probes: const [], mainIsProbe: true);
    } else {
      publish(
        bundle.tree,
        probes: [..._probes, if (landedIsProbe) probe],
        mainIsProbe: _mainTreeIsProbe,
        mainTreeChanged: identical(landed, bundle.tree),
      );
    }
    return (
      added: added,
      mainTreeChanged: bundle != null && identical(landed, bundle.tree),
    );
  }

  /// Record an engine continuation for the position at [probe]'s root.
  ///
  /// A PV is evidence about one position, never extra policy branches:
  /// grafting its replies into a searched chance node would corrupt Maia
  /// mass. So when the database already holds the position, only its eval
  /// and PV are updated; otherwise the single-node [probe] joins as a tree
  /// of its own. Returns whether the build's own tree changed.
  bool recordEnginePv(BuildTree probe) {
    final bundle = _current;
    final root = probe.root;
    final at = bundle?.fenMap.getCanonical(root.fen);
    final host = at == null ? null : treeOwning(at, bundle!.allTrees);
    if (host != null && at != null) {
      at.engineEvalCp = root.engineEvalCp;
      at.enginePv = root.enginePv;
      publish(
        bundle!.tree,
        probes: List.of(_probes),
        mainIsProbe: _mainTreeIsProbe,
        mainTreeChanged: identical(host, bundle.tree),
      );
      return identical(host, bundle.tree);
    }
    if (bundle == null) {
      publish(probe, probes: const [], mainIsProbe: true);
    } else {
      publish(
        bundle.tree,
        probes: [..._probes, probe],
        mainIsProbe: _mainTreeIsProbe,
        mainTreeChanged: false,
      );
    }
    return false;
  }

  /// The config a saved tree was built with, or null for a legacy tree
  /// without a snapshot (or one whose snapshot no longer parses).
  static TreeBuildConfig? _configOf(BuildTree tree) {
    if (tree.configSnapshot.isEmpty) return null;
    try {
      return TreeBuildConfig.fromJson(
        tree.configSnapshot,
        startFen: tree.root.fen,
      );
    } catch (e) {
      log.w(
        'config snapshot parse failed',
        name: 'ExpectimaxDatabase',
        error: e,
      );
      return null;
    }
  }
}

/// A one-node tree carrying the engine's verdict on [fen]: its eval (White-
/// relative centipawns) and principal variation, rooted after [startMoves].
BuildTree enginePvProbe({
  required String fen,
  required int evalCpWhite,
  required List<String> pv,
  required List<String> startMoves,
  required TreeBuildConfig config,
}) {
  final root = BuildTreeNode(
    fen: fen,
    moveSan: '',
    moveUci: '',
    ply: 0,
    isWhiteToMove: isWhiteToMove(fen),
    nodeId: 0,
  );
  root.engineEvalCp = root.isWhiteToMove ? evalCpWhite : -evalCpWhite;
  root.enginePv = List.unmodifiable(pv);
  return BuildTree(
    root: root,
    startMoves: startMoves.join(' '),
    configSnapshot: config.toJson(),
  )..computeMetadata();
}
