import 'dart:convert';
import 'dart:typed_data';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/services.dart';

/// Maia-3 tensor preprocessing.
///
/// Board encoding: (64, 12) per-square one-hot piece channels.
/// Elo: continuous float (not categorical).
/// Move vocabulary: 4352 (64×64 grid + 256 promotions).
class MaiaTensor {
  static Map<String, int> _allMoves = {};
  static Map<int, String> _allMovesReversed = {};
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;

    try {
      final movesJson =
          await rootBundle.loadString('assets/data/all_moves_maia3.json');
      final movesRevJson = await rootBundle
          .loadString('assets/data/all_moves_maia3_reversed.json');

      final Map<String, dynamic> movesMap = json.decode(movesJson);
      _allMoves = movesMap.map((key, value) => MapEntry(key, value as int));

      final Map<String, dynamic> movesRevMap = json.decode(movesRevJson);
      _allMovesReversed =
          movesRevMap.map((key, value) => MapEntry(int.parse(key), value as String));

      _initialized = true;
    } catch (e) {
      print('Failed to load Maia move data: $e');
    }
  }

  /// Maia-3 board tensor: (64, 12) flattened = 768 floats.
  /// Each square gets a 12-element one-hot vector for the piece on it.
  /// Piece order: P,N,B,R,Q,K,p,n,b,r,q,k (indices 0-11).
  static Float32List boardToMaia3Tokens(String fen) {
    final piecePlacement = fen.split(' ')[0];
    const pieceTypes = [
      'P', 'N', 'B', 'R', 'Q', 'K',
      'p', 'n', 'b', 'r', 'q', 'k'
    ];

    final tensor = Float32List(64 * 12);
    final rows = piecePlacement.split('/');

    for (int rank = 0; rank < 8; rank++) {
      final row = 7 - rank;
      int file = 0;
      for (int i = 0; i < rows[rank].length; i++) {
        final char = rows[rank][i];
        final digit = int.tryParse(char);
        if (digit != null) {
          file += digit;
        } else {
          final pieceIdx = pieceTypes.indexOf(char);
          if (pieceIdx >= 0) {
            final square = row * 8 + file;
            tensor[square * 12 + pieceIdx] = 1.0;
          }
          file++;
        }
      }
    }

    return tensor;
  }

  static Map<String, dynamic> preprocess(String fen, int eloSelf, int eloOppo) {
    if (!_initialized) throw Exception('MaiaTensor not initialized');

    Position position;
    try {
      position = Chess.fromSetup(Setup.parseFen(fen));
    } catch (_) {
      throw Exception('Invalid FEN: $fen');
    }
    bool isBlack = fen.split(' ')[1] == 'b';

    String processedFen = fen;
    if (isBlack) {
      processedFen = mirrorFEN(fen);
      try {
        position = Chess.fromSetup(Setup.parseFen(processedFen));
      } catch (_) {
        throw Exception('Invalid mirrored FEN: $processedFen');
      }
    }

    final boardInput = boardToMaia3Tokens(processedFen);

    final legalMoves = Float32List(_allMoves.length);

    for (final entry in position.legalMoves.entries) {
      final fromSq = entry.key;
      final targets = entry.value;
      final piece = position.board.pieceAt(fromSq);
      final fromStr = fromSq.name;

      for (final toSq in targets.squares) {
        final toStr = toSq.name;
        final isPromotion = piece?.role == Role.pawn &&
            ((piece!.color == Side.white && toSq ~/ 8 == 7) ||
                (piece.color == Side.black && toSq ~/ 8 == 0));

        if (isPromotion) {
          for (final role in [Role.queen, Role.rook, Role.bishop, Role.knight]) {
            final promoChar = _roleToUciChar(role);
            final uci = '$fromStr$toStr$promoChar';
            if (_allMoves.containsKey(uci)) {
              legalMoves[_allMoves[uci]!] = 1.0;
            }
          }
        } else {
          final uci = '$fromStr$toStr';
          if (_allMoves.containsKey(uci)) {
            legalMoves[_allMoves[uci]!] = 1.0;
          }
        }
      }
    }

    return {
      'boardInput': boardInput,
      'eloSelf': eloSelf.toDouble(),
      'eloOppo': eloOppo.toDouble(),
      'legalMoves': legalMoves,
      'isBlack': isBlack,
    };
  }

  static String _roleToUciChar(Role role) => switch (role) {
        Role.queen => 'q',
        Role.rook => 'r',
        Role.bishop => 'b',
        Role.knight => 'n',
        _ => '',
      };

  // --- Mirroring Logic ---

  static String mirrorFEN(String fen) {
    final tokens = fen.split(' ');
    final position = tokens[0];
    final activeColor = tokens[1];
    final castling = tokens[2];
    final enPassant = tokens[3];
    final halfmove = tokens.length > 4 ? tokens[4] : '0';
    final fullmove = tokens.length > 5 ? tokens[5] : '1';

    final ranks = position.split('/');
    final mirroredRanks =
        ranks.reversed.map((rank) => _swapColorsInRank(rank)).toList();
    final mirroredPosition = mirroredRanks.join('/');

    final mirroredActiveColor = activeColor == 'w' ? 'b' : 'w';
    final mirroredCastling = _swapCastlingRights(castling);
    final mirroredEnPassant =
        enPassant != '-' ? _mirrorSquare(enPassant) : '-';

    return '$mirroredPosition $mirroredActiveColor $mirroredCastling $mirroredEnPassant $halfmove $fullmove';
  }

  static String _swapColorsInRank(String rank) {
    final buffer = StringBuffer();
    for (int i = 0; i < rank.length; i++) {
      final char = rank[i];
      if (char.toUpperCase() != char.toLowerCase()) {
        if (char == char.toUpperCase()) {
          buffer.write(char.toLowerCase());
        } else {
          buffer.write(char.toUpperCase());
        }
      } else {
        buffer.write(char);
      }
    }
    return buffer.toString();
  }

  static String _swapCastlingRights(String castling) {
    if (castling == '-') return '-';

    final rights = castling.split('').toSet();
    final swapped = <String>{};

    if (rights.contains('K')) swapped.add('k');
    if (rights.contains('Q')) swapped.add('q');
    if (rights.contains('k')) swapped.add('K');
    if (rights.contains('q')) swapped.add('Q');

    final buffer = StringBuffer();
    if (swapped.contains('K')) buffer.write('K');
    if (swapped.contains('Q')) buffer.write('Q');
    if (swapped.contains('k')) buffer.write('k');
    if (swapped.contains('q')) buffer.write('q');

    return buffer.isNotEmpty ? buffer.toString() : '-';
  }

  static String _mirrorSquare(String square) {
    final file = square[0];
    final rank = int.parse(square[1]);
    return '$file${9 - rank}';
  }

  static String mirrorMove(String moveUci) {
    final startSquare = moveUci.substring(0, 2);
    final endSquare = moveUci.substring(2, 4);
    final promotion = moveUci.length > 4 ? moveUci.substring(4) : '';

    return '${_mirrorSquare(startSquare)}${_mirrorSquare(endSquare)}$promotion';
  }

  static String getMoveFromIndex(int index) {
    return _allMovesReversed[index] ?? '';
  }
}
