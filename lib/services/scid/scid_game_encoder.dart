/// Encodes one game into Scid's game-data blob — the payload stored in
/// `.sg4` / `.sg5`, which is byte-identical between the two format versions.
///
/// Layout (`Game::Encode`, `src/game.cpp:2932-2950`):
///
///   1. the tag pairs that the index does *not* hold, terminated by a 0 byte
///   2. one start-board flags byte, plus a NUL-terminated FEN when the game
///      does not start from the standard position
///   3. the move list, terminated by the end-game token
///   4. the comments, each NUL-terminated, in move-list order
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dartchess/dartchess.dart';

import 'scid_home_pawns.dart';
import 'scid_move_codec.dart';
import 'scid_piece_list.dart';

/// Tags Scid lifts out of the blob and into the index or the namebase, so
/// they must not be written again as ordinary tag pairs.
///
/// `src/pgnparse.h:273-330` plus the seven-tag roster. `Setup`/`SetUp` is
/// deliberately absent: Scid keeps it as a tag.
const Set<String> kScidIndexedTags = {
  'Event',
  'Site',
  'Date',
  'Round',
  'White',
  'Black',
  'Result',
  'ECO',
  'FEN',
  'EventDate',
  'ScidFlags',
  'WhiteElo',
  'BlackElo',
};

/// Tags that get a one-byte code instead of their name, in code order from
/// 241 (`src/bytebuf.h:50-65`).
const List<String> kScidCommonTags = [
  'WhiteCountry', // 241
  'BlackCountry', // 242
  'Annotator', // 243
  'PlyCount', // 244
  'EventDate', // 245
  'Opening', // 246
  'Variation', // 247
  'Setup', // 248
  'Source', // 249
  'SetUp', // 250
];

const int _maxTagNameLen = 240;
const int _maxTagValueLen = 255;
const int _firstCommonTagCode = 241;

/// Start-board flag bits (`src/game.cpp`, `Game::Encode`).
const int _flagNonStandardStart = 0x01;
const int _flagPromotion = 0x02;
const int _flagUnderPromotion = 0x04;

/// The SAN spellings of a null move.
const Set<String> _nullMoveSans = {'--', 'Z0', '0000', '@@@@'};

/// What encoding a game produced, beyond the bytes: the counts and flags the
/// index record needs.
class ScidEncodedGame {
  const ScidEncodedGame({
    required this.data,
    required this.plyCount,
    required this.commentCount,
    required this.variationCount,
    required this.nagCount,
    required this.hasPromotion,
    required this.hasUnderPromotion,
    required this.nonStandardStart,
    required this.finalMaterial,
    required this.homePawnData,
    required this.homePawnCount,
    this.truncatedAt,
  });

  final Uint8List data;
  final int plyCount;
  final int commentCount;
  final int variationCount;
  final int nagCount;
  final bool hasPromotion;
  final bool hasUnderPromotion;
  final bool nonStandardStart;

  /// 24-bit material signature of the final mainline position.
  final int finalMaterial;

  /// Nine bytes: the count, then up to 16 half-byte entries recording which
  /// home pawns left, in order ([ScidHomePawnTracker.toBytes]).
  final Uint8List homePawnData;
  final int homePawnCount;

  /// Set when a move could not be encoded and the line was cut there — an
  /// illegal move in the source PGN, which dartchess's parser accepts as a
  /// token but no board can play. Scid's own importer stops at the same
  /// point; this makes it reportable instead of silent.
  final String? truncatedAt;
}

/// Thrown when a game cannot be represented in Scid's encoding.
class ScidEncodeException implements Exception {
  ScidEncodeException(this.message);
  final String message;
  @override
  String toString() => 'ScidEncodeException: $message';
}

class _Writer {
  final BytesBuilder _b = BytesBuilder(copy: false);
  void byte(int v) => _b.addByte(v & 0xFF);
  void bytes(List<int> v) => _b.add(v);
  Uint8List take() => _b.takeBytes();
}

/// Encodes a parsed PGN game.
class ScidGameEncoder {
  /// Encode [game], starting from its `FEN` tag when `SetUp` says so and
  /// from the standard position otherwise.
  static ScidEncodedGame encode(PgnGame<PgnNodeData> game) {
    final headers = game.headers;
    final start = _startPosition(headers);
    final nonStandardStart = start.fen != Chess.initial.fen;

    final w = _Writer();

    // ── 1. tag pairs not held by the index ──────────────────────────────
    _writeTags(w, headers);

    // ── walk the move tree, collecting bytes and comments ───────────────
    final state = _EncodeState(
      pieces: nonStandardStart
          ? ScidPieceList.fromPosition(start)
          : ScidPieceList.standard(),
      position: start,
    );
    final walk = _MoveWalk(
      homePawns: ScidHomePawnTracker(enabled: !nonStandardStart),
    );
    walk.walkGame(game, state);

    // ── 2. start-board flags (+ FEN) ────────────────────────────────────
    var flags = 0;
    if (nonStandardStart) flags |= _flagNonStandardStart;
    if (walk.hasPromotion) flags |= _flagPromotion;
    if (walk.hasUnderPromotion) flags |= _flagUnderPromotion;
    w.byte(flags);
    if (nonStandardStart) {
      w.bytes(utf8.encode(start.fen));
      w.byte(0);
    }

    // ── 3. moves, 4. comments ───────────────────────────────────────────
    w.bytes(walk.moveBytes);
    for (final c in walk.comments) {
      w.bytes(utf8.encode(c));
      w.byte(0);
    }

    return ScidEncodedGame(
      data: w.take(),
      plyCount: walk.mainlinePly,
      commentCount: walk.comments.length,
      variationCount: walk.variationCount,
      nagCount: walk.nagCount,
      hasPromotion: walk.hasPromotion,
      hasUnderPromotion: walk.hasUnderPromotion,
      nonStandardStart: nonStandardStart,
      finalMaterial: materialSignature(walk.finalMainlinePosition ?? start),
      homePawnData: walk.homePawns.toBytes(),
      homePawnCount: walk.homePawns.count,
      truncatedAt: walk.truncatedAt,
    );
  }

  /// The game's initial position: its `FEN` tag when `SetUp` (or `Setup`)
  /// is `1`, else the standard start.
  static Position _startPosition(PgnHeaders headers) {
    final fen = headers['FEN'];
    final setup = headers['SetUp'] ?? headers['Setup'];
    if (setup != '1' || fen == null || fen.trim().isEmpty) {
      return Chess.initial;
    }
    try {
      return Chess.fromSetup(Setup.parseFen(fen));
    } catch (e) {
      throw ScidEncodeException('unparsable FEN: $e');
    }
  }

  /// Section 1: every tag the index does not hold, common ones as a single
  /// code byte, the rest as a length-prefixed name; values are
  /// length-prefixed and capped at 255 bytes.
  static void _writeTags(_Writer w, PgnHeaders headers) {
    for (final entry in headers.entries) {
      if (kScidIndexedTags.contains(entry.key)) continue;
      if (entry.key.isEmpty) continue;
      final commonIndex = kScidCommonTags.indexOf(entry.key);
      if (commonIndex >= 0) {
        w.byte(_firstCommonTagCode + commonIndex);
      } else {
        _writeCapped(w, utf8.encode(entry.key), _maxTagNameLen);
      }
      _writeCapped(w, utf8.encode(entry.value), _maxTagValueLen);
    }
    w.byte(0); // end of tag section
  }

  static void _writeCapped(_Writer w, List<int> bytes, int cap) {
    final len = bytes.length > cap ? cap : bytes.length;
    w.byte(len);
    w.bytes(bytes.sublist(0, len));
  }

  static String? _joinComments(List<String>? comments) {
    if (comments == null || comments.isEmpty) return null;
    final joined = comments.where((c) => c.isNotEmpty).join(' ');
    return joined.isEmpty ? null : joined;
  }
}

/// Position plus piece list, carried down one line of the tree.
class _EncodeState {
  _EncodeState({required this.pieces, required this.position});
  ScidPieceList pieces;
  Position position;

  _EncodeState clone() =>
      _EncodeState(pieces: pieces.clone(), position: position);
}

/// Walks a game's move tree in PGN order, emitting the move-list bytes and
/// collecting the comment texts in the order their markers were written.
class _MoveWalk {
  _MoveWalk({required this.homePawns});

  final _Writer _out = _Writer();
  final List<String> comments = [];
  final ScidHomePawnTracker homePawns;

  int variationCount = 0;
  int nagCount = 0;
  int mainlinePly = 0;
  String? truncatedAt;
  bool hasPromotion = false;
  bool hasUnderPromotion = false;
  Position? finalMainlinePosition;

  /// The move list, once [walkGame] has run.
  Uint8List get moveBytes => _out.take();

  /// Encode the whole game: a pre-game comment marker first, then the tree,
  /// then the end-game token.
  void walkGame(PgnGame<PgnNodeData> game, _EncodeState state) {
    _emitComment(ScidGameEncoder._joinComments(game.comments));
    _walkChildren(game.moves.children, state);
    _out.byte(ScidToken.endGame);
  }

  void _emitNags(List<int>? nags) {
    if (nags == null) return;
    for (final n in nags) {
      _out.byte(ScidToken.nag);
      _out.byte(n & 0xFF);
      nagCount++;
    }
  }

  /// Mark that a comment belongs here; the text itself goes after the moves.
  void _emitComment(String? comment) {
    if (comment == null) return;
    _out.byte(ScidToken.comment);
    comments.add(comment);
  }

  /// Walk a node's children in PGN order: the first child is the line, the
  /// rest are variations wrapped in start/end markers.
  void _walkChildren(
    List<PgnChildNode<PgnNodeData>> children,
    _EncodeState state, {
    bool mainline = true,
  }) {
    var current = children;
    var st = state;
    while (current.isNotEmpty) {
      final first = current.first;

      // Snapshot BEFORE the move: a variation is an alternative *to* this
      // move, so it has to branch from the position the move was played in,
      // not the one it produced. Cloning afterwards silently encoded every
      // variation from the wrong board.
      final beforeMove = current.length > 1 ? st.clone() : null;

      // The move itself.
      final next = _emitMove(first.data, st, mainline: mainline);
      if (next == null) return;

      // NAGs and comment marker belong to the move just written.
      _emitNags(first.data.nags);
      _emitComment(ScidGameEncoder._joinComments(first.data.comments));

      // Sibling variations, each a fresh branch from the pre-move state.
      for (var i = 1; i < current.length; i++) {
        _walkVariation(current[i], beforeMove!.clone());
      }

      st = next;
      if (mainline) {
        mainlinePly++;
        finalMainlinePosition = st.position;
      }
      current = first.children;
    }
  }

  /// One variation between its start/end markers.  Its first move's comment
  /// is marked before its NAGs — the reverse of a line move — because that
  /// is the order Scid's traversal writes them.  An unencodable first move
  /// leaves the variation empty rather than corrupting the stream.
  void _walkVariation(PgnChildNode<PgnNodeData> node, _EncodeState branch) {
    variationCount++;
    _out.byte(ScidToken.startVariation);
    final emitted = _emitMove(node.data, branch, mainline: false);
    if (emitted != null) {
      _emitComment(ScidGameEncoder._joinComments(node.data.comments));
      _emitNags(node.data.nags);
      _walkChildren(node.children, branch, mainline: false);
    }
    _out.byte(ScidToken.endVariation);
  }

  /// Emit one move, advancing [state]. Returns the new state, or null when the
  /// move cannot be played (a malformed PGN), which ends the line.
  _EncodeState? _emitMove(
    PgnNodeData data,
    _EncodeState state, {
    required bool mainline,
  }) {
    final san = data.san;
    final before = state.position;

    // Null moves are a king "move" to its own square.
    if (_nullMoveSans.contains(san)) {
      _out.byte(scidMoveByte(0, ScidToken.nullMove));
      state.position = before.copyWith(turn: before.turn.opposite);
      return state;
    }

    final Move? move;
    try {
      move = before.parseSan(san);
    } catch (_) {
      truncatedAt ??= '$san (unparsable)';
      return null;
    }
    if (move == null || move is! NormalMove) {
      truncatedAt ??= '$san (illegal here)';
      return null;
    }

    final from = move.from;
    final to = move.to;
    final piece = before.board.pieceAt(from);
    if (piece == null) return null;

    final slot = state.pieces.slotOf(from);
    if (slot < 0) {
      truncatedAt ??= '$san (piece list desync at square $from)';
      return null;
    }

    // Castling: dartchess encodes it king-onto-rook; Scid wants the king's
    // nominal two-square shift, and moves the rook separately.
    final destPiece = before.board.pieceAt(to);
    final isCastle =
        piece.role == Role.king &&
        destPiece != null &&
        destPiece.role == Role.rook &&
        destPiece.color == piece.color;

    int? rookFrom;
    int? rookTo;
    int kingTo = to;
    if (isCastle) {
      final kingside = to > from;
      kingTo = kingside ? from + 2 : from - 2;
      rookFrom = to;
      rookTo = kingside ? kingTo - 1 : kingTo + 1;
    }

    final promo = move.promotion;
    if (promo != null && mainline) {
      // Scid derives these from the mainline only (`mainlineInfo`), and an
      // under-promotion sets *both* flags.
      hasPromotion = true;
      if (promo != Role.queen) hasUnderPromotion = true;
    }

    _writeMoveBytes(piece.role, slot, from, to, kingTo: kingTo, promo: promo);

    // Advance the position, then the piece list to match.
    final Position after;
    try {
      after = before.play(move);
    } catch (_) {
      return null;
    }

    state.pieces.applyMove(
      mover: piece.color,
      from: from,
      to: isCastle ? kingTo : to,
      capturedSquare: isCastle
          ? null
          : _capturedSquare(piece, from, to, destPiece),
      castleRookFrom: rookFrom,
      castleRookTo: rookTo,
    );
    state.position = after;
    if (mainline) homePawns.noteMove(after);
    return state;
  }

  void _writeMoveBytes(
    Role role,
    int slot,
    int from,
    int to, {
    required int kingTo,
    required Role? promo,
  }) {
    switch (role) {
      case Role.king:
        _out.byte(scidMoveByte(slot, encodeKingCode(from, kingTo)));
      case Role.queen:
        final enc = encodeQueenMove(slot, from, to);
        _out.byte(enc.first);
        final second = enc.second;
        if (second != null) _out.byte(second);
      case Role.rook:
        _out.byte(scidMoveByte(slot, encodeRookCode(from, to)));
      case Role.bishop:
        _out.byte(scidMoveByte(slot, encodeBishopCode(from, to)));
      case Role.knight:
        _out.byte(scidMoveByte(slot, encodeKnightCode(from, to)));
      case Role.pawn:
        _out.byte(
          scidMoveByte(slot, encodePawnCode(from, to, _promoIndex(promo))),
        );
    }
  }

  /// The square of the piece a non-castling move captures, if any.  An en
  /// passant capture takes the pawn on the mover's own rank.
  static int? _capturedSquare(Piece piece, int from, int to, Piece? destPiece) {
    if (destPiece != null && destPiece.color != piece.color) return to;
    final isDiagonalPawnMove =
        piece.role == Role.pawn && (from & 7) != (to & 7);
    if (isDiagonalPawnMove && destPiece == null) return (from & ~7) | (to & 7);
    return null;
  }

  static int _promoIndex(Role? promo) => switch (promo) {
    Role.queen => 1,
    Role.rook => 2,
    Role.bishop => 3,
    Role.knight => 4,
    Role.king || Role.pawn || null => 0,
  };
}

// ── material signature ──────────────────────────────────────────────────────

const int _shiftBp = 0;
const int _shiftBn = 4;
const int _shiftBb = 6;
const int _shiftBr = 8;
const int _shiftBq = 10;
const int _shiftWp = 12;
const int _shiftWn = 16;
const int _shiftWb = 18;
const int _shiftWr = 20;
const int _shiftWq = 22;

/// Scid's 24-bit material signature (`src/matsig.h:27-33`).
///
/// Pawns get 4 bits (0-8); every other piece gets 2 (counts saturate at 3).
/// Used to reject, without decoding, a game whose final material has fewer of
/// some piece than a searched position needs — material only ever decreases.
int materialSignature(Position position) {
  int countOf(Side side, Role role) => position.board.piecesOf(side, role).size;
  int cap(int n) => n > 3 ? 3 : n;
  int capPawns(int n) => n > 8 ? 8 : n;

  return (capPawns(countOf(Side.black, Role.pawn)) << _shiftBp) |
      (cap(countOf(Side.black, Role.knight)) << _shiftBn) |
      (cap(countOf(Side.black, Role.bishop)) << _shiftBb) |
      (cap(countOf(Side.black, Role.rook)) << _shiftBr) |
      (cap(countOf(Side.black, Role.queen)) << _shiftBq) |
      (capPawns(countOf(Side.white, Role.pawn)) << _shiftWp) |
      (cap(countOf(Side.white, Role.knight)) << _shiftWn) |
      (cap(countOf(Side.white, Role.bishop)) << _shiftWb) |
      (cap(countOf(Side.white, Role.rook)) << _shiftWr) |
      (cap(countOf(Side.white, Role.queen)) << _shiftWq);
}
