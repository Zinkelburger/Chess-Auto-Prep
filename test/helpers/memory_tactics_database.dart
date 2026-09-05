import 'package:chess_auto_prep/features/tactics/services/tactics_database.dart';

/// Session/notifier unit tests exercise state without a filesystem. Durable
/// writes and failures are tested using real temp files in storage tests.
class MemoryTacticsDatabase extends TacticsDatabase {
  @override
  Future<void> savePositions() async {}
}
