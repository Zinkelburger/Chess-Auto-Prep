/// Rich move object that contains complete information about a move
class CompletedMove {
  final String from;
  final String to;
  final String san;
  final String fenBefore;
  final String fenAfter;
  final String uci;

  CompletedMove({
    required this.from,
    required this.to,
    required this.san,
    required this.fenBefore,
    required this.fenAfter,
    required this.uci,
  });

  @override
  String toString() => 'Move($uci -> $san, $fenBefore -> $fenAfter)';
}
