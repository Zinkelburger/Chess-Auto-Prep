// Stub for web / non-IO platforms where dart:isolate is unavailable.
import '../models/tactics_position.dart';

/// Whether parallel multi-core analysis is available on this platform.
bool get isParallelAnalysisAvailable => false;

/// Not available on this platform — returns 1 as a safe fallback.
int get availableProcessors => 1;

/// Not available — always throws on non-native platforms.
Future<List<TacticsPosition>> analyzeGamesParallel({
  required List<Map<String, dynamic>> gameTasks,
  required String username,
  required int depth,
  required int totalGames,
  int? maxCores,
  int? hashPerWorkerMb,
  Function(String)? progressCallback,
  void Function(TacticsPosition)? onPositionFound,
  void Function(String)? onGameComplete,
}) async {
  throw UnsupportedError('Parallel analysis is not available on this platform');
}
