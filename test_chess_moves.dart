import 'package:chess/chess.dart';

void main() {
  print('=== TESTING CHESS LIBRARY MOVE FORMATS ===');

  final chess = Chess();

  // Test standard opening moves
  final testMoves = [
    'e4', 'c5', 'Nf3', 'd6', 'd4', 'cxd4', 'Nxd4', 'Nf6', 'Nc3', 'Nc6'
  ];

  print('Testing moves in sequence:');
  for (int i = 0; i < testMoves.length; i++) {
    final move = testMoves[i];
    final currentTurn = chess.turn == Color.WHITE ? 'White' : 'Black';

    print('${i+1}. $currentTurn to play: "$move"');

    try {
      final result = chess.move(move);
      if (result) {
        print('   ✅ SUCCESS');
        print('   Position after: ${chess.fen}');
      } else {
        print('   ❌ FAILED - Invalid move');
        print('   Legal moves: ${chess.moves().take(10).join(', ')}...');
        break;
      }
    } catch (e) {
      print('   💥 EXCEPTION: $e');
      print('   Legal moves: ${chess.moves().take(10).join(', ')}...');
      break;
    }
    print('');
  }

  // Test different move formats for the same capture
  print('\n=== TESTING CAPTURE FORMATS ===');
  final chess2 = Chess();
  chess2.move('e4');
  chess2.move('d5');
  chess2.move('exd5'); // Set up a capture position

  print('Position: ${chess2.fen}');
  print('Legal moves: ${chess2.moves()}');

  final chess3 = Chess();
  chess3.move('e4');
  chess3.move('c5');
  chess3.move('Nf3');
  chess3.move('d6');
  chess3.move('d4');

  print('\nAfter 1.e4 c5 2.Nf3 d6 3.d4:');
  print('Position: ${chess3.fen}');
  print('Legal moves: ${chess3.moves()}');

  // Test the problematic capture
  print('\nTesting "cxd4":');
  final result = chess3.move('cxd4');
  print('Result: $result');

  if (!result) {
    print('Trying alternative formats:');
    final alternatives = ['c5xd4', 'c5-d4', 'cd4'];
    for (final alt in alternatives) {
      final chess4 = Chess();
      chess4.move('e4');
      chess4.move('c5');
      chess4.move('Nf3');
      chess4.move('d6');
      chess4.move('d4');

      final altResult = chess4.move(alt);
      print('  "$alt": $altResult');
    }
  }
}