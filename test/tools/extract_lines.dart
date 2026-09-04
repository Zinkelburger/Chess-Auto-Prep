/// Re-extract repertoire lines from a tree that has already been built.
///
/// A generation run writes two things beside each chapter: the chapter's
/// `.pgn` (the lines it chose) and `<chapter>_tree.json` (everything it
/// explored, ~7.6k nodes for a ten-ply Benko run). Only the first is what
/// you read in the builder — but the second is where the lines *come from*,
/// and turning one into the other costs no engine, no network, and a few
/// seconds. So a chapter that came out thin does not need the hours back; it
/// needs this.
///
/// Runs exactly the pipeline's own post-build phases via [runSnapshotExport]
/// — ease, expectimax, trap scores, selection, extraction, PGN formatting —
/// so the lines it writes are the lines the build would have written under
/// the settings you give it here.
///
/// Deliberately has no `_test` suffix, so a bare `flutter test` (and CI)
/// never picks it up.
///
///   flutter test test/tools/extract_lines.dart \
///     --dart-define=TREE="$HOME/Documents/repertoires/e6 Benko/Main_tree.json" \
///     --dart-define=OUT="$HOME/Documents/repertoires/e6 Benko/Deep Lines.pgn" \
///     --dart-define=NAME="Deep Lines" \
///     --dart-define=LINES=40
///
/// Writing into a chapter that already exists keeps that chapter's identity:
/// its `// ` header block is carried over verbatim, so the name, colour,
/// created date and any `// Root:` survive and only the games are replaced.
/// The previous contents are saved beside it as `<chapter>.pgn.bak` first —
/// this replaces a file the user may have edited by hand.
///
/// TREE  path to a `*_tree.json` written by a build (required)
/// OUT   chapter `.pgn` to write; defaults beside TREE (required in practice)
/// NAME  chapter name in the `// ` header; ignored when OUT already exists,
///       otherwise defaults to OUT's basename
/// LINES target line count; -1 (default) keeps the build's own setting, and
///       0 means what the form means by it — no pruning at all
library;

import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/services/engine/stockfish_pool.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/services/generation/engine_tail.dart';
import 'package:chess_auto_prep/services/generation/fen_map.dart';
import 'package:chess_auto_prep/services/generation/eca_calculator.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:chess_auto_prep/services/generation/line_pruner.dart';
import 'package:chess_auto_prep/services/generation/repertoire_selector.dart';
import 'package:chess_auto_prep/services/generation/tree_ease.dart';
import 'package:chess_auto_prep/services/generation/tree_my_ease.dart';
import 'package:chess_auto_prep/services/generation/tree_serialization.dart';
import 'package:chess_auto_prep/services/generation/snapshot_export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;

const _treePath = String.fromEnvironment('TREE');
const _outPath = String.fromEnvironment('OUT');
const _name = String.fromEnvironment('NAME');

/// How many of the ranked lines to keep. 0 (the default) keeps every line
/// that teaches something new, which is what a build now exports.
const _lineTarget = int.fromEnvironment('LINES');

/// Keep however many lines cover this share of what you will face, as a
/// percentage. 0 (the default) is off. [_lineTarget] wins when both are set.
const _coverage = int.fromEnvironment('COVERAGE');

/// Points path_provider at the real app support directory, which is where
/// the Stockfish binary lives. Without this the pool cannot find it and the
/// engine tail pass hangs at startup.
class _RealPaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _RealPaths(this.support);
  final String support;
  @override
  Future<String?> getApplicationDocumentsPath() async => support;
  @override
  Future<String?> getApplicationSupportPath() async => support;
}

void main() {
  test('extract lines from a built tree', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    PathProviderPlatform.instance = _RealPaths(
      p.join(
        Platform.environment['HOME']!,
        '.local',
        'share',
        'com.example.chess_auto_prep',
      ),
    );

    expect(_treePath, isNotEmpty, reason: 'pass --dart-define=TREE=…');
    expect(_outPath, isNotEmpty, reason: 'pass --dart-define=OUT=…');

    final treeFile = File(_treePath);
    expect(
      treeFile.existsSync(),
      isTrue,
      reason: 'no tree at $_treePath — run a build first',
    );

    final treeJson = await treeFile.readAsString();
    final data = jsonDecode(treeJson) as Map<String, dynamic>;
    final config = Map<String, dynamic>.from(
      data['config'] as Map<String, dynamic>? ?? const {},
    );
    // The build's own prefix: the moves played before the tree's root, which
    // every extracted line has to be written back on top of.
    final prefix = (data['start_moves'] as String? ?? '')
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();

    final playAsWhite = config['play_as_white'] as bool? ?? true;

    stdout.writeln(
      '[extract] ${data['total_nodes']} nodes, max depth '
      '${data['max_depth']}, prefix ${prefix.join(' ')}',
    );

    // Engine continuations for the lines that stopped at the ply cap.
    // Needs Stockfish, so it happens here rather than inside the pure
    // export; the export takes the finished map.
    final tails = await _engineTails(treeJson, config, prefix);

    final sw = Stopwatch()..start();
    final result = runSnapshotExport(
      SnapshotExportRequest(
        treeJson: data,
        configJson: config,
        prefix: prefix,
        repertoireStartFen: kStandardStartFen,
        engineTails: tails,
      ),
    );
    stdout.writeln(
      '[extract] selected ${result.selectedCount} nodes → '
      '${result.pgnEntries.length} lines in ${sw.elapsedMilliseconds}ms',
    );

    expect(
      result.pgnEntries,
      isNotEmpty,
      reason:
          'selection kept nothing — the tree is too shallow, or the config\'s '
          'eval window rejects every continuation',
    );

    final out = File(_outPath);
    final header = await _headerFor(out, playAsWhite: playAsWhite);

    final buffer = StringBuffer(header)
      ..writeln(
        '// Re-extracted from ${p.basename(_treePath)} '
        '(${data['total_nodes']} nodes) on '
        '${DateTime.now().toString().split('.')[0]} — no rebuild.',
      );
    for (final pgn in result.pgnEntries) {
      buffer
        ..writeln()
        ..writeln(pgn);
    }
    await out.writeAsString(buffer.toString());
    stdout.writeln(
      '[extract] wrote ${result.pgnEntries.length} lines to $_outPath',
    );
  }, timeout: const Timeout(Duration(minutes: 10)));
}

/// The `// ` comment block to put at the top of the chapter.
///
/// For a chapter that already exists that is whatever it already had, minus
/// any re-extraction note from a previous run — the name, colour and
/// `// Root:` are the chapter's identity and this tool has no business
/// rewriting them. The old file is backed up before it is replaced, because
/// replacing it discards lines the user may have authored by hand.
Future<String> _headerFor(File out, {required bool playAsWhite}) async {
  if (!out.existsSync()) {
    final name = _name.isNotEmpty
        ? _name
        : p.basenameWithoutExtension(out.path);
    return '// $name\n'
        '// Color: ${playAsWhite ? 'White' : 'Black'}\n'
        '// Created on ${DateTime.now().toString().split('.')[0]}\n';
  }

  final existing = await out.readAsString();
  await File('${out.path}.bak').writeAsString(existing);
  stdout.writeln('[extract] backed up ${p.basename(out.path)} -> .pgn.bak');

  final kept = <String>[];
  for (final line in existing.split('\n')) {
    final trimmed = line.trim();
    // The header block runs until the first game; a blank line inside it is
    // spacing, so keep scanning rather than stopping at the first one.
    if (trimmed.startsWith('[Event ')) break;
    if (!trimmed.startsWith('//')) continue;
    if (trimmed.startsWith('// Re-extracted from')) continue;
    kept.add(trimmed);
  }
  return kept.isEmpty
      ? '// ${p.basenameWithoutExtension(out.path)}\n'
            '// Color: ${playAsWhite ? 'White' : 'Black'}\n'
      : '${kept.join('\n')}\n';
}

/// Runs the tail pass over the lines this tree would export.
///
/// Extraction is cheap and pure, so it is simply run twice: once here to
/// learn which leaf positions the export will end on, and once inside
/// [runSnapshotExport] for real. That costs a few hundred milliseconds and
/// keeps the engine out of the pure path.
///
/// Returns an empty map when TAIL=0 or Stockfish is unavailable — a missing
/// tail costs depth in the PGN, never the export.
Future<Map<String, EngineTail>> _engineTails(
  String treeJson,
  Map<String, dynamic> configJson,
  List<String> prefix,
) async {
  final tree = deserializeTree(treeJson);
  final config = TreeBuildConfig.fromJson(
    configJson,
    startFen: tree.root.fen,
  ).anchoredToRoot(tree.root);
  if (config.engineTailPlies <= 0) return const {};

  // Selection first, then pruning, so the engine is only asked about the
  // lines that will actually be exported. Skipping this asked it about all
  // ~2000 raw extractions instead of the ~300 survivors.
  calculateTreeEase(tree);
  final fenMap = FenMap()..populate(tree.root);
  final eca = ExpectimaxCalculator(config: config, fenMap: fenMap);
  eca.calculate(tree);
  eca.computeTrapScores(tree.root);
  calculateMyEase(tree, playAsWhite: config.playAsWhite);
  RepertoireSelector(config: config, ecaCalc: eca, fenMap: fenMap).select(tree);
  tree.sortAllChildren();
  tree.computeMetadata();

  final slice = LinePruner.rank(
    LineExtractor(config: config, fenMap: fenMap).extract(tree),
  );
  final lines = _lineTarget > 0
      ? slice.take(_lineTarget)
      : _coverage > 0
      ? slice.take(slice.countForCoverage(_coverage / 100.0))
      : slice.all;

  try {
    await StockfishPool.instance.prepareForTreeBuild(
      config.resolvedEngineThreads,
    );
  } catch (e) {
    stdout.writeln('[extract] no engine ($e) — skipping tails');
    return const {};
  }
  final sw = Stopwatch()..start();
  final tails = await computeEngineTails(
    lines: lines,
    config: config,
    pool: StockfishPool.instance,
    onProgress: (done, total) {
      if (done == 1 || done % 50 == 0 || done == total) {
        stdout.writeln('[extract] tails $done/$total');
      }
    },
  );
  stdout.writeln(
    '[extract] ${tails.length} engine tails at depth '
    '${config.resolvedEngineTailDepth} in ${sw.elapsedMilliseconds}ms',
  );
  return tails;
}
