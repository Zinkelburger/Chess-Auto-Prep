/// FP-Growth algorithm for frequent itemset mining.
///
/// Optimized for small transaction sets typical in chess repertoire analysis
/// (50-500 transactions, 5-15 items each).
library;

class FrequentItemset {
  final Set<String> items;
  final double support;
  final int count;

  const FrequentItemset({
    required this.items,
    required this.support,
    required this.count,
  });
}

class _FPNode {
  final String? item;
  int count = 0;
  final Map<String, _FPNode> children = {};
  _FPNode? parent;
  _FPNode? headerLink;

  _FPNode({this.item});
}

class FPGrowthMiner {
  final double minSupport;
  final List<Set<String>> transactions;

  FPGrowthMiner({
    required this.minSupport,
    required this.transactions,
  });

  List<FrequentItemset> mine() {
    if (transactions.isEmpty) return [];

    final n = transactions.length;
    final minCount = (minSupport * n).ceil();

    final freq = <String, int>{};
    for (final t in transactions) {
      for (final item in t) {
        freq[item] = (freq[item] ?? 0) + 1;
      }
    }

    final frequentItems = freq.entries
        .where((e) => e.value >= minCount)
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    if (frequentItems.isEmpty) return [];

    final itemOrder = <String, int>{};
    for (var i = 0; i < frequentItems.length; i++) {
      itemOrder[frequentItems[i].key] = i;
    }

    final root = _FPNode();
    final headerTable = <String, _FPNode>{};

    for (final transaction in transactions) {
      final sorted = transaction
          .where((item) => itemOrder.containsKey(item))
          .toList()
        ..sort((a, b) => itemOrder[a]!.compareTo(itemOrder[b]!));

      var current = root;
      for (final item in sorted) {
        if (!current.children.containsKey(item)) {
          final newNode = _FPNode(item: item)..parent = current;
          current.children[item] = newNode;
          if (headerTable.containsKey(item)) {
            var last = headerTable[item]!;
            while (last.headerLink != null) {
              last = last.headerLink!;
            }
            last.headerLink = newNode;
          } else {
            headerTable[item] = newNode;
          }
        }
        current = current.children[item]!;
        current.count++;
      }
    }

    return _mineTree(headerTable, minCount, <String>{});
  }

  List<FrequentItemset> _mineTree(
    Map<String, _FPNode> headerTable,
    int minCount,
    Set<String> prefix,
  ) {
    final results = <FrequentItemset>[];
    final items = headerTable.keys.toList().reversed.toList();

    for (final item in items) {
      final newPrefix = {...prefix, item};
      final support = _countItem(headerTable[item]);

      if (support >= minCount) {
        results.add(FrequentItemset(
          items: newPrefix,
          support: support / transactions.length,
          count: support,
        ));

        final conditionalPatterns =
            _conditionalPatternBase(headerTable[item]!);
        if (conditionalPatterns.isNotEmpty) {
          final subMiner = FPGrowthMiner(
            minSupport: minSupport,
            transactions: conditionalPatterns,
          );
          final subResults = subMiner.mine();
          for (final sub in subResults) {
            results.add(FrequentItemset(
              items: {...sub.items, ...newPrefix},
              support: sub.support,
              count: sub.count,
            ));
          }
        }
      }
    }

    return results;
  }

  /// Filter to maximal frequent itemsets only.
  List<FrequentItemset> maximalItemsets(List<FrequentItemset> all) {
    all.sort((a, b) => b.items.length.compareTo(a.items.length));
    final maximal = <FrequentItemset>[];
    for (final candidate in all) {
      final isSubset = maximal.any((m) =>
          candidate.items.every((item) => m.items.contains(item)));
      if (!isSubset) maximal.add(candidate);
    }
    return maximal;
  }

  static int _countItem(_FPNode? node) {
    int count = 0;
    var current = node;
    while (current != null) {
      count += current.count;
      current = current.headerLink;
    }
    return count;
  }

  static List<Set<String>> _conditionalPatternBase(_FPNode node) {
    final patterns = <Set<String>>[];
    var current = node;

    while (true) {
      if (current.count > 0) {
        final path = <String>{};
        var walker = current.parent;
        while (walker != null && walker.item != null) {
          path.add(walker.item!);
          walker = walker.parent;
        }
        if (path.isNotEmpty) {
          for (int i = 0; i < current.count; i++) {
            patterns.add(Set.of(path));
          }
        }
      }
      if (current.headerLink == null) break;
      current = current.headerLink!;
    }

    return patterns;
  }
}
