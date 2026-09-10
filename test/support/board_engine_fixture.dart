import 'package:chess_auto_prep/services/engine/board_engine.dart';
import 'package:chess_auto_prep/services/engine/stockfish_connection_factory.dart';
import 'package:flutter_test/flutter_test.dart';

import 'scripted_engine.dart';

/// Call from setUp in composite screen tests whose subject is not Stockfish.
/// Mounted boards can prepare, search and detach without platform libraries,
/// downloads or real CPU work. Protocol and native-engine tests own those paths.
void useScriptedBoardEngine() {
  final previous = StockfishConnectionFactory.createForTest;
  StockfishConnectionFactory.createForTest = () async => ScriptedEngine();
  addTearDown(() {
    BoardEngine.instance.dispose();
    StockfishConnectionFactory.createForTest = previous;
  });
}
