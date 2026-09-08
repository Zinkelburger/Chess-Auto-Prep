/// The Scid piece list, checked rule by rule against Scid's `position.cpp`
/// (`StdStart`, `AddPiece`, `DoSimpleMove`): fixed standard-start order,
/// FEN read order with the king forced to slot 0, swap-with-last on capture,
/// promotion keeping the pawn's slot, castling moving king and rook in place.
///
/// The encoder fixtures already prove the whole pipeline byte-for-byte; these
/// tests pin the individual rules so a regression names the rule it broke.
library;

import 'dart:math';

import 'package:chess_auto_prep/services/scid/scid_piece_list.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

int sq(String name) => Square.parse(name)!;

Position pos(String fen) => Chess.fromSetup(Setup.parseFen(fen));

/// Every live slot maps back to itself and every occupied square of [side]
/// on the board holds exactly one slot — the invariant Scid's own
/// `valid_sqlist` asserts after each move.
void expectConsistent(ScidPieceList list, Position position, Side side) {
  final count = list.countOf(side);
  final onBoard = <int>{};
  for (final entry in position.board.pieces) {
    if (entry.$2.color == side) onBoard.add(entry.$1);
  }
  expect(count, onBoard.length, reason: 'count must match board occupancy');
  final seen = <int>{};
  for (var slot = 0; slot < count; slot++) {
    final square = list.squareAt(side, slot);
    expect(seen.add(square), isTrue, reason: 'slot $slot repeats $square');
    expect(onBoard, contains(square), reason: 'slot $slot points off-board');
    expect(list.slotOf(square), slot, reason: 'slotOf must invert squareAt');
  }
  // The king is always slot 0, on the standard and every FEN start, and a
  // king move keeps its slot.
  expect(
    position.board.pieceAt(Square(list.squareAt(side, 0)))?.role,
    Role.king,
  );
}

/// Drive [list] with the capture/castling detection the encoder performs.
Position applySan(ScidPieceList list, Position before, String san) {
  final move = before.parseSan(san)! as NormalMove;
  final piece = before.board.pieceAt(move.from)!;
  final dest = before.board.pieceAt(move.to);
  final isCastle =
      piece.role == Role.king &&
      dest != null &&
      dest.role == Role.rook &&
      dest.color == piece.color;
  int? rookFrom, rookTo;
  int kingTo = move.to;
  if (isCastle) {
    final kingside = move.to > move.from;
    kingTo = kingside ? move.from + 2 : move.from - 2;
    rookFrom = move.to;
    rookTo = kingside ? kingTo - 1 : kingTo + 1;
  }
  int? captured;
  if (!isCastle) {
    if (dest != null && dest.color != piece.color) {
      captured = move.to;
    } else if (piece.role == Role.pawn &&
        (move.from & 7) != (move.to & 7) &&
        dest == null) {
      captured = (move.from & ~7) | (move.to & 7);
    }
  }
  list.applyMove(
    mover: piece.color,
    from: move.from,
    to: isCastle ? kingTo : move.to,
    capturedSquare: captured,
    castleRookFrom: rookFrom,
    castleRookTo: rookTo,
  );
  return before.play(move);
}

void main() {
  group('standard start', () {
    test('back rank is K R N B Q B N R, then pawns a-h', () {
      final list = ScidPieceList.standard();
      const files = ['e', 'a', 'b', 'c', 'd', 'f', 'g', 'h'];
      for (var slot = 0; slot < 8; slot++) {
        expect(list.squareAt(Side.white, slot), sq('${files[slot]}1'));
        expect(list.squareAt(Side.black, slot), sq('${files[slot]}8'));
      }
      for (var file = 0; file < 8; file++) {
        final f = String.fromCharCode('a'.codeUnitAt(0) + file);
        expect(list.squareAt(Side.white, 8 + file), sq('${f}2'));
        expect(list.squareAt(Side.black, 8 + file), sq('${f}7'));
        expect(list.slotOf(sq('${f}2')), 8 + file);
      }
      expect(list.countOf(Side.white), 16);
      expect(list.countOf(Side.black), 16);
      expect(list.slotOf(sq('e4')), -1);
    });

    test('differs from the same position read as a FEN', () {
      // Scid keeps these apart with the start-board flag; an encoder that
      // used FEN order for a standard game would write wrong slot nibbles.
      final fromFen = ScidPieceList.fromPosition(Chess.initial);
      expect(
        fromFen.slotOf(sq('a1')),
        isNot(ScidPieceList.standard().slotOf(sq('a1'))),
      );
    });
  });

  group('FEN start', () {
    test('appends in read order and forces the king to slot 0', () {
      final list = ScidPieceList.fromPosition(Chess.initial);
      // Black: r n b q are read first, then the king displaces a8 to the end
      // of what has been read so far (slot 4), then b n r, then pawns.
      const black = ['e8', 'b8', 'c8', 'd8', 'a8', 'f8', 'g8', 'h8'];
      for (var slot = 0; slot < 8; slot++) {
        expect(
          list.squareAt(Side.black, slot),
          sq(black[slot]),
          reason: 'black slot $slot',
        );
      }
      for (var file = 0; file < 8; file++) {
        final f = String.fromCharCode('a'.codeUnitAt(0) + file);
        expect(list.squareAt(Side.black, 8 + file), sq('${f}7'));
      }
      // White: the pawns on rank 2 come before rank 1, so the king displaces
      // the a2 pawn (slot 0) to slot 12.
      for (var file = 0; file < 8; file++) {
        final f = String.fromCharCode('a'.codeUnitAt(0) + file);
        expect(
          list.slotOf(sq('${f}2')),
          file == 0 ? 12 : file,
          reason: '${f}2',
        );
      }
      expect(list.squareAt(Side.white, 0), sq('e1'));
      expect(list.slotOf(sq('a1')), 8);
      expect(list.slotOf(sq('b1')), 9);
      expect(list.slotOf(sq('c1')), 10);
      expect(list.slotOf(sq('d1')), 11);
      expect(list.slotOf(sq('f1')), 13);
      expect(list.slotOf(sq('g1')), 14);
      expect(list.slotOf(sq('h1')), 15);
      expectConsistent(list, Chess.initial, Side.white);
      expectConsistent(list, Chess.initial, Side.black);
    });

    test('a king read first stays at slot 0 without displacing anything', () {
      final p = pos('k7/8/8/8/8/8/8/K6R w - - 0 1');
      final list = ScidPieceList.fromPosition(p);
      expect(list.squareAt(Side.black, 0), sq('a8'));
      expect(list.countOf(Side.black), 1);
      expect(list.squareAt(Side.white, 0), sq('a1'));
      expect(list.squareAt(Side.white, 1), sq('h1'));
      expect(list.countOf(Side.white), 2);
    });

    test('a king read last displaces the first-read piece, not the last', () {
      final p = pos('8/8/8/8/8/8/8/RNBQK2k w - - 0 1');
      final list = ScidPieceList.fromPosition(p);
      expect(list.squareAt(Side.white, 0), sq('e1'));
      expect(list.squareAt(Side.white, 1), sq('b1'));
      expect(list.squareAt(Side.white, 2), sq('c1'));
      expect(list.squareAt(Side.white, 3), sq('d1'));
      expect(
        list.squareAt(Side.white, 4),
        sq('a1'),
        reason: 'displaced to the end',
      );
      expect(list.countOf(Side.white), 5);
    });
  });

  group('captures', () {
    test('a capture drops the last piece into the captured slot', () {
      final list = ScidPieceList.standard();
      Position p = Chess.initial;
      for (final san in ['e4', 'd5', 'exd5']) {
        p = applySan(list, p, san);
      }
      // Black's d-pawn was slot 11; the h-pawn (slot 15) takes its place.
      expect(list.countOf(Side.black), 15);
      expect(list.squareAt(Side.black, 11), sq('h7'));
      expect(list.slotOf(sq('h7')), 11);
      // White's e-pawn keeps slot 12 on its new square.
      expect(list.slotOf(sq('d5')), 12);
      expect(list.slotOf(sq('e4')), -1);
      expectConsistent(list, p, Side.white);
      expectConsistent(list, p, Side.black);
    });

    test('capturing the piece in the last slot just shrinks the list', () {
      final list = ScidPieceList.standard();
      Position p = Chess.initial;
      // 1.e4 h5 2.Qxh5 ... Black's h-pawn sits in the last slot (15).
      for (final san in ['e4', 'h5', 'Qxh5']) {
        p = applySan(list, p, san);
      }
      expect(list.countOf(Side.black), 15);
      expect(
        list.slotOf(sq('h5')),
        4,
        reason: 'the queen (slot 4) now stands there',
      );
      expect(
        list.squareAt(Side.black, 14),
        sq('g7'),
        reason: 'slot 14 untouched',
      );
      expectConsistent(list, p, Side.black);
    });

    test('en passant removes the pawn beside the destination', () {
      final list = ScidPieceList.standard();
      Position p = Chess.initial;
      for (final san in ['e4', 'a6', 'e5', 'd5', 'exd6']) {
        p = applySan(list, p, san);
      }
      expect(list.slotOf(sq('d5')), -1, reason: 'captured pawn square emptied');
      expect(list.slotOf(sq('d6')), 12, reason: 'white e-pawn keeps slot 12');
      expect(list.slotOf(sq('e5')), -1);
      expect(list.countOf(Side.black), 15);
      // Black's d-pawn (slot 11) was replaced by the last piece, the h-pawn.
      expect(list.squareAt(Side.black, 11), sq('h7'));
      expectConsistent(list, p, Side.black);
      expectConsistent(list, p, Side.white);
    });

    test('slots of surviving pieces are stable across repeated captures', () {
      final list = ScidPieceList.standard();
      Position p = Chess.initial;
      // Scholar's-mate-ish exchange sequence with several captures.
      for (final san in [
        'e4',
        'e5',
        'Nf3',
        'Nc6',
        'Bc4',
        'Nf6',
        'Nxe5',
        'Nxe5',
        'd4',
        'Nxc4',
      ]) {
        p = applySan(list, p, san);
      }
      // The white king (0) and queen (4) never moved. Nxe5 lost the g1
      // knight (slot 6), so the h-pawn (15) dropped into 6; Nxc4 then lost
      // the bishop (slot 5), and the new last piece, the g-pawn (14), took 5.
      expect(list.slotOf(sq('e1')), 0);
      expect(list.slotOf(sq('d1')), 4);
      expect(list.squareAt(Side.white, 6), sq('h2'));
      expect(list.squareAt(Side.white, 5), sq('g2'));
      expect(list.countOf(Side.white), 14);
      expect(list.countOf(Side.black), 15);
      expectConsistent(list, p, Side.white);
      expectConsistent(list, p, Side.black);
    });
  });

  group('promotion', () {
    test('the promoted piece keeps the pawn slot and moves with it', () {
      final p0 = pos('4k3/P7/8/8/8/8/8/4K3 w - - 0 1');
      final list = ScidPieceList.fromPosition(p0);
      final pawnSlot = list.slotOf(sq('a7'));
      expect(pawnSlot, 1);
      var p = applySan(list, p0, 'a8=Q');
      expect(list.slotOf(sq('a8')), pawnSlot);
      p = applySan(list, p, 'Kf7'); // Qa8 gives check along the rank
      p = applySan(list, p, 'Qa4');
      expect(
        list.slotOf(sq('a4')),
        pawnSlot,
        reason: 'no re-slotting on promotion',
      );
      expect(list.countOf(Side.white), 2);
      expectConsistent(list, p, Side.white);
    });

    test(
      'a capturing promotion swaps the victim out and keeps the pawn slot',
      () {
        final p0 = pos('rn2k3/1P6/8/8/8/8/8/4K3 w - - 0 1');
        final list = ScidPieceList.fromPosition(p0);
        // Black FEN order: a8 rook (0) → displaced by the king to slot 2;
        // b8 knight is slot 1; king slot 0.
        expect(list.slotOf(sq('a8')), 2);
        expect(list.slotOf(sq('b8')), 1);
        final p = applySan(list, p0, 'bxa8=Q');
        expect(list.countOf(Side.black), 2);
        expect(
          list.squareAt(Side.black, 1),
          sq('b8'),
          reason: 'the rook was last; nothing swapped',
        );
        expect(
          list.slotOf(sq('a8')),
          1,
          reason: 'white pawn slot 1 now holds the queen',
        );
        expectConsistent(list, p, Side.white);
        expectConsistent(list, p, Side.black);
      },
    );
  });

  group('castling', () {
    test(
      'kingside keeps king at 0 and rook at its slot on the new squares',
      () {
        final list = ScidPieceList.standard();
        Position p = Chess.initial;
        for (final san in [
          'e4',
          'e5',
          'Nf3',
          'Nc6',
          'Bc4',
          'Bc5',
          'O-O',
          'Nf6',
        ]) {
          p = applySan(list, p, san);
        }
        expect(list.squareAt(Side.white, 0), sq('g1'));
        expect(list.squareAt(Side.white, 7), sq('f1'));
        expect(list.slotOf(sq('e1')), -1);
        expect(list.slotOf(sq('h1')), -1);
        expectConsistent(list, p, Side.white);
      },
    );

    test('queenside for Black moves the a8 rook (slot 1) to d8', () {
      final list = ScidPieceList.standard();
      Position p = Chess.initial;
      for (final san in [
        'd4',
        'd5',
        'Nc3',
        'Nc6',
        'Bf4',
        'Bf5',
        'Qd2',
        'Qd7',
        'O-O-O',
        'O-O-O',
      ]) {
        p = applySan(list, p, san);
      }
      expect(list.squareAt(Side.black, 0), sq('c8'));
      expect(list.squareAt(Side.black, 1), sq('d8'));
      expect(list.slotOf(sq('e8')), -1);
      expect(list.slotOf(sq('a8')), -1);
      expect(list.squareAt(Side.white, 0), sq('c1'));
      expect(list.squareAt(Side.white, 1), sq('d1'));
      expectConsistent(list, p, Side.white);
      expectConsistent(list, p, Side.black);
    });
  });

  group('clone', () {
    test('a clone is independent of the line it branched from', () {
      final main = ScidPieceList.standard();
      Position p = Chess.initial;
      p = applySan(main, p, 'e4');
      p = applySan(main, p, 'd5');
      final branch = main.clone();
      final branched = applySan(branch, p, 'exd5');
      applySan(main, p, 'Nc3');
      expect(branch.countOf(Side.black), 15);
      expect(main.countOf(Side.black), 16);
      expect(main.slotOf(sq('d5')), 11, reason: 'main line still has the pawn');
      expect(
        branch.slotOf(sq('d5')),
        12,
        reason: 'branch has the capturing pawn',
      );
      expectConsistent(branch, branched, Side.black);
    });
  });

  test('null move touches nothing', () {
    final list = ScidPieceList.standard();
    list.applyNullMove();
    expect(list.countOf(Side.white), 16);
    expect(list.squareAt(Side.white, 0), sq('e1'));
  });

  test('random playouts keep the list a bijection onto the board', () {
    final rng = Random(20260908);
    for (var game = 0; game < 40; game++) {
      final list = ScidPieceList.standard();
      Position p = Chess.initial;
      for (var ply = 0; ply < 120 && !p.isGameOver; ply++) {
        final legal = <NormalMove>[];
        for (final entry in p.legalMoves.entries) {
          for (final to in entry.value.squares) {
            final piece = p.board.pieceAt(entry.key)!;
            final promo =
                piece.role == Role.pawn && (to ~/ 8 == 0 || to ~/ 8 == 7);
            if (promo) {
              for (final r in [
                Role.queen,
                Role.knight,
                Role.rook,
                Role.bishop,
              ]) {
                legal.add(NormalMove(from: entry.key, to: to, promotion: r));
              }
            } else {
              legal.add(NormalMove(from: entry.key, to: to));
            }
          }
        }
        final move = legal[rng.nextInt(legal.length)];
        final (_, san) = p.makeSan(move);
        p = applySan(list, p, san);
        expectConsistent(list, p, Side.white);
        expectConsistent(list, p, Side.black);
      }
    }
  });
}
