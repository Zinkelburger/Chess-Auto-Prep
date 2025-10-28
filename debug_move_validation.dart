import 'dart:io';

void main() {
  print('=== TESTING MOVE VALIDATION ===');

  // Current regex from tactics_service.dart
  bool isValidChessMoveOld(String move) {
    if (move.isEmpty || move.length > 10) return false;
    return RegExp(r'^([a-h][1-8]|[NBRQK][a-h1-8]*x?[a-h][1-8]|O-O(-O)?|[a-h]x[a-h][1-8]|[NBRQK][a-h1-8]+|[a-h][1-8]=?[QRBN]?)$').hasMatch(move) ||
           move == 'O-O' || move == 'O-O-O';
  }

  // Improved regex that should handle all cases
  bool isValidChessMoveNew(String move) {
    if (move.isEmpty || move.length > 10) return false;

    // Comprehensive patterns:
    final patterns = [
      r'^[a-h][1-8]$',                    // Pawn moves: e4, d5
      r'^[a-h]x[a-h][1-8]$',              // Pawn captures: exd5, cxd4
      r'^[NBRQK][a-h1-8]*x?[a-h][1-8]$',  // Piece moves/captures: Nf3, Nxd4, Bxf7
      r'^O-O(-O)?$',                      // Castling
      r'^[a-h][1-8]=[QRBN]$',             // Pawn promotion: e8=Q
      r'^[a-h]x[a-h][1-8]=[QRBN]$',       // Capture promotion: dxe8=Q
    ];

    return patterns.any((pattern) => RegExp(pattern).hasMatch(move));
  }

  // Test moves that are failing
  final testMoves = [
    'e4', 'c5', 'Nf3', 'd6', 'd4', 'cxd4', 'Nxd4', 'Nf6', 'Nc3', 'Nc6',
    'Be2', 'g6', 'Be3', 'Bg7', 'O-O', 'Bd7', 'Bf3', 'e5', 'Ndb5', 'a6',
    'Nxd6', 'Nd4', 'Qd2', 'Nd3', 'Ng4', 'Nc4', 'Nd1'
  ];

  print('Testing move validation:');
  print('Move      Old   New');
  print('-------------------');

  for (final move in testMoves) {
    final oldResult = isValidChessMoveOld(move);
    final newResult = isValidChessMoveNew(move);
    final status = oldResult == newResult ? '✓' : '❌';
    print('${move.padRight(8)} ${oldResult ? '✓' : '✗'}     ${newResult ? '✓' : '✗'}   $status');
  }

  // Test specifically problematic captures
  print('\n=== CAPTURE TESTING ===');
  final captures = ['cxd4', 'Nxd4', 'Bxf7', 'exd5', 'Qxd8', 'Rxe1'];

  for (final capture in captures) {
    final oldResult = isValidChessMoveOld(capture);
    final newResult = isValidChessMoveNew(capture);
    print('$capture: old=${oldResult ? '✓' : '✗'}, new=${newResult ? '✓' : '✗'}');
  }
}