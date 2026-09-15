/// Maia-3 tensor preprocessing.
///
/// Board encoding: (64, 12) per-square one-hot piece channels.
/// Elo: continuous float (not categorical).
/// Move vocabulary: 4352 (64×64 grid + 256 promotions).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/services.dart';

import '../../utils/chess_utils.dart' show toStandardUci;
import '../../utils/fen_utils.dart';
import '../../utils/log.dart';

/// Piece letters in channel order: indices 0-11 of a square's one-hot vector.
const String _kPieceChannels = 'PNBRQKpnbrqk';

const int _kSquares = 64;
const int _kChannels = 12;

/// Thrown when a position cannot be encoded for the network.
class MaiaInputException implements Exception {
  const MaiaInputException(this.message);
  final String message;

  @override
  String toString() => 'MaiaInputException: $message';
}

/// What the network is fed for one position.
///
/// Maia-3 only ever sees White to move: for Black the position is mirrored
/// ([MaiaTensor.mirrorFEN]) and [isBlack] tells the caller to mirror the
/// policy back.
class MaiaInput {
  const MaiaInput({
    required this.boardInput,
    required this.eloSelf,
    required this.eloOppo,
    required this.legalMoves,
    required this.isBlack,
  });

  /// `(64, 12)` one-hot board, flattened.
  final Float32List boardInput;
  final double eloSelf;
  final double eloOppo;

  /// 1.0 at the vocabulary index of every legal move, in standard UCI.
  final Float32List legalMoves;
  final bool isBlack;
}

class MaiaTensor {
  static Map<String, int> _allMoves = {};
  static Map<int, String> _allMovesReversed = {};
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;

    try {
      final movesJson = await rootBundle.loadString(
        'assets/data/all_moves_maia3.json',
      );
      final movesRevJson = await rootBundle.loadString(
        'assets/data/all_moves_maia3_reversed.json',
      );

      final movesMap = json.decode(movesJson) as Map<String, dynamic>;
      _allMoves = movesMap.map((key, value) => MapEntry(key, value as int));

      final movesRevMap = json.decode(movesRevJson) as Map<String, dynamic>;
      _allMovesReversed = movesRevMap.map(
        (key, value) => MapEntry(int.parse(key), value as String),
      );

      _initialized = true;
    } catch (e) {
      log.e('Failed to load Maia move data: $e');
    }
  }

  /// Maia-3 board tensor: (64, 12) flattened = 768 floats.
  /// Each square gets a 12-element one-hot vector for the piece on it.
  /// Piece order: P,N,B,R,Q,K,p,n,b,r,q,k (indices 0-11).
  static Float32List boardToMaia3Tokens(String fen) {
    final tensor = Float32List(_kSquares * _kChannels);
    final rows = fen.split(' ')[0].split('/');

    for (var rank = 0; rank < 8; rank++) {
      final row = 7 - rank;
      var file = 0;
      for (final char in rows[rank].split('')) {
        final digit = int.tryParse(char);
        if (digit != null) {
          file += digit;
          continue;
        }
        final channel = _kPieceChannels.indexOf(char);
        if (channel >= 0) {
          tensor[(row * 8 + file) * _kChannels + channel] = 1.0;
        }
        file++;
      }
    }

    return tensor;
  }

  /// Encode [fen] for the network, mirrored when Black is to move.
  ///
  /// Throws [StateError] before [init] and [MaiaInputException] for a FEN
  /// dartchess rejects.
  static MaiaInput preprocess(String fen, int eloSelf, int eloOppo) {
    if (!_initialized) throw StateError('MaiaTensor not initialized');

    // Parsed before mirroring: a malformed FEN fails here with a clear
    // message rather than inside the mirror's field indexing.
    var position = _parsePosition(fen, isMirrored: false);
    final isBlack = !isWhiteToMove(fen);
    final processedFen = isBlack ? mirrorFEN(fen) : fen;
    if (isBlack) position = _parsePosition(processedFen, isMirrored: true);

    return MaiaInput(
      boardInput: boardToMaia3Tokens(processedFen),
      eloSelf: eloSelf.toDouble(),
      eloOppo: eloOppo.toDouble(),
      legalMoves: _legalMoveMask(position),
      isBlack: isBlack,
    );
  }

  static Position _parsePosition(String fen, {required bool isMirrored}) {
    try {
      return Chess.fromSetup(Setup.parseFen(fen));
    } on Exception {
      final label = isMirrored ? 'Invalid mirrored FEN' : 'Invalid FEN';
      throw MaiaInputException('$label: $fen');
    }
  }

  /// 1.0 at the vocabulary index of every legal move of [position].
  ///
  /// dartchess encodes castling as king→own-rook (e1h1), but the Maia move
  /// vocabulary uses the standard king→destination encoding (e1g1). We set
  /// the mask at the standard index so the model's trained castling logit is
  /// read, and the returned policy keys also use standard UCI so callers
  /// (tree builder, engine pane, audit) can look them up directly with the
  /// Stockfish/Lichess convention most of the app uses.
  static Float32List _legalMoveMask(Position position) {
    final mask = Float32List(_allMoves.length);
    void mark(String uci) {
      final index = _allMoves[uci];
      if (index != null) mask[index] = 1.0;
    }

    for (final entry in position.legalMoves.entries) {
      final from = entry.key;
      final piece = position.board.pieceAt(from);
      for (final to in entry.value.squares) {
        if (piece != null && _isPromotion(piece, to)) {
          for (final role in _promotionRoles) {
            mark('${from.name}${to.name}${_roleToUciChar(role)}');
          }
        } else {
          mark(toStandardUci(position, from, to));
        }
      }
    }
    return mask;
  }

  static const _promotionRoles = [
    Role.queen,
    Role.rook,
    Role.bishop,
    Role.knight,
  ];

  static bool _isPromotion(Piece piece, Square to) =>
      piece.role == Role.pawn &&
      ((piece.color == Side.white && to ~/ 8 == 7) ||
          (piece.color == Side.black && to ~/ 8 == 0));

  static String _roleToUciChar(Role role) => switch (role) {
    Role.queen => 'q',
    Role.rook => 'r',
    Role.bishop => 'b',
    Role.knight => 'n',
    Role.pawn || Role.king => '',
  };

  // --- Mirroring Logic ---

  /// The same position with the colours swapped and the board flipped, so
  /// the side to move becomes White.
  static String mirrorFEN(String fen) {
    final tokens = fen.split(' ');
    final position = tokens[0];
    final activeColor = tokens[1];
    final castling = tokens[2];
    final enPassant = tokens[3];
    final halfmove = tokens.length > 4 ? tokens[4] : '0';
    final fullmove = tokens.length > 5 ? tokens[5] : '1';

    final mirroredPosition = position
        .split('/')
        .reversed
        .map(_swapColorsInRank)
        .join('/');
    final mirroredActiveColor = activeColor == 'w' ? 'b' : 'w';
    final mirroredCastling = _swapCastlingRights(castling);
    final mirroredEnPassant = enPassant != '-' ? _mirrorSquare(enPassant) : '-';

    return '$mirroredPosition $mirroredActiveColor $mirroredCastling '
        '$mirroredEnPassant $halfmove $fullmove';
  }

  static String _swapColorsInRank(String rank) {
    final buffer = StringBuffer();
    for (final char in rank.split('')) {
      final upper = char.toUpperCase();
      final lower = char.toLowerCase();
      if (upper == lower) {
        buffer.write(char);
      } else {
        buffer.write(char == upper ? lower : upper);
      }
    }
    return buffer.toString();
  }

  /// `KQkq` order is preserved after swapping each side's rights.
  static String _swapCastlingRights(String castling) {
    if (castling == '-') return '-';
    final swapped = [
      if (castling.contains('k')) 'K',
      if (castling.contains('q')) 'Q',
      if (castling.contains('K')) 'k',
      if (castling.contains('Q')) 'q',
    ].join();
    return swapped.isEmpty ? '-' : swapped;
  }

  static String _mirrorSquare(String square) {
    final file = square[0];
    final rank = int.parse(square[1]);
    return '$file${9 - rank}';
  }

  /// The move [moveUci] as played on the mirrored board.
  static String mirrorMove(String moveUci) {
    final startSquare = moveUci.substring(0, 2);
    final endSquare = moveUci.substring(2, 4);
    final promotion = moveUci.length > 4 ? moveUci.substring(4) : '';

    return '${_mirrorSquare(startSquare)}${_mirrorSquare(endSquare)}$promotion';
  }

  /// The vocabulary move at [index], or '' when out of range.
  static String getMoveFromIndex(int index) => _allMovesReversed[index] ?? '';
}
