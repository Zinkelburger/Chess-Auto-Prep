/// FP-Growth algorithm for frequent itemset mining.
///
/// Optimized for small transaction sets typical in chess repertoire analysis
/// (50-500 transactions, 5-15 items each).
library;

/// A set of items that occur together in at least [support] of the
/// transactions ([count] of them).
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

/// One node of the FP-tree: the item, how many transactions pass through it,
/// and the link to the next node holding the same item (the header chain).
class _FPNode {
  _FPNode({this.item, this.parent});

  final String? item;
  final _FPNode? parent;
  final Map<String, _FPNode> children = {};
  int count = 0;
  _FPNode? headerLink;
}

class FPGrowthMiner {
  /// Minimum fraction of [transactions] an itemset must appear in.
  final double minSupport;
  final List<Set<String>> transactions;

  FPGrowthMiner({required this.minSupport, required this.transactions});

  /// Every itemset meeting [minSupport], including non-maximal ones.
  List<FrequentItemset> mine() {
    if (transactions.isEmpty) return [];

    final minCount = (minSupport * transactions.length).ceil();
    final itemOrder = _frequentItemOrder(minCount);
    if (itemOrder.isEmpty) return [];

    final headerTable = _buildTree(itemOrder);
    return _mineTree(headerTable, minCount, <String>{});
  }

  /// Items meeting [minCount], mapped to their rank by descending frequency
  /// (the order transactions are inserted into the tree in).
  Map<String, int> _frequentItemOrder(int minCount) {
    final freq = <String, int>{};
    for (final transaction in transactions) {
      for (final item in transaction) {
        freq[item] = (freq[item] ?? 0) + 1;
      }
    }
    final frequentItems =
        freq.entries.where((e) => e.value >= minCount).toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    return {
      for (var i = 0; i < frequentItems.length; i++) frequentItems[i].key: i,
    };
  }

  /// Insert every transaction, restricted to frequent items in [itemOrder],
  /// into a fresh FP-tree. Returns the header table: each item's first node,
  /// chained through [_FPNode.headerLink] in insertion order.
  Map<String, _FPNode> _buildTree(Map<String, int> itemOrder) {
    final root = _FPNode();
    final headerTable = <String, _FPNode>{};

    for (final transaction in transactions) {
      final sorted =
          transaction.where((item) => itemOrder.containsKey(item)).toList()
            ..sort((a, b) => itemOrder[a]!.compareTo(itemOrder[b]!));

      var current = root;
      for (final item in sorted) {
        final parent = current;
        current = parent.children.putIfAbsent(item, () {
          final node = _FPNode(item: item, parent: parent);
          _linkIntoHeader(headerTable, item, node);
          return node;
        });
        current.count++;
      }
    }
    return headerTable;
  }

  static void _linkIntoHeader(
    Map<String, _FPNode> headerTable,
    String item,
    _FPNode node,
  ) {
    final first = headerTable[item];
    if (first == null) {
      headerTable[item] = node;
      return;
    }
    var last = first;
    while (last.headerLink != null) {
      last = last.headerLink!;
    }
    last.headerLink = node;
  }

  List<FrequentItemset> _mineTree(
    Map<String, _FPNode> headerTable,
    int minCount,
    Set<String> prefix,
  ) {
    final results = <FrequentItemset>[];

    for (final item in headerTable.keys.toList().reversed) {
      final first = headerTable[item]!;
      final support = _countItem(first);
      if (support < minCount) continue;

      final newPrefix = {...prefix, item};
      results.add(
        FrequentItemset(
          items: newPrefix,
          support: support / transactions.length,
          count: support,
        ),
      );

      final conditionalPatterns = _conditionalPatternBase(first);
      if (conditionalPatterns.isEmpty) continue;
      final subMiner = FPGrowthMiner(
        minSupport: minSupport,
        transactions: conditionalPatterns,
      );
      for (final sub in subMiner.mine()) {
        results.add(
          FrequentItemset(
            items: {...sub.items, ...newPrefix},
            support: sub.support,
            count: sub.count,
          ),
        );
      }
    }

    return results;
  }

  /// Filter to maximal frequent itemsets only: those no other itemset in
  /// [all] is a superset of. [all] is not modified.
  List<FrequentItemset> maximalItemsets(List<FrequentItemset> all) {
    final bySize = [...all]
      ..sort((a, b) => b.items.length.compareTo(a.items.length));
    final maximal = <FrequentItemset>[];
    for (final candidate in bySize) {
      final isSubset = maximal.any((m) => m.items.containsAll(candidate.items));
      if (!isSubset) maximal.add(candidate);
    }
    return maximal;
  }

  /// Total count along [node]'s header chain.
  static int _countItem(_FPNode node) {
    var count = 0;
    for (
      _FPNode? current = node;
      current != null;
      current = current.headerLink
    ) {
      count += current.count;
    }
    return count;
  }

  /// The prefix paths leading to every node on [node]'s header chain, each
  /// repeated once per transaction that passed through it.
  static List<Set<String>> _conditionalPatternBase(_FPNode node) {
    final patterns = <Set<String>>[];
    for (
      _FPNode? current = node;
      current != null;
      current = current.headerLink
    ) {
      if (current.count == 0) continue;
      final path = <String>{};
      for (
        var walker = current.parent;
        walker != null;
        walker = walker.parent
      ) {
        final item = walker.item;
        if (item == null) break;
        path.add(item);
      }
      if (path.isEmpty) continue;
      for (var i = 0; i < current.count; i++) {
        patterns.add(Set.of(path));
      }
    }
    return patterns;
  }
}
