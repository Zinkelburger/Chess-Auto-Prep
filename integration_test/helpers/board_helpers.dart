import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';

/// Parse a move string (UCI or SAN) to a UCI string (e.g. "b8d7").
/// Returns null if the move can't be parsed.
String? parseMoveToUci(Position position, String moveStr) {
  final trimmed = moveStr.trim();
  if (trimmed.isEmpty) return null;

  if (RegExp(r'^[a-h][1-8][a-h][1-8][qrbnQRBN]?$').hasMatch(trimmed)) {
    return trimmed;
  }

  final move = position.parseSan(trimmed);
  if (move is NormalMove) {
    var uci = '${move.from.name}${move.to.name}';
    if (move.promotion != null) uci += move.promotion!.letter;
    return uci;
  }
  return null;
}

/// Send a UCI move through AppState.onMoveAttempted — the same path
/// the board's onMove callback uses.
Future<void> playMoveViaAppState(
  WidgetTester tester,
  String uci,
) async {
  getAppState(tester).onMoveAttempted(uci);
  await tester.pump();
  await tester.pumpAndSettle();
}

/// Read the current [AppState] from the widget tree.
AppState getAppState(WidgetTester tester) {
  final context = tester.element(find.byType(Scaffold).first);
  return Provider.of<AppState>(context, listen: false);
}
