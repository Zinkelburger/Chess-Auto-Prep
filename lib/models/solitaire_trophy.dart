/// A trophy earned when the user's solitaire guess beats the GM's actual move
/// by a significant engine-eval margin.
class SolitaireTrophy {
  final String id;
  final DateTime date;
  final String fen;
  final String userMove;
  final String gmMove;
  final int userEvalCp;
  final int gmEvalCp;
  final int advantageCp;
  final String gameLabel;
  final Map<String, String> headers;
  final String pgn;

  const SolitaireTrophy({
    required this.id,
    required this.date,
    required this.fen,
    required this.userMove,
    required this.gmMove,
    required this.userEvalCp,
    required this.gmEvalCp,
    required this.advantageCp,
    required this.gameLabel,
    required this.headers,
    required this.pgn,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'date': date.toIso8601String(),
    'fen': fen,
    'userMove': userMove,
    'gmMove': gmMove,
    'userEvalCp': userEvalCp,
    'gmEvalCp': gmEvalCp,
    'advantageCp': advantageCp,
    'gameLabel': gameLabel,
    'headers': headers,
    'pgn': pgn,
  };

  factory SolitaireTrophy.fromJson(Map<String, dynamic> json) {
    return SolitaireTrophy(
      id: json['id'] as String,
      date: DateTime.parse(json['date'] as String),
      fen: json['fen'] as String,
      userMove: json['userMove'] as String,
      gmMove: json['gmMove'] as String,
      userEvalCp: json['userEvalCp'] as int,
      gmEvalCp: json['gmEvalCp'] as int,
      advantageCp: json['advantageCp'] as int,
      gameLabel: json['gameLabel'] as String? ?? '',
      headers: Map<String, String>.from(json['headers'] as Map? ?? {}),
      pgn: json['pgn'] as String? ?? '',
    );
  }
}
