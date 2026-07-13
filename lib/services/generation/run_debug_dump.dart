/// Debug artifacts for repertoire-builder runs.
///
/// Every generation run — successful or failed — writes a self-contained
/// folder under `<documents>/repertoire_debug_runs/run_<timestamp>/`:
///
///   run_log.txt         — timestamped build log (every `[TreeBuild]` message,
///                         including eval-source errors with FEN context)
///   summary.json        — config snapshot, BuildStats, phase-2 counts, and
///                         the error message when the run failed
///   pruned_too_low.json — lines flagged eval-too-low and deleted post-build
///                         (these never appear in the tree itself)
///   tree.json           — final serialized tree (v4 format, same as the
///                         `{repertoire}_tree.json` artifact)
///
/// Only the newest [keepRuns] folders are kept; older ones are deleted.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../storage/app_paths.dart';
import 'tree_prune.dart';

/// In-memory build log: buffers every message for the end-of-run dump and
/// mirrors it to the debug console. Unlike bare `debugPrint`, the buffer is
/// populated in release builds too.
class RunDebugLog {
  final List<String> _lines = [];

  void add(String msg) {
    _lines.add('${DateTime.now().toIso8601String()} $msg');
    if (kDebugMode) debugPrint(msg);
  }

  void clear() => _lines.clear();

  String dump() => _lines.join('\n');
}

const String debugRunsDirectoryName = 'repertoire_debug_runs';
const int keepRuns = 10;

/// Write one debug-run folder. Best-effort: failures are logged and swallowed
/// so a dump problem can never break the run itself. Returns the folder path,
/// or null when the dump could not be written.
Future<String?> writeRunDebugDump({
  required RunDebugLog log,
  Map<String, dynamic>? config,
  Map<String, dynamic>? stats,
  Map<String, dynamic>? summaryExtras,
  List<PrunedLine> prunedTooLow = const [],
  String? treeJson,
  String? error,
}) async {
  try {
    final docs = await AppPaths.documentsDirectory();
    final baseDir = Directory(p.join(docs.path, debugRunsDirectoryName));
    await baseDir.create(recursive: true);

    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    var runDir = Directory(p.join(baseDir.path, 'run_$stamp'));
    if (await runDir.exists()) {
      runDir = Directory('${runDir.path}_${now.millisecond}');
    }
    await runDir.create();

    final summary = <String, dynamic>{
      'timestamp': now.toIso8601String(),
      'outcome': error == null ? 'completed' : 'failed',
      'error': ?error,
      'pruned_too_low_lines': prunedTooLow.length,
      ...?summaryExtras,
      'config': ?config,
      'stats': ?stats,
    };

    const encoder = JsonEncoder.withIndent('  ');
    await File(p.join(runDir.path, 'summary.json'))
        .writeAsString(encoder.convert(summary));
    await File(p.join(runDir.path, 'run_log.txt')).writeAsString(log.dump());
    await File(p.join(runDir.path, 'pruned_too_low.json')).writeAsString(
        encoder.convert(prunedTooLow.map((l) => l.toJson()).toList()));
    if (treeJson != null) {
      await File(p.join(runDir.path, 'tree.json')).writeAsString(treeJson);
    }

    await _rotateOldRuns(baseDir);
    debugPrint('[RunDebugDump] wrote ${runDir.path}');
    return runDir.path;
  } catch (e) {
    debugPrint('[RunDebugDump] failed: $e');
    return null;
  }
}

Future<void> _rotateOldRuns(Directory baseDir) async {
  final runs = <Directory>[];
  await for (final entry in baseDir.list(followLinks: false)) {
    if (entry is Directory && p.basename(entry.path).startsWith('run_')) {
      runs.add(entry);
    }
  }
  if (runs.length <= keepRuns) return;
  // Timestamped names sort chronologically.
  runs.sort((a, b) => a.path.compareTo(b.path));
  for (final old in runs.take(runs.length - keepRuns)) {
    try {
      await old.delete(recursive: true);
    } catch (_) {
      // Rotation is best-effort.
    }
  }
}
