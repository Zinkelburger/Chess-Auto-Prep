// Laws of the saved-tree format over trees a real search builds: what is
// written reads back as the same tree, a second save changes no byte, what
// the reader must not believe or does not know is read past, damage is an
// answer rather than an exception. Search roots are small and horizons three plies or less, so a case
// takes milliseconds.
import 'dart:convert';

import 'package:chess_auto_prep/chess/generation/search_config.dart';
import 'package:chess_auto_prep/chess/generation/search_node.dart';
import 'package:chess_auto_prep/chess/generation/tree_wire_v4.dart';
import 'package:chess_auto_prep/chess/generation/tree_wire_v4_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/gen/json_gen.dart';
import '../../support/gen/pgn_mutations.dart' show replaceCharacter;
import '../../support/gen/tree_gen.dart';
import '../../support/props.dart';
import 'tree_sameness.dart';

/// Enough cases to reach every root, leaf kind and setting; a soak raises it
/// with `CAP_PROP_RUNS`.
const _runs = 60;

/// Node fields every reader recomputes from the tree rather than believes.
const _derivedNodeFields = [
  'value_lower',
  'value_upper',
  'cumulative_probability',
  'expectimax_value',
  'local_cpl',
  'id',
  'depth',
  'is_repertoire_move',
];

/// Document fields counted from the tree.
const _derivedDocumentFields = ['total_nodes', 'max_depth'];

/// A saved search and what it was saved from.
typedef _Saved = ({
  SearchNode tree,
  SearchConfig config,
  bool complete,
  String text,
});

Future<_Saved?> _saved(SearchSpec spec) async {
  final grown = await grownSearch(spec);
  if (grown == null) return null;
  return (
    tree: grown.tree,
    config: spec.config,
    complete: grown.complete,
    text: encodeTreeV4(grown.tree, spec.config, complete: grown.complete),
  );
}

TreeDecoded _decoded(String text) {
  final read = decodeTreeV4(text);
  if (read is! TreeDecoded) fail('expected a tree, got $read');
  return read;
}

String _resaved(TreeDecoded read) =>
    encodeTreeV4(read.root, read.config, complete: read.complete);

void main() {
  forAllAsync(
    'a saved tree reads back as the same tree, settings and all',
    searchSpecs,
    (spec) async {
      final saved = await _saved(spec);
      if (saved == null) return;
      final read = _decoded(saved.text);
      expectSameTree(read.root, saved.tree);
      expect(read.complete, saved.complete);
      final (want, got) = (saved.config, read.config);
      expect(got.side, want.side);
      expect(got.horizonPlies, want.horizonPlies);
      expect(got.lossLimitCp, want.lossLimitCp);
      expect(got.nodeBudget, want.nodeBudget);
      expect(got.maxOurMoves, want.maxOurMoves);
      expect(got.rootMoves, want.maxOurMoves == null ? null : want.rootMoves);
      expect(got.replyFloor, want.replyFloor);
    },
    runs: _runs,
  );

  // Seed 806485: the reader divided shares that already made a whole move
  // by their sum, so …0756302521 was saved again as …075630252103.
  forAllAsync(
    'saving what was read changes no byte',
    searchSpecs,
    (spec) async {
      final saved = await _saved(spec);
      if (saved == null) return;
      expect(_resaved(_decoded(saved.text)), saved.text);
    },
    runs: _runs,
    regressionSeeds: const [806485],
  );

  forAllAsync(
    'unknown fields and changed derived fields read as the same tree',
    searchSpecs,
    (spec) async {
      final saved = await _saved(spec);
      if (saved == null) return;
      final rand = Rand(spec.seed);
      final document = _withDerivedChanged(jsonDecode(saved.text), rand);
      final text = jsonEncode(withUnknownFields(document, rand));
      final read = _decoded(text);
      expectSameTree(read.root, saved.tree);
      expect(_resaved(read), _resaved(_decoded(saved.text)));
    },
    runs: _runs,
  );

  forAllAsync(
    'a document damaged as text is refused or read, never an exception, and '
    'what is read can be saved',
    searchSpecs,
    (spec) async {
      for (final read in await _damagedReads(spec, asJson: false)) {
        decodeTreeV4(_resaved(read));
      }
    },
    runs: _runs,
  );

  // Seed 806552: a `v2_reply_floor` saved as anything but a number threw a
  // TypeError out of decodeTreeV4.
  forAllAsync(
    'a document damaged as JSON is refused or read, never an exception, and '
    'what is read can be saved',
    searchSpecs,
    (spec) async {
      for (final read in await _damagedReads(spec, asJson: true)) {
        decodeTreeV4(_resaved(read));
      }
    },
    runs: _runs,
    regressionSeeds: const [806552],
  );

  // Seed 806501: the reader took a node's `is_white_to_move` over the side
  // to move in its `fen`, and took a `fen` of "42", so the node was read as
  // the wrong side's and the tree read back at another value.
  forAllAsync(
    'what is read from a damaged document saves and reads back as itself',
    searchSpecs,
    (spec) async {
      for (final asJson in [false, true]) {
        for (final read in await _damagedReads(spec, asJson: asJson)) {
          expectSameTree(_decoded(_resaved(read)).root, read.root);
        }
      }
    },
    runs: _runs,
    regressionSeeds: const [806501],
  );
}

/// [json] with every field in [_derivedNodeFields] and
/// [_derivedDocumentFields] given a value that is not the tree's.
Object? _withDerivedChanged(Object? json, Rand rand) {
  var document = json;
  for (final path in jsonPaths(json)) {
    final key = path.isEmpty ? null : path.last;
    final derived = path.length == 1
        ? _derivedDocumentFields.contains(key)
        : path.length > 1 && _derivedNodeFields.contains(key);
    if (!derived || !rand.chance(70)) continue;
    document = atPath(
      document,
      path,
      (_) => rand.pick(const [0, 1, -3, 0.25, 7.5, 1e9, true]),
    );
  }
  return document;
}

/// The trees read from eight damaged copies of [spec]'s saved tree, damaged
/// [asJson] or as text. Reading them must not throw.
Future<List<TreeDecoded>> _damagedReads(
  SearchSpec spec, {
  required bool asJson,
}) async {
  final saved = await _saved(spec);
  if (saved == null) return const [];
  final rand = Rand(spec.seed);
  return [
    for (var i = 0; i < 8; i++)
      if (decodeTreeV4(
            asJson
                ? jsonEncode(mutateJson(jsonDecode(saved.text), rand).json)
                : _damagedText(saved.text, rand),
          )
          case final TreeDecoded read)
        read,
  ];
}

/// [text] cut short or with a character replaced.
String _damagedText(String text, Rand rand) => rand.nextBool()
    ? text.substring(0, rand.nextInt(text.length))
    : replaceCharacter(text, rand);
