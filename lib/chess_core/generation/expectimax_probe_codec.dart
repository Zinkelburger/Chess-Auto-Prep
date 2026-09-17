/// Pure versioned probe artifact format. No build or engine dependencies.
library;

import 'dart:convert';

import 'build_tree_node.dart';
import 'tree_serialization.dart';

/// Versioned probe-tree encoding, independent of storage location.
class ExpectimaxProbeCodec {
  static const int version = 1;

  /// Every tree serialized on its own, so each one round-trips through the
  /// same v4 format as the main tree file.
  static String encode(List<BuildTree> trees) => jsonEncode({
    'version': version,
    'trees': [for (final t in trees) serializeTree(t, indent: false)],
  });

  static List<BuildTree> decode(String raw) {
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final trees = data['trees'] as List<dynamic>? ?? const [];
    return [
      for (final entry in trees)
        if (entry is String) deserializeTree(entry),
    ];
  }
}
