/// A node in the analysis tree. Each node represents a move.
/// Children[0] is the main continuation, children[1+] are variations.
class AnalysisNode {
  final String san;
  final String fenAfter;
  final List<AnalysisNode> children;
  final int id;
  final bool isEphemeral; // true = user-added, false = from PGN

  static int _nextId = 0;

  AnalysisNode({
    required this.san,
    required this.fenAfter,
    this.isEphemeral = true,
  })  : children = [],
        id = _nextId++;

  AnalysisNode? findChild(String san) {
    for (final child in children) {
      if (child.san == san) return child;
    }
    return null;
  }

  (AnalysisNode node, bool isMainLine) addChild(String san, String fenAfter,
      {bool isEphemeral = true}) {
    final existing = findChild(san);
    if (existing != null) {
      return (existing, children.indexOf(existing) == 0);
    }
    final newNode =
        AnalysisNode(san: san, fenAfter: fenAfter, isEphemeral: isEphemeral);
    children.add(newNode);
    return (newNode, children.length == 1);
  }
}
