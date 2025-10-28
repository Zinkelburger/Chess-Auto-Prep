class ChessGameModel {
  final String white;
  final String black;
  final String result;
  final DateTime date;
  final String event;
  final String? whiteElo;
  final String? blackElo;
  final String? timeControl;
  final String? termination;
  final List<String> moves;
  final String pgn;

  const ChessGameModel({
    required this.white,
    required this.black,
    required this.result,
    required this.date,
    required this.event,
    this.whiteElo,
    this.blackElo,
    this.timeControl,
    this.termination,
    required this.moves,
    required this.pgn,
  });

  factory ChessGameModel.fromPgn(String pgn) {
    final lines = pgn.split('\n');
    final headers = <String, String>{};
    final moveLines = <String>[];

    bool inHeaders = true;
    for (final line in lines) {
      if (line.trim().isEmpty) continue;

      if (inHeaders && line.startsWith('[') && line.endsWith(']')) {
        final match = RegExp(r'\[(\w+)\s+"([^"]+)"\]').firstMatch(line);
        if (match != null) {
          headers[match.group(1)!] = match.group(2)!;
        }
      } else {
        inHeaders = false;
        if (!line.startsWith('[')) {
          moveLines.add(line);
        }
      }
    }

    final movesText = moveLines.join(' ');
    final moves = _extractMoves(movesText);

    return ChessGameModel(
      white: headers['White'] ?? 'Unknown',
      black: headers['Black'] ?? 'Unknown',
      result: headers['Result'] ?? '*',
      date: _parseDate(headers['Date'] ?? ''),
      event: headers['Event'] ?? '',
      whiteElo: headers['WhiteElo'],
      blackElo: headers['BlackElo'],
      timeControl: headers['TimeControl'],
      termination: headers['Termination'],
      moves: moves,
      pgn: pgn,
    );
  }

  static DateTime _parseDate(String dateStr) {
    try {
      final parts = dateStr.split('.');
      if (parts.length >= 3) {
        return DateTime(
          int.parse(parts[0]),
          int.parse(parts[1]),
          int.parse(parts[2]),
        );
      }
    } catch (e) {
      // Ignore parsing errors
    }
    return DateTime.now();
  }

  static List<String> _extractMoves(String movesText) {
    final moves = <String>[];
    final cleanText = movesText
        .replaceAll(RegExp(r'\{[^}]*\}'), '') // Remove comments
        .replaceAll(RegExp(r'\([^)]*\)'), '') // Remove variations
        .replaceAll(RegExp(r'\d+\.'), '') // Remove move numbers
        .replaceAll(RegExp(r'[*1-9]/[*1-9]-[*1-9]/[*1-9]'), '') // Remove results
        .trim();

    for (final move in cleanText.split(RegExp(r'\s+'))) {
      if (move.isNotEmpty && !RegExp(r'^[*1-9]/[*1-9]-[*1-9]/[*1-9]$').hasMatch(move)) {
        moves.add(move);
      }
    }

    return moves;
  }
}