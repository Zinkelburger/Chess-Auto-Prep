/**
 * san_convert.c - UCI to SAN conversion using chesslib
 *
 * Separate compilation unit to avoid the ChessPosition type name
 * collision between chess_logic.h and chesslib/position.h.
 */

#include "san_convert.h"
#include "chess.h"
#include "position.h"
#include "move.h"
#include "generate.h"
#include "fen.h"
#include "carray.h"

#include <string.h>
#include <stdlib.h>
#include <ctype.h>

static int piece_type(ChessPiece p) {
    return p / 2; /* 1=pawn 2=knight 3=bishop 4=rook 5=queen 6=king */
}

bool uci_to_san(const char *fen, const char *uci, char *san, size_t san_len) {
    if (!fen || !uci || !san || san_len < 12) return false;

    size_t len = strlen(uci);
    if (len < 4 || len > 5) return false;

    ChessPosition pos;
    if (!chess_fen_load(fen, &pos)) return false;

    ChessFile ff = chess_file_from_char(uci[0]);
    ChessRank fr = chess_rank_from_char(uci[1]);
    ChessFile tf = chess_file_from_char(uci[2]);
    ChessRank tr = chess_rank_from_char(uci[3]);
    if (ff < 0 || fr < 0 || tf < 0 || tr < 0) return false;

    ChessSquare from_sq = chess_square_from_fr(ff, fr);
    ChessSquare to_sq   = chess_square_from_fr(tf, tr);

    ChessMovePromote promo = CHESS_MOVE_PROMOTE_NONE;
    if (len == 5) promo = chess_move_promote_from_char(uci[4]);

    ChessMove move = (promo != CHESS_MOVE_PROMOTE_NONE)
        ? chess_move_make_promote(from_sq, to_sq, promo)
        : chess_move_make(from_sq, to_sq);

    ChessPiece piece = pos.piece[from_sq];
    if (piece == CHESS_PIECE_NONE) return false;

    bool is_capture = chess_position_move_is_capture(&pos, move);
    int pt = piece_type(piece);
    int idx = 0;

    /* Castling */
    if (pt == 6 && abs(tf - ff) == 2) {
        if (tf > ff) { memcpy(san, "O-O", 3); idx = 3; }
        else         { memcpy(san, "O-O-O", 5); idx = 5; }
        goto add_check;
    }

    /* Pawn */
    if (pt == 1) {
        if (is_capture)  {
            san[idx++] = chess_file_to_char(ff);
            san[idx++] = 'x';
        }
        san[idx++] = chess_file_to_char(tf);
        san[idx++] = chess_rank_to_char(tr);
        if (promo != CHESS_MOVE_PROMOTE_NONE) {
            san[idx++] = '=';
            san[idx++] = (char)toupper((unsigned char)
                             chess_move_promote_to_char(promo));
        }
        goto add_check;
    }

    /* Piece letter */
    san[idx++] = (char)toupper((unsigned char)chess_piece_to_char(piece));

    /* Disambiguation via legal move generation */
    {
        ChessArray moves;
        chess_array_init(&moves, sizeof(ChessMove));
        chess_generate_moves(&pos, &moves);

        bool need_file = false, need_rank = false;
        for (size_t i = 0; i < chess_array_size(&moves); i++) {
            ChessMove other = *(const ChessMove *)chess_array_elem(&moves, i);
            if (other == move) continue;
            if (chess_move_to(other) != to_sq) continue;
            ChessSquare of = chess_move_from(other);
            if (pos.piece[of] != piece) continue;
            ChessFile ofile = chess_square_file(of);
            ChessRank orank = chess_square_rank(of);
            if (ofile != ff)       need_file = true;
            else if (orank != fr)  need_rank = true;
            else                 { need_file = true; need_rank = true; }
        }
        chess_array_cleanup(&moves);

        if (need_file) san[idx++] = chess_file_to_char(ff);
        if (need_rank) san[idx++] = chess_rank_to_char(fr);
    }

    if (is_capture) san[idx++] = 'x';
    san[idx++] = chess_file_to_char(tf);
    san[idx++] = chess_rank_to_char(tr);

add_check:
    {
        ChessUnmove um = chess_position_make_move(&pos, move);
        if (chess_position_is_check(&pos)) {
            ChessResult result = chess_position_check_result(&pos);
            san[idx++] = (result == CHESS_RESULT_WHITE_WINS ||
                          result == CHESS_RESULT_BLACK_WINS)
                ? '#' : '+';
        }
        chess_position_undo_move(&pos, um);
    }

    san[idx] = '\0';
    return true;
}
