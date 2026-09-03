// Replays real FICS bughouse games through BughouseState and checks the one
// invariant the two-board piece flow must never break: every piece is either
// on a board or in somebody's reserve, so the total stays at 64 for ever.
//
// A duplicated piece shows up here immediately, whatever produced it.
import 'dart:io' as io;

import 'package:dartchess/dartchess.dart';
import 'package:chess_auto_prep/features/bughouse/models/bughouse_state.dart';

int _material(BughouseState s) {
  var total = 0;
  for (final which in BughouseBoard.values) {
    final p = s.board(which);
    total += p.board.occupied.size;
    final pockets = p.pockets ?? Pockets.empty;
    for (final side in Side.values) {
      for (final role in Role.values) {
        total += pockets.of(side, role);
      }
    }
  }
  return total;
}

String _pocketReport(BughouseState s) {
  final out = <String>[];
  for (final which in BughouseBoard.values) {
    final pockets = s.board(which).pockets ?? Pockets.empty;
    for (final side in Side.values) {
      for (final role in Role.values) {
        final n = pockets.of(side, role);
        if (n > 0) out.add('${which.name}/${side.name}/${role.name}=$n');
      }
    }
  }
  return out.join(' ');
}

void main(List<String> args) {
  final lines = io.File(args[0]).readAsLinesSync();
  var replayed = 0, illegal = 0, violations = 0;
  var worstQueens = 0;
  String? firstFailure;

  for (final line in lines) {
    final parts = line.split(' ');
    final gameNo = parts.first;
    var state = BughouseState.initial();
    final start = _material(state);
    var ok = true;

    for (final token in parts.skip(1)) {
      final split = token.indexOf(':');
      final boardLetter = token.substring(0, split);
      final san = token.substring(split + 1);
      final which = (boardLetter == 'A' || boardLetter == 'a')
          ? BughouseBoard.a
          : BughouseBoard.b;
      final position = state.board(which);

      Move? move;
      try {
        move = position.parseSan(san);
      } catch (_) {
        move = null;
      }
      if (move == null) {
        illegal++;
        ok = false;
        break;
      }
      final next = state.playMove(which, move);
      if (next == null) {
        illegal++;
        ok = false;
        break;
      }
      state = next;

      final now = _material(state);
      for (final w in BughouseBoard.values) {
        final pockets = state.board(w).pockets ?? Pockets.empty;
        for (final side in Side.values) {
          final q = pockets.of(side, Role.queen);
          if (q > worstQueens) worstQueens = q;
        }
      }
      if (now != start) {
        violations++;
        firstFailure ??=
            'game $gameNo: material $start -> $now after '
            '$boardLetter:$san\n  pockets: ${_pocketReport(state)}';
        ok = false;
        break;
      }
    }
    if (ok) replayed++;
  }

  io.stdout.writeln('games replayed clean : $replayed');
  io.stdout.writeln('games with an illegal/unparsed move : $illegal');
  io.stdout.writeln('MATERIAL VIOLATIONS  : $violations');
  io.stdout.writeln('largest queen reserve seen : $worstQueens');
  if (firstFailure != null)
    io.stdout.writeln('\nfirst failure:\n$firstFailure');
}
