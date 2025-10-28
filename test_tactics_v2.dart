import 'lib/services/tactics_service_v2.dart';

void main() async {
  print('=== TESTING TACTICS SERVICE V2 ===');

  final service = TacticsServiceV2();

  try {
    final positions = await service.generateTacticsFromLichess('BigManArkhangelsk');
    print('Successfully generated ${positions.length} tactical positions!');

    if (positions.isNotEmpty) {
      print('\nFirst few positions:');
      for (int i = 0; i < positions.length && i < 5; i++) {
        final pos = positions[i];
        print('${i+1}. ${pos.mistakeType} - ${pos.positionContext}');
        print('   FEN: ${pos.fen.substring(0, 30)}...');
        print('   User move: ${pos.userMove}');
        print('   Best move: ${pos.correctLine.join(' ')}');
        print('   Analysis: ${pos.mistakeAnalysis.substring(0, 50)}...');
        print('');
      }
    }
  } catch (e) {
    print('Error: $e');
  }
}