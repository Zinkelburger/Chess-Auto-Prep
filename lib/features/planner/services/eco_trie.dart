/// The ECO book as a move trie, so the planner can ask "is this position a
/// fork worth a question?" from data instead of a curated list.
///
/// Every named line in `assets/data/openings/[a-e].tsv` is a SAN sequence.
/// Laid over each other they form a trie whose shape *is* the opening
/// theory's structure: where many named lines pass through one position and
/// then diverge, that position is a tabiya. The score below quantifies it:
///
///     tabiya(node) = entriesBelow(node) × distinctChildren(node)
///
/// so `1.d4 d5 2.c4` (hundreds of lines below, five named replies) scores
/// high and a forced sequence inside one variation scores ~1. The planner
/// asks at high-scoring nodes where the user is to move, and stops descending
/// when the score falls under a threshold — the book has run out and the
/// engine takes over.
///
/// The trie is keyed by SAN, not FEN, so transpositions are separate paths.
/// That is fine for asking questions along a path; the opening namer that
/// labels chapters is FEN-based and handles transpositions.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../../utils/san_token_utils.dart';

/// One node of the trie: the position reached by its SAN path.
class EcoNode {
  EcoNode({required this.san, required this.ply});

  /// SAN of the move that reached this node ('' at the root).
  final String san;
  final int ply;

  final Map<String, EcoNode> children = {};

  /// Named entries that end exactly here.
  final List<EcoEntry> entriesHere = [];

  /// Named entries in this subtree, including [entriesHere].
  int entriesBelow = 0;

  /// The most specific name for the position: the entry ending here, else
  /// the nearest named ancestor (filled in during build).
  EcoEntry? nearestName;

  int get distinctChildren => children.length;

  /// See the library doc: how much of a fork this position is.
  int get tabiyaScore => entriesBelow * distinctChildren;

  bool get isLeaf => children.isEmpty;

  /// Children ordered by how much book lies below them.
  List<EcoNode> get childrenByWeight =>
      children.values.toList()
        ..sort((a, b) => b.entriesBelow.compareTo(a.entriesBelow));
}

class EcoEntry {
  final String eco;
  final String name;
  final List<String> moves;
  const EcoEntry({required this.eco, required this.name, required this.moves});
}

class EcoTrie {
  EcoTrie._(this.root, this.entryCount);

  final EcoNode root;
  final int entryCount;

  /// Follow [moves] from the root; null once the path leaves the book.
  EcoNode? nodeAt(List<String> moves) {
    var node = root;
    for (final san in moves) {
      final next = node.children[san];
      if (next == null) return null;
      node = next;
    }
    return node;
  }

  /// The deepest book node on [moves] and how many plies of it were in book.
  ({EcoNode node, int inBookPlies}) deepestOn(List<String> moves) {
    var node = root;
    var n = 0;
    for (final san in moves) {
      final next = node.children[san];
      if (next == null) break;
      node = next;
      n++;
    }
    return (node: node, inBookPlies: n);
  }

  /// Name for the position after [moves]: the most specific entry on or
  /// above the deepest book node reached.
  EcoEntry? nameFor(List<String> moves) => deepestOn(moves).node.nearestName;

  /// Tabiya score after [moves]; 0 when out of book.
  int tabiyaScoreAt(List<String> moves) => nodeAt(moves)?.tabiyaScore ?? 0;

  /// Parse TSV volumes (`eco\tname\tpgn`) into a trie. Pure, so it can run
  /// in an isolate.
  static EcoTrie build(List<String> tsvContents) {
    final root = EcoNode(san: '', ply: 0);
    var count = 0;
    for (final content in tsvContents) {
      for (final line in const LineSplitter().convert(content)) {
        if (line.isEmpty || line.startsWith('eco\t')) continue;
        final parts = line.split('\t');
        if (parts.length < 3) continue;
        final moves = cleanSanTokens(parts[2]);
        if (moves.isEmpty) continue;
        final entry = EcoEntry(eco: parts[0], name: parts[1], moves: moves);
        var node = root;
        node.entriesBelow++;
        for (final san in moves) {
          node = node.children.putIfAbsent(
            san,
            () => EcoNode(san: san, ply: node.ply + 1),
          );
          node.entriesBelow++;
        }
        node.entriesHere.add(entry);
        count++;
      }
    }
    _fillNames(root, null);
    return EcoTrie._(root, count);
  }

  static void _fillNames(EcoNode node, EcoEntry? inherited) {
    // Prefer the shortest-named entry ending here as "the" name; when several
    // end at one node they differ only in aliases.
    final own = node.entriesHere.isEmpty
        ? null
        : (node.entriesHere.toList()
                ..sort((a, b) => a.name.length.compareTo(b.name.length)))
              .first;
    node.nearestName = own ?? inherited;
    for (final child in node.children.values) {
      _fillNames(child, node.nearestName);
    }
  }
}

/// Loads and caches the bundled trie.
class EcoTrieService {
  EcoTrieService._();
  static final EcoTrieService instance = EcoTrieService._();

  Future<EcoTrie>? _loading;

  Future<EcoTrie> load() => _loading ??= _load();

  Future<EcoTrie> _load() async {
    final contents = <String>[];
    for (final volume in const ['a', 'b', 'c', 'd', 'e']) {
      contents.add(
        await rootBundle.loadString('assets/data/openings/$volume.tsv'),
      );
    }
    return compute(EcoTrie.build, contents);
  }

  /// Tests inject a small trie instead of the asset bundle.
  @visibleForTesting
  set override(EcoTrie? trie) =>
      _loading = trie == null ? null : Future.value(trie);
}
