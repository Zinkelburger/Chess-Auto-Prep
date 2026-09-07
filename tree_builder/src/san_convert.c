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

    chess_generate_init();

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


static void chessmove_to_uci_str(ChessMove m, char *out) {
    ChessSquare from = chess_move_from(m);
    ChessSquare to   = chess_move_to(m);
    ChessMovePromote promo = chess_move_promotes(m);

    out[0] = chess_file_to_char(chess_square_file(from));
    out[1] = chess_rank_to_char(chess_square_rank(from));
    out[2] = chess_file_to_char(chess_square_file(to));
    out[3] = chess_rank_to_char(chess_square_rank(to));

    if (promo != CHESS_MOVE_PROMOTE_NONE) {
        out[4] = chess_move_promote_to_char(promo);
        out[5] = '\0';
    } else {
        out[4] = '\0';
    }
}

bool san_to_uci(const char *fen, const char *san_input,
                char *uci, size_t uci_len) {
    if (!fen || !san_input || !uci || uci_len < 8) return false;

    chess_generate_init();

    /* Strip optional move numbers: "1." "1..." "12." etc. */
    const char *san = san_input;
    while (*san >= '0' && *san <= '9') san++;
    while (*san == '.') san++;
    while (*san == ' ') san++;
    if (*san == '\0') return false;

    /* Strip trailing +/# for comparison (we add them in uci_to_san) */
    char clean[16];
    size_t slen = strlen(san);
    if (slen >= sizeof(clean)) return false;
    memcpy(clean, san, slen + 1);
    for (size_t i = 0; clean[i]; i++) {
        if (clean[i] == '0') clean[i] = 'O';
    }
    while (slen > 0 && (clean[slen-1] == '+' || clean[slen-1] == '#'))
        clean[--slen] = '\0';
    if (slen == 0) return false;

    ChessPosition pos;
    if (!chess_fen_load(fen, &pos)) return false;

    ChessArray moves;
    chess_array_init(&moves, sizeof(ChessMove));
    chess_generate_moves(&pos, &moves);

    bool found = false;
    for (size_t i = 0; i < chess_array_size(&moves); i++) {
        ChessMove m = *(const ChessMove *)chess_array_elem(&moves, i);
        char move_uci[8];
        chessmove_to_uci_str(m, move_uci);
        char move_san[16];
        if (!uci_to_san(fen, move_uci, move_san, sizeof(move_san)))
            continue;

        /* Strip +/# from generated SAN too */
        size_t mlen = strlen(move_san);
        while (mlen > 0 && (move_san[mlen-1] == '+' || move_san[mlen-1] == '#'))
            move_san[--mlen] = '\0';

        if (strcmp(clean, move_san) == 0) {
            strncpy(uci, move_uci, uci_len - 1);
            uci[uci_len - 1] = '\0';
            found = true;
            break;
        }
    }

    chess_array_cleanup(&moves);
    return found;
}

/* Pure search's chesslib adapter. Kept in this TU because the old
 * chess_logic and chesslib headers both define ChessPosition. */
#include "pure_search.h"
#include <stdio.h>
static void pure_normalize_ep(ChessPosition *pos, const ChessArray *moves) {
    if (pos->ep < 0) return;
    bool captures = false;
    for (size_t i=0; i<moves->size; i++) {
        ChessMove m = *(const ChessMove*)chess_array_elem(moves,i);
        int from=chess_move_from(m), to=chess_move_to(m);
        if (piece_type(pos->piece[from])==1 && pos->piece[to]==CHESS_PIECE_NONE &&
            chess_square_file(from)!=chess_square_file(to)) captures=true;
    }
    if (!captures) pos->ep=CHESS_FILE_INVALID;
}
bool pure_position_key(const char *fen, char key[128]) {
    ChessPosition pos;
    if (!chess_fen_load(fen,&pos)) return false;
    ChessArray moves; chess_array_init(&moves,sizeof(ChessMove));
    chess_generate_init(); chess_generate_moves(&pos,&moves);
    pure_normalize_ep(&pos,&moves); chess_array_cleanup(&moves);
    chess_fen_save(&pos,key);
    int spaces=0;
    for(char *p=key; *p; p++) if(*p==' ' && ++spaces==4) { *p=0; break; }
    return true;
}
static bool pure_insufficient(const ChessPosition *pos) {
    int minors=0, knights=0, bishop_color=-1;
    bool same=true;
    for(int sq=0;sq<64;sq++) {
        int p=piece_type(pos->piece[sq]);
        if(p==1 || p==4 || p==5) return false;
        if(p==2) { minors++; knights++; }
        if(p==3) {
            minors++;
            int color=(sq/8+sq%8)%2;
            if(bishop_color>=0 && bishop_color!=color) same=false;
            bishop_color=color;
        }
    }
    return minors<=1 || (knights==0 && same);
}
int pure_legal(const char *fen, PureMove *out, int *terminal) {
    ChessPosition pos;
    chess_generate_init();
    if(!chess_fen_load(fen,&pos)) return -1;
    ChessArray moves; chess_array_init(&moves,sizeof(ChessMove));
    chess_generate_moves(&pos,&moves);
    *terminal=-1;
    if(moves.size==0) *terminal=chess_position_is_check(&pos) ?
        (pos.to_move==CHESS_COLOR_WHITE?2:1) : 0;
    else if(pos.fifty>=100 || pure_insufficient(&pos)) *terminal=0;
    int n=(int)moves.size;
    if(n>PURE_MAX_MOVES) { chess_array_cleanup(&moves); return -1; }
    for(int i=0;i<n;i++) {
        ChessMove m=*(const ChessMove*)chess_array_elem(&moves,i);
        chessmove_to_uci_str(m,out[i].uci);
        if(!uci_to_san(fen,out[i].uci,out[i].san,sizeof(out[i].san))) { chess_array_cleanup(&moves); return -1; }
        ChessPosition child=pos;
        bool reset=piece_type(pos.piece[chess_move_from(m)])==1 || chess_position_move_is_capture(&pos,m);
        chess_position_make_move(&child,m);
        /* chesslib resets its counter on castling-right changes; FIDE does not. */
        child.fifty=reset?0:pos.fifty+1;
        chess_fen_save(&child,out[i].fen);
    }
    chess_array_cleanup(&moves);
    /* Identical deterministic order in the Dart implementation. */
    for(int i=1;i<n;i++) { PureMove m=out[i]; int j=i;
        while(j>0 && strcmp(out[j-1].uci,m.uci)>0) {out[j]=out[j-1];j--;}
        out[j]=m;
    }
    return n;
}
