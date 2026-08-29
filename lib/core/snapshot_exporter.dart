/// Snapshot export — write the lines found so far to a **new** repertoire
/// file while the generation run continues.
///
/// Owned by [GenerationSessionController]. Unverified exports serialize the
/// tree and run every phase in a background isolate so exploration keeps
/// going. Verified exports pause the shared engine pool for the check, then
/// resume.
library;

import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../services/engine/stockfish_pool.dart';
import '../services/generation/eca_calculator.dart';
import '../services/generation/fen_map.dart';
import '../services/generation/generation_config.dart';
import '../services/generation/repertoire_verifier.dart';
import '../services/generation/snapshot_export.dart';
import '../services/generation/tree_serialization.dart';
import '../services/storage/storage_factory.dart';
import '../services/tree_build_service.dart';
import 'generation_progress.dart';
import 'generation_session_types.dart';

class SnapshotExporter {
  SnapshotExporter({
    required this._notify,
    required this._isGenerating,
    required this._isPaused,
    required this._cancelRequested,
    required this._activeRequest,
    required this._activeConfig,
    required this._startMoveSequence,
    required this._buildService,
    required this._progress,
  });

  final void Function() _notify;
  final bool Function() _isGenerating;
  final bool Function() _isPaused;
  final bool Function() _cancelRequested;
  final GenerationRequest? Function() _activeRequest;
  final TreeBuildConfig? Function() _activeConfig;
  final List<String> Function() _startMoveSequence;
  final TreeBuildService Function() _buildService;
  final GenerationProgress Function() _progress;

  bool _exporting = false;

  /// Live status of an in-flight snapshot export, shown in the Jobs panel.
  /// Null when no snapshot is running.
  String? status;

  bool get isExporting => _exporting;

  /// Suggested repertoire name for a snapshot export at the current depth.
  String nameSuggestion() {
    final path = _activeRequest()?.repertoireFilePath;
    final depth = _progress().depth;
    final base = (path == null || path.isEmpty)
        ? 'Generated'
        : p.basenameWithoutExtension(path);
    return '$base d$depth snapshot';
  }

  /// Export the lines the build has found so far to a **new** repertoire
  /// file named [repertoireName], without ending the run.
  ///
  /// Returns (success, user-facing message).
  Future<(bool, String)> export({
    required String repertoireName,
    required bool verify,
  }) async {
    final progress = _progress();
    if (!_isGenerating() ||
        _cancelRequested() ||
        progress.phase != GenerationPhase.buildingTree) {
      return (false, 'No active build to export from.');
    }
    if (_exporting) {
      return (false, 'A snapshot export is already running.');
    }
    final request = _activeRequest();
    final config = _activeConfig();
    final tree = _buildService().currentTree;
    if (request == null || config == null || tree == null) {
      return (false, 'Build state unavailable — try again in a moment.');
    }

    final name = repertoireName.trim();
    if (name.isEmpty) return (false, 'Please enter a repertoire name.');
    final storage = StorageFactory.instance;
    final targetPath = await storage.repertoireFilePath(name);
    if (await storage.fileExists(targetPath)) {
      return (false, 'A repertoire named "$name" already exists.');
    }

    final depth = progress.depth;
    final doVerify = verify && config.needsStockfish;
    // Verification shares the engine pool with the build, so exploration
    // pauses for its duration. Unverified exports never touch the run.
    final pausedForVerify = doVerify && !_isPaused();
    final buildService = _buildService();

    _exporting = true;
    _setStatus('Snapshot: preparing (depth $depth)…');
    try {
      if (pausedForVerify) buildService.pauseBuild();

      // Synchronous, so atomic w.r.t. the async build loop — the copy is a
      // consistent point-in-time snapshot even while BFS continues.
      final exportRequest = SnapshotExportRequest(
        treeJson: serializeTreeJson(tree),
        configJson: Map<String, dynamic>.from(config.toJson()),
        prefix: List<String>.from(_startMoveSequence()),
        repertoireStartFen: request.repertoireStartFen,
        stopAfterSelection: doVerify,
      );

      _setStatus('Snapshot: computing lines (depth $depth)…');
      final result = await Isolate.run(() => runSnapshotExport(exportRequest));

      var pgnEntries = result.pgnEntries;
      String verifyNote = 'unverified';
      if (doVerify) {
        final snapTree = deserializeTree(result.selectedTreeJson!);
        final fenMap = FenMap()..populate(snapTree.root);
        final ecaCalc = ExpectimaxCalculator(config: config, fenMap: fenMap);
        var verified = false;
        try {
          _setStatus(
            'Snapshot: verifying (depth ${config.resolvedVerifyDepth})…',
          );
          if (StockfishPool.instance.workerCount == 0) {
            await StockfishPool.instance.prepareForTreeBuild(
              config.resolvedEngineThreads,
            );
          }
          final verifier = RepertoireVerifier(config: config);
          final report = await verifier.verify(
            snapTree,
            fenMap: fenMap,
            ecaCalc: ecaCalc,
            isCancelled: _cancelRequested,
            onStatus: (s) => _setStatus('Snapshot: $s'),
          );
          verified = report.completed;
        } catch (e) {
          // Verification is best-effort; export the unverified selection.
          debugPrint('[Snapshot] verification failed: $e');
        }
        // Engine is free again — resume exploration before the extraction
        // walk, which only reads the snapshot copy.
        if (pausedForVerify && !_isPaused()) buildService.resumeBuild();
        _setStatus('Snapshot: extracting lines…');
        pgnEntries = extractSnapshotLines(
          tree: snapTree,
          config: config,
          fenMap: fenMap,
          prefix: List<String>.from(_startMoveSequence()),
          repertoireStartFen: request.repertoireStartFen,
        );
        verifyNote = verified
            ? 'verified at depth ${config.resolvedVerifyDepth}'
            : 'verification incomplete';
      }

      if (pgnEntries.isEmpty) {
        return (
          false,
          'Snapshot produced no lines yet — let the build explore deeper.',
        );
      }

      final header =
          '// $name Repertoire\n'
          '// Color: ${config.playAsWhite ? 'White' : 'Black'}\n'
          '// Created on ${DateTime.now().toString().split('.')[0]}\n'
          '// Snapshot at depth $depth ($verifyNote) from an in-progress '
          'generation run.\n';
      final buffer = StringBuffer(header);
      for (final pgn in pgnEntries) {
        buffer.writeln();
        buffer.writeln(pgn);
      }
      await storage.writeFile(targetPath, buffer.toString());
      return (
        true,
        'Exported ${pgnEntries.length} lines to "$name" ($verifyNote).',
      );
    } catch (e) {
      debugPrint('[Snapshot] export failed: $e');
      return (false, 'Snapshot export failed: $e');
    } finally {
      if (pausedForVerify && !_isPaused()) buildService.resumeBuild();
      _exporting = false;
      status = null;
      _notify();
    }
  }

  void _setStatus(String next) {
    status = next;
    _notify();
  }
}
