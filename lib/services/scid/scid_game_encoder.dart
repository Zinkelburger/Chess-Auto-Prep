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
const int _firstCommonTagCode = 241;

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

  /// Up to 16 half-byte entries recording which home pawns left, in order.
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
  int get length => _b.length;
  Uint8List take() => _b.takeBytes();
}

/// Encodes a parsed PGN game.
class ScidGameEncoder {
  /// Encode [game]. [startPosition] must be the game's initial position.
  static ScidEncodedGame encode(PgnGame<PgnNodeData> game) {
    final headers = game.headers;
    final fen = headers['FEN'];
    final setup = headers['SetUp'] ?? headers['Setup'];
    final hasFenStart = setup == '1' && fen != null && fen.trim().isNotEmpty;

    final Position start;
    if (hasFenStart) {
      try {
        start = Chess.fromSetup(Setup.parseFen(fen));
      } catch (e) {
        throw ScidEncodeException('unparsable FEN: $e');
      }
    } else {
      start = Chess.initial;
    }

    final nonStandardStart = hasFenStart && start.fen != Chess.initial.fen;

    final w = _Writer();

    // ── 1. tag pairs not held by the index ──────────────────────────────
    for (final entry in headers.entries) {
      if (kScidIndexedTags.contains(entry.key)) continue;
      if (entry.key.isEmpty) continue;
      final commonIndex = kScidCommonTags.indexOf(entry.key);
      if (commonIndex >= 0) {
        w.byte(_firstCommonTagCode + commonIndex);
      } else {
        final name = utf8.encode(entry.key);
        final len = name.length > _maxTagNameLen ? _maxTagNameLen : name.length;
        w.byte(len);
        w.bytes(name.sublist(0, len));
      }
      final value = utf8.encode(entry.value);
      final vlen = value.length > 255 ? 255 : value.length;
      w.byte(vlen);
      w.bytes(value.sublist(0, vlen));
    }
    w.byte(0); // end of tag section

    // ── walk the move tree, collecting bytes and comments ───────────────
    final state = _EncodeState(
      pieces: nonStandardStart
          ? ScidPieceList.fromPosition(start)
          : ScidPieceList.standard(),
      position: start,
    );
    final moveBytes = _Writer();
    final comments = <String>[];

    // A pre-game comment is marked before anything else.
    final preComment = _joinComments(game.comments);
    if (preComment != null) {
      moveBytes.byte(ScidToken.comment);
      comments.add(preComment);
    }

    final walk = _MoveWalk(moveBytes, comments)
      ..trackHomePawns = !nonStandardStart;
    walk.walkChildren(game.moves.children, state);
    moveBytes.byte(ScidToken.endGame);

    // ── 2. start-board flags (+ FEN) ────────────────────────────────────
    var flags = 0;
    if (nonStandardStart) flags |= 0x01;
    if (walk.hasPromotion) flags |= 0x02;
    if (walk.hasUnderPromotion) flags |= 0x04;
    w.byte(flags);
    if (nonStandardStart) {
      w.bytes(utf8.encode(start.fen));
      w.byte(0);
    }

    // ── 3. moves, 4. comments ───────────────────────────────────────────
    w.bytes(moveBytes.take());
    for (final c in comments) {
      w.bytes(utf8.encode(c));
      w.byte(0);
    }

    final hp = walk.homePawnBytes();
    return ScidEncodedGame(
      data: w.take(),
      plyCount: walk.mainlinePly,
      commentCount: comments.length,
      variationCount: walk.variationCount,
      nagCount: walk.nagCount,
      hasPromotion: walk.hasPromotion,
      hasUnderPromotion: walk.hasUnderPromotion,
      nonStandardStart: nonStandardStart,
      finalMaterial: materialSignature(walk.finalMainlinePosition ?? start),
      homePawnData: hp,
      homePawnCount: walk.homePawnCount,
      truncatedAt: walk.truncatedAt,
    );
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

class _MoveWalk {
  _MoveWalk(this._out, this._comments);

  final _Writer _out;
  final List<String> _comments;

  int variationCount = 0;
  int nagCount = 0;
  int mainlinePly = 0;
  String? truncatedAt;
  bool hasPromotion = false;
  bool hasUnderPromotion = false;
  Position? finalMainlinePosition;

  /// Home-pawn departures, in order, as Scid records them
  /// (`mainlineInfo`, `src/game.cpp`).
  ///
  /// A 16-bit signature starts at [_hpAllHome] — one bit per home square,
  /// **set while the pawn is still there** — and bits clear as pawns leave or
  /// are captured. After each mainline move the difference `old - new` names
  /// the square that changed, and the value stored is that difference's
  /// highest set bit *position*, i.e. `15 - index` where index is 0-7 for
  /// White a-h and 8-15 for Black a-h.
  ///
  /// Tracked for the mainline only, and only from the standard start: from a
  /// FEN there is no "home" to leave, and Scid leaves the count at zero.
  static const int _hpAllHome = 0xFFFF;
  int _hpSig = _hpAllHome;
  final List<int> _hpValues = [];
  bool trackHomePawns = true;

  int get homePawnCount => _hpValues.length;

  Uint8List homePawnBytes() {
    // Nine bytes: the count, then up to sixteen nibbles. The first departure
    // goes in the HIGH nibble of the first byte.
    final out = Uint8List(9);
    final n = _hpValues.length > 16 ? 16 : _hpValues.length;
    out[0] = n;
    for (var i = 0; i < n; i++) {
      final v = _hpValues[i] & 0x0F;
      out[1 + (i >> 1)] |= i.isEven ? v << 4 : v;
    }
    return out;
  }

  /// The signature of [pos]: a bit set for every home square still holding
  /// its own pawn.
  static int _hpSigOf(Position pos) {
    var sig = 0;
    for (var file = 0; file < 8; file++) {
      final w = pos.board.pieceAt(Square(8 + file));
      if (w != null && w.role == Role.pawn && w.color == Side.white) {
        sig |= 1 << (15 - file);
      }
      final b = pos.board.pieceAt(Square(48 + file));
      if (b != null && b.role == Role.pawn && b.color == Side.black) {
        sig |= 1 << (15 - (8 + file));
      }
    }
    return sig;
  }

  void _noteHomePawns(Position after) {
    if (!trackHomePawns) return;
    final now = _hpSigOf(after);
    final changed = _hpSig - now;
    if (changed <= 0) return;
    _hpSig = now;
    var idx = 0;
    var c = changed;
    while ((c >>= 1) != 0) {
      idx++;
    }
    if (_hpValues.length < 16) _hpValues.add(idx);
  }

  /// Walk a node's children in PGN order: the first child is the line, the
  /// rest are variations wrapped in start/end markers.
  void walkChildren(
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
      final nags = first.data.nags;
      if (nags != null) {
        for (final n in nags) {
          _out.byte(ScidToken.nag);
          _out.byte(n & 0xFF);
          nagCount++;
        }
      }
      final comment = ScidGameEncoder._joinComments(first.data.comments);
      if (comment != null) {
        _out.byte(ScidToken.comment);
        _comments.add(comment);
      }

      // Sibling variations, each a fresh branch from the pre-move state.
      for (var i = 1; i < current.length; i++) {
        variationCount++;
        _out.byte(ScidToken.startVariation);
        final branch = beforeMove!.clone();
        final varComment = ScidGameEncoder._joinComments(
          current[i].data.comments,
        );
        // A comment on the variation's first move is marked right after the
        // start marker in Scid's traversal.
        final saved = _out.length;
        final emitted = _emitMove(current[i].data, branch, mainline: false);
        if (emitted != null) {
          if (varComment != null) {
            _out.byte(ScidToken.comment);
            _comments.add(varComment);
          }
          final varNags = current[i].data.nags;
          if (varNags != null) {
            for (final n in varNags) {
              _out.byte(ScidToken.nag);
              _out.byte(n & 0xFF);
              nagCount++;
            }
          }
          walkChildren(current[i].children, branch, mainline: false);
        } else {
          // Unencodable variation: drop it rather than corrupt the stream.
          assert(saved <= _out.length);
        }
        _out.byte(ScidToken.endVariation);
      }

      st = next;
      if (mainline) {
        mainlinePly++;
        finalMainlinePosition = st.position;
      }
      current = first.children;
    }
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
    if (san == '--' || san == 'Z0' || san == '0000' || san == '@@@@') {
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

    // Write the byte(s).
    switch (piece.role) {
      case Role.king:
        _out.byte(scidMoveByte(slot, encodeKingCode(from, kingTo)));
        break;
      case Role.queen:
        final enc = encodeQueenMove(slot, from, to);
        _out.byte(enc.first);
        if (enc.second != null) _out.byte(enc.second!);
        break;
      case Role.rook:
        _out.byte(scidMoveByte(slot, encodeRookCode(from, to)));
        break;
      case Role.bishop:
        _out.byte(scidMoveByte(slot, encodeBishopCode(from, to)));
        break;
      case Role.knight:
        _out.byte(scidMoveByte(slot, encodeKnightCode(from, to)));
        break;
      case Role.pawn:
        _out.byte(
          scidMoveByte(slot, encodePawnCode(from, to, _promoIndex(promo))),
        );
        break;
    }

    // Advance the position, then the piece list to match.
    final Position after;
    try {
      after = before.play(move);
    } catch (_) {
      return null;
    }

    int? capturedSquare;
    if (!isCastle) {
      if (destPiece != null && destPiece.color != piece.color) {
        capturedSquare = to;
      } else if (piece.role == Role.pawn &&
          (from & 7) != (to & 7) &&
          destPiece == null) {
        // En passant: the captured pawn is on the mover's rank.
        capturedSquare = (from & ~7) | (to & 7);
      }
    }

    state.pieces.applyMove(
      mover: piece.color,
      from: from,
      to: isCastle ? kingTo : to,
      capturedSquare: capturedSquare,
      castleRookFrom: rookFrom,
      castleRookTo: rookTo,
    );
    state.position = after;
    if (mainline) _noteHomePawns(after);
    return state;
  }

  static int _promoIndex(Role? promo) => switch (promo) {
    null => 0,
    Role.queen => 1,
    Role.rook => 2,
    Role.bishop => 3,
    Role.knight => 4,
    _ => 0,
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
