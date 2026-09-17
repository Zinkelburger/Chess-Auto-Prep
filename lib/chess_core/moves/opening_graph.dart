/// Read-only queries shared by opening explorers and repertoire analysis.
/// Builder exposes a protected projection; traversal never grants edit ownership.
library;

class ReachEstimate {
  final double probability;
  final int decisionPoints;

  const ReachEstimate(this.probability, this.decisionPoints);

  double get percent => probability * 100;

  /// Compact percentage label: '100', '<0.1', or one decimal place.
  String get percentLabel {
    if (percent >= 99.95) return '100';
    if (percent > 0 && percent < 0.05) return '<0.1';
    return percent.toStringAsFixed(1);
  }
}

abstract interface class OpeningNodeView {
  String get move;
  String get fen;
  int get gamesPlayed;
  int get wins;
  int get losses;
  int get draws;
  Map<String, OpeningNodeView> get children;
  OpeningNodeView? get parent;
  List<OpeningNodeView> get sortedChildren;
  double get winRate;
  double get winRatePercent;
  bool get hasWdl;
  bool get moverWasWhite;
  ReachEstimate reachEstimate({required bool protagonistIsWhite});
  List<String> getMovePath();
  String getMovePathString();
  int countDescendants({required int maxPly});
}

abstract interface class OpeningPositionView {
  List<OpeningNodeView> get nodes;
  OpeningNodeView get primaryNode;
  String get fen;
  String get move;
  bool get viaTransposition;
  int get gamesPlayed;
  int get wins;
  int get losses;
  int get draws;
  bool get hasWdl;
  double get winRate;
  double get winRatePercent;
  List<OpeningPositionView> get children;
  ReachEstimate reachEstimate({required bool protagonistIsWhite});
}

abstract interface class OpeningGraph {
  OpeningNodeView get root;
  OpeningNodeView get currentNode;
  OpeningNodeView get cursorRoot;
  Map<String, List<OpeningNodeView>> get fenToNodes;
  List<OpeningNodeView> get setupRoots;
  String get currentFen;
  bool get inBook;
  List<String> get currentMovePath;
  String get currentMovePathString;
  bool get canGoBack;
  int get currentDepth;
  int get totalGames;
  OpeningPositionView get currentGroup;
  List<OpeningPositionView> get continuations;
  List<OpeningPositionView> continuationsAt(String fen);
  bool hasMove(String fen, String san);
  bool hasMoveOnPath(List<String> pathFromRoot, String san);
  bool doesMoveTranspose(String fen, String san);
  OpeningNodeView? nodeAtPath(List<String> sans);
}
