import 'package:dartchess/dartchess.dart';

void main() {
  print('=== TESTING DARTCHESS LIBRARY MOVE FORMATS ===');

  Position pos = Chess.initial;

  // Test standard opening moves
  final testMoves = [
    'e4', 'c5', 'Nf3', 'd6', 'd4', 'cxd4', 'Nxd4', 'Nf6', 'Nc3', 'Nc6'
  ];

  print('Testing moves in sequence:');
  for (int i = 0; i < testMoves.length; i++) {
    final san = testMoves[i];
    final currentTurn = pos.turn == Side.white ? 'White' : 'Black';

    print('${i+1}. $currentTurn to play: "$san"');

    try {
      final move = pos.parseSan(san);
      if (move != null) {
        pos = pos.play(move);
        print('   ✅ SUCCESS');
        print('   Position after: ${pos.fen}');
      } else {
        print('   ❌ FAILED - Invalid move');
        break;
      }
    } catch (e) {
      print('   💥 EXCEPTION: $e');
      break;
    }
    print('');
  }

  // Test different move formats for the same capture
  print('\n=== TESTING CAPTURE FORMATS ===');
  Position pos2 = Chess.initial;
  pos2 = pos2.play(pos2.parseSan('e4')!);
  pos2 = pos2.play(pos2.parseSan('d5')!);
  pos2 = pos2.play(pos2.parseSan('exd5')!);

  print('Position: ${pos2.fen}');

  Position pos3 = Chess.initial;
  pos3 = pos3.play(pos3.parseSan('e4')!);
  pos3 = pos3.play(pos3.parseSan('c5')!);
  pos3 = pos3.play(pos3.parseSan('Nf3')!);
  pos3 = pos3.play(pos3.parseSan('d6')!);
  pos3 = pos3.play(pos3.parseSan('d4')!);

  print('\nAfter 1.e4 c5 2.Nf3 d6 3.d4:');
  print('Position: ${pos3.fen}');

  // Test the problematic capture
  print('\nTesting "cxd4":');
  final result = pos3.parseSan('cxd4');
  print('Result: ${result != null ? "success" : "failed"}');
}
