import 'dart:convert';
import 'dart:typed_data';
import 'package:chess/chess.dart' as chess;
import 'package:flutter/services.dart';

class MaiaTensor {
  static Map<String, int> _allMoves = {};
  static Map<int, String> _allMovesReversed = {};
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;

    try {
      final movesJson = await rootBundle.loadString('assets/data/all_moves.json');
      final movesRevJson = await rootBundle.loadString('assets/data/all_moves_reversed.json');

      final Map<String, dynamic> movesMap = json.decode(movesJson);
      _allMoves = movesMap.map((key, value) => MapEntry(key, value as int));

      final Map<String, dynamic> movesRevMap = json.decode(movesRevJson);
      _allMovesReversed = movesRevMap.map((key, value) => MapEntry(int.parse(key), value as String));

      _initialized = true;
    } catch (e) {
      print('Failed to load Maia move data: $e');
    }
  }

  static Float32List boardToTensor(String fen) {
    final tokens = fen.split(' ');
    final piecePlacement = tokens[0];
    final activeColor = tokens[1];
    final castlingAvailability = tokens[2];
    final enPassantTarget = tokens[3];

    const pieceTypes = [
      'P', 'N', 'B', 'R', 'Q', 'K',
      'p', 'n', 'b', 'r', 'q', 'k'
    ];

    // 18 channels: 12 for pieces, 1 for turn, 4 for castling, 1 for en passant
    final tensor = Float32List((12 + 6) * 8 * 8);

    final rows = piecePlacement.split('/');

    // Fill piece channels (0-11)
    for (int rank = 0; rank < 8; rank++) {
      final row = 7 - rank;
      int file = 0;
      for (int i = 0; i < rows[rank].length; i++) {
        final char = rows[rank][i];
        if (int.tryParse(char) != null) {
          file += int.parse(char);
        } else {
          final index = pieceTypes.indexOf(char);
          if (index != -1) {
            final tensorIndex = index * 64 + row * 8 + file;
            tensor[tensorIndex] = 1.0;
          }
          file += 1;
        }
      }
    }

    // Channel 12: Turn (White = 1.0, Black = 0.0)
    final turnChannelStart = 12 * 64;
    final turnValue = activeColor == 'w' ? 1.0 : 0.0;
    for (int i = turnChannelStart; i < turnChannelStart + 64; i++) {
      tensor[i] = turnValue;
    }

    // Channel 13-16: Castling Rights
    final rights = [
      castlingAvailability.contains('K'),
      castlingAvailability.contains('Q'),
      castlingAvailability.contains('k'),
      castlingAvailability.contains('q')
    ];

    for (int i = 0; i < 4; i++) {
      if (rights[i]) {
        final channelStart = (13 + i) * 64;
        for (int j = channelStart; j < channelStart + 64; j++) {
          tensor[j] = 1.0;
        }
      }
    }

    // Channel 17: En Passant Target
    final epChannelStart = 17 * 64;
    if (enPassantTarget != '-') {
      final file = enPassantTarget.codeUnitAt(0) - 'a'.codeUnitAt(0);
      final rank = int.parse(enPassantTarget[1]) - 1;
      final row = 7 - rank; // Invert rank to match tensor indexing (0 is bottom/rank 1)
      // Note: The TS code does 'row = 7 - rank' and 'rank = parseInt(...) - 1'.
      // If target is e3 (rank 2, index 2), rank var is 2. row = 7-2 = 5.
      // Let's double check TS logic:
      // const rank = parseInt(enPassantTarget[1], 10) - 1 // '3' -> 2
      // const row = 7 - rank // 7 - 2 = 5
      // Wait, chess board usually rank 0 is 1. 
      // Let's stick to porting the TS logic exactly.
      
      // TS: const index = epChannel + row * 8 + file
      final index = epChannelStart + row * 8 + file;
      if (index >= epChannelStart && index < epChannelStart + 64) {
        tensor[index] = 1.0;
      }
    }

    return tensor;
  }

  static Map<String, dynamic> preprocess(String fen, int eloSelf, int eloOppo) {
    if (!_initialized) throw Exception('MaiaTensor not initialized');

    // Handle mirroring if it's black's turn
    // The model is trained on White's perspective
    chess.Chess board = chess.Chess.fromFEN(fen);
    bool isBlack = fen.split(' ')[1] == 'b';
    
    String processedFen = fen;
    if (isBlack) {
      processedFen = mirrorFEN(fen);
      board = chess.Chess.fromFEN(processedFen);
    }

    // Convert board to tensor
    final boardInput = boardToTensor(processedFen);

    // Map Elo to categories
    final eloDict = _createEloDict();
    final eloSelfCategory = _mapToCategory(eloSelf, eloDict);
    final eloOppoCategory = _mapToCategory(eloOppo, eloDict);

    // Generate legal moves tensor (mask)
    // Size should match the output size of the model (all possible moves)
    final legalMoves = Float32List(_allMoves.length);
    final moves = board.moves(); // Returns List<dynamic> (strings or Move objects)
    
    // We need verbose moves to get from/to/promotion
    // dart-chess moves() returns simple algebraic san usually, 
    // but we need to generate legal moves and map them to indices.
    // Let's re-generate moves with our board object to get details.
    // Actually chess.dart generate_moves() returns Move objects.
    // Let's assume board.moves() gives us list of Move objects if we don't ask for SAN.
    // Checking chess.dart source or usage: board.generate_moves() is internal usually.
    // board.moves() returns List<Move> if input is not specified? No, usually SAN strings.
    // We need UCI format: "e2e4".
    
    // Workaround: iterate all generated moves
    for (final move in board.generate_moves()) {
      final from = move.fromAlgebraic;
      final to = move.toAlgebraic;
      final promotion = move.promotion != null ? move.promotion!.name : ''; // p, n, b, r, q? 
      // chess.dart PieceType.name returns 'p', 'n' etc.
      
      // Construct UCI
      final uci = '$from$to$promotion';
      
      if (_allMoves.containsKey(uci)) {
        final index = _allMoves[uci]!;
        legalMoves[index] = 1.0;
      }
    }

    return {
      'boardInput': boardInput,
      'eloSelfCategory': eloSelfCategory,
      'eloOppoCategory': eloOppoCategory,
      'legalMoves': legalMoves,
      'isBlack': isBlack, // Pass this along to un-mirror output
    };
  }

  static Map<String, int> _createEloDict() {
    const interval = 100;
    const start = 1100;
    const end = 2000;

    final Map<String, int> eloDict = {'<$start': 0};
    int rangeIndex = 1;

    for (int lowerBound = start; lowerBound < end; lowerBound += interval) {
      final upperBound = lowerBound + interval;
      eloDict['$lowerBound-${upperBound - 1}'] = rangeIndex;
      rangeIndex += 1;
    }

    eloDict['>=$end'] = rangeIndex;
    return eloDict;
  }

  static int _mapToCategory(int elo, Map<String, int> eloDict) {
    const interval = 100;
    const start = 1100;
    const end = 2000;

    if (elo < start) {
      return eloDict['<$start']!;
    } else if (elo >= end) {
      return eloDict['>=$end']!;
    } else {
      for (int lowerBound = start; lowerBound < end; lowerBound += interval) {
        final upperBound = lowerBound + interval;
        if (elo >= lowerBound && elo < upperBound) {
          return eloDict['$lowerBound-${upperBound - 1}']!;
        }
      }
    }
    throw Exception('Elo value is out of range.');
  }

  // --- Mirroring Logic (Ported from TS) ---

  static String mirrorFEN(String fen) {
    final tokens = fen.split(' ');
    final position = tokens[0];
    final activeColor = tokens[1];
    final castling = tokens[2];
    final enPassant = tokens[3];
    final halfmove = tokens.length > 4 ? tokens[4] : '0';
    final fullmove = tokens.length > 5 ? tokens[5] : '1';

    final ranks = position.split('/');
    final mirroredRanks = ranks.reversed.map((rank) => _swapColorsInRank(rank)).toList();
    final mirroredPosition = mirroredRanks.join('/');

    final mirroredActiveColor = activeColor == 'w' ? 'b' : 'w';
    final mirroredCastling = _swapCastlingRights(castling);
    final mirroredEnPassant = enPassant != '-' ? _mirrorSquare(enPassant) : '-';

    return '$mirroredPosition $mirroredActiveColor $mirroredCastling $mirroredEnPassant $halfmove $fullmove';
  }

  static String _swapColorsInRank(String rank) {
    final buffer = StringBuffer();
    for (int i = 0; i < rank.length; i++) {
      final char = rank[i];
      if (char.toUpperCase() != char.toLowerCase()) {
        // It's a letter
        if (char == char.toUpperCase()) {
          buffer.write(char.toLowerCase());
        } else {
          buffer.write(char.toUpperCase());
        }
      } else {
        // Number or other
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







