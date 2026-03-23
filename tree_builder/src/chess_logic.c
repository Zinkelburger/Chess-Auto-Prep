/**
 * chess_logic.c - Minimal Chess Position Logic Implementation
 * 
 * Handles FEN parsing, UCI move application, and FEN generation.
 * Does NOT validate move legality - trusts moves from Lichess/Stockfish.
 */

#include "chess_logic.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <ctype.h>


/* ========== Helper Functions ========== */

char file_to_char(int file) {
    return 'a' + file;
}

char rank_to_char(int rank) {
    return '1' + rank;
}

int char_to_file(char c) {
    if (c >= 'a' && c <= 'h') return c - 'a';
    return -1;
}

int char_to_rank(char c) {
    if (c >= '1' && c <= '8') return c - '1';
    return -1;
}

bool piece_is_white(int8_t piece) {
    return piece > 0;
}

bool piece_is_black(int8_t piece) {
    return piece < 0;
}

static int8_t char_to_piece(char c) {
    switch (c) {
        case 'P': return W_PAWN;
        case 'N': return W_KNIGHT;
        case 'B': return W_BISHOP;
        case 'R': return W_ROOK;
        case 'Q': return W_QUEEN;
        case 'K': return W_KING;
        case 'p': return B_PAWN;
        case 'n': return B_KNIGHT;
        case 'b': return B_BISHOP;
        case 'r': return B_ROOK;
        case 'q': return B_QUEEN;
        case 'k': return B_KING;
        default:  return EMPTY;
    }
}

static char piece_to_char(int8_t piece) {
    switch (piece) {
        case W_PAWN:   return 'P';
        case W_KNIGHT: return 'N';
        case W_BISHOP: return 'B';
        case W_ROOK:   return 'R';
        case W_QUEEN:  return 'Q';
        case W_KING:   return 'K';
        case B_PAWN:   return 'p';
        case B_KNIGHT: return 'n';
        case B_BISHOP: return 'b';
        case B_ROOK:   return 'r';
        case B_QUEEN:  return 'q';
        case B_KING:   return 'k';
        default:       return ' ';
    }
}

static int abs_piece(int8_t piece) {
    return piece < 0 ? -piece : piece;
}


/* ========== Position Operations ========== */

void position_init_startpos(ChessPosition *pos) {
    position_from_fen(pos, "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1");
}

void position_copy(ChessPosition *dst, const ChessPosition *src) {
    memcpy(dst, src, sizeof(ChessPosition));
}

int8_t position_piece_at(const ChessPosition *pos, int rank, int file) {
    if (rank < 0 || rank > 7 || file < 0 || file > 7) return EMPTY;
    return pos->board[rank][file];
}


/* ========== FEN Parsing ========== */

bool position_from_fen(ChessPosition *pos, const char *fen) {
    if (!pos || !fen) return false;
    
    memset(pos, 0, sizeof(ChessPosition));
    pos->ep_file = -1;
    pos->ep_rank = -1;
    
    const char *p = fen;
    
    /* 1. Piece placement (rank 8 down to rank 1) */
    for (int rank = 7; rank >= 0; rank--) {
        int file = 0;
        while (file < 8 && *p && *p != '/' && *p != ' ') {
            if (*p >= '1' && *p <= '8') {
                /* Empty squares */
                int count = *p - '0';
                for (int i = 0; i < count && file < 8; i++) {
                    pos->board[rank][file++] = EMPTY;
                }
            } else {
                /* Piece */
                int8_t piece = char_to_piece(*p);
                if (piece == EMPTY && *p != ' ') {
                    return false; /* Invalid character */
                }
                pos->board[rank][file++] = piece;
            }
            p++;
        }
        /* Fill remaining squares in rank (shouldn't happen in valid FEN) */
        while (file < 8) {
            pos->board[rank][file++] = EMPTY;
        }
        if (rank > 0) {
            if (*p == '/') p++;
        }
    }
    
    /* Skip to active color */
    while (*p && *p == ' ') p++;
    if (!*p) {
        pos->white_to_move = true;
        pos->fullmove_number = 1;
        return true;
    }
    
    /* 2. Active color */
    pos->white_to_move = (*p == 'w');
    p++;
    
    /* Skip space */
    while (*p && *p == ' ') p++;
    if (!*p) {
        pos->fullmove_number = 1;
        return true;
    }
    
    /* 3. Castling availability */
    pos->castle_K = false;
    pos->castle_Q = false;
    pos->castle_k = false;
    pos->castle_q = false;
    
    if (*p == '-') {
        p++;
    } else {
        while (*p && *p != ' ') {
            switch (*p) {
                case 'K': pos->castle_K = true; break;
                case 'Q': pos->castle_Q = true; break;
                case 'k': pos->castle_k = true; break;
                case 'q': pos->castle_q = true; break;
            }
            p++;
        }
    }
    
    /* Skip space */
    while (*p && *p == ' ') p++;
    if (!*p) {
        pos->fullmove_number = 1;
        return true;
    }
    
    /* 4. En passant target square */
    if (*p == '-') {
        pos->ep_file = -1;
        pos->ep_rank = -1;
        p++;
    } else {
        pos->ep_file = char_to_file(*p);
        p++;
        if (*p) {
            pos->ep_rank = char_to_rank(*p);
            p++;
        }
    }
    
    /* Skip space */
    while (*p && *p == ' ') p++;
    if (!*p) {
        pos->fullmove_number = 1;
        return true;
    }
    
    /* 5. Halfmove clock */
    pos->halfmove_clock = atoi(p);
    while (*p && *p != ' ') p++;
    
    /* Skip space */
    while (*p && *p == ' ') p++;
    if (!*p) {
        pos->fullmove_number = 1;
        return true;
    }
    
    /* 6. Fullmove number */
    pos->fullmove_number = atoi(p);
    if (pos->fullmove_number < 1) pos->fullmove_number = 1;
    
    return true;
}


/* ========== FEN Generation ========== */

void position_to_fen(const ChessPosition *pos, char *fen, size_t max_len) {
    if (!pos || !fen || max_len == 0) return;
    
    char buf[256];
    int idx = 0;
    
    /* 1. Piece placement (rank 8 down to rank 1) */
    for (int rank = 7; rank >= 0; rank--) {
        int empty_count = 0;
        
        for (int file = 0; file < 8; file++) {
            int8_t piece = pos->board[rank][file];
            
            if (piece == EMPTY) {
                empty_count++;
            } else {
                if (empty_count > 0) {
                    buf[idx++] = '0' + empty_count;
                    empty_count = 0;
                }
                buf[idx++] = piece_to_char(piece);
            }
        }
        
        if (empty_count > 0) {
            buf[idx++] = '0' + empty_count;
        }
        
        if (rank > 0) {
            buf[idx++] = '/';
        }
    }
    
    /* 2. Active color */
    buf[idx++] = ' ';
    buf[idx++] = pos->white_to_move ? 'w' : 'b';
    
    /* 3. Castling */
    buf[idx++] = ' ';
    if (!pos->castle_K && !pos->castle_Q && !pos->castle_k && !pos->castle_q) {
        buf[idx++] = '-';
    } else {
        if (pos->castle_K) buf[idx++] = 'K';
        if (pos->castle_Q) buf[idx++] = 'Q';
        if (pos->castle_k) buf[idx++] = 'k';
        if (pos->castle_q) buf[idx++] = 'q';
    }
    
    /* 4. En passant */
    buf[idx++] = ' ';
    if (pos->ep_file >= 0 && pos->ep_rank >= 0) {
        buf[idx++] = file_to_char(pos->ep_file);
        buf[idx++] = rank_to_char(pos->ep_rank);
    } else {
        buf[idx++] = '-';
    }
    
    /* 5. Halfmove clock */
    idx += snprintf(buf + idx, sizeof(buf) - idx, " %d", pos->halfmove_clock);
    
    /* 6. Fullmove number */
    idx += snprintf(buf + idx, sizeof(buf) - idx, " %d", pos->fullmove_number);
    
    buf[idx] = '\0';
    
    /* Copy to output */
    strncpy(fen, buf, max_len - 1);
    fen[max_len - 1] = '\0';
}


/* ========== UCI Move Application ========== */

bool position_apply_uci(ChessPosition *pos, const char *uci) {
    if (!pos || !uci) return false;
    
    size_t len = strlen(uci);
    if (len < 4 || len > 5) return false;
    
    /* Parse source and target squares */
    int from_file = char_to_file(uci[0]);
    int from_rank = char_to_rank(uci[1]);
    int to_file   = char_to_file(uci[2]);
    int to_rank   = char_to_rank(uci[3]);
    
    if (from_file < 0 || from_rank < 0 || to_file < 0 || to_rank < 0) {
        return false;
    }
    
    /* Get the piece being moved */
    int8_t piece = pos->board[from_rank][from_file];
    int8_t captured = pos->board[to_rank][to_file];
    int abs_p = abs_piece(piece);
    
    /* Determine if this is a pawn move or capture (for halfmove clock) */
    bool is_pawn = (abs_p == 1); /* W_PAWN or B_PAWN */
    bool is_capture = (captured != EMPTY);
    
    /* Handle en passant capture */
    if (is_pawn && to_file != from_file && captured == EMPTY) {
        /* Pawn moving diagonally to empty square = en passant */
        if (pos->ep_file == to_file && pos->ep_rank == to_rank) {
            /* Remove the captured pawn */
            int capture_rank = from_rank; /* Same rank as the capturing pawn */
            pos->board[capture_rank][to_file] = EMPTY;
            is_capture = true;
        }
    }
    
    /* Handle castling */
    bool is_castling = false;
    if (abs_p == 6 && abs(to_file - from_file) == 2) { /* King moves 2 squares */
        is_castling = true;
        
        if (to_file > from_file) {
            /* Kingside castling */
            int rook_rank = from_rank;
            pos->board[rook_rank][5] = pos->board[rook_rank][7]; /* Move rook h->f */
            pos->board[rook_rank][7] = EMPTY;
        } else {
            /* Queenside castling */
            int rook_rank = from_rank;
            pos->board[rook_rank][3] = pos->board[rook_rank][0]; /* Move rook a->d */
            pos->board[rook_rank][0] = EMPTY;
        }
    }
    
    /* Handle promotion */
    int8_t promotion_piece = EMPTY;
    if (len == 5) {
        char promo_char = tolower(uci[4]);
        bool is_white = piece_is_white(piece);
        switch (promo_char) {
            case 'q': promotion_piece = is_white ? W_QUEEN  : B_QUEEN;  break;
            case 'r': promotion_piece = is_white ? W_ROOK   : B_ROOK;   break;
            case 'b': promotion_piece = is_white ? W_BISHOP : B_BISHOP; break;
            case 'n': promotion_piece = is_white ? W_KNIGHT : B_KNIGHT; break;
            default:  return false;
        }
    }
    
    /* Move the piece */
    pos->board[from_rank][from_file] = EMPTY;
    if (promotion_piece != EMPTY) {
        pos->board[to_rank][to_file] = promotion_piece;
    } else {
        pos->board[to_rank][to_file] = piece;
    }
    
    /* Update castling rights */
    /* If king moves, lose both castling rights for that side */
    if (abs_p == 6) { /* King */
        if (piece_is_white(piece)) {
            pos->castle_K = false;
            pos->castle_Q = false;
        } else {
            pos->castle_k = false;
            pos->castle_q = false;
        }
    }
    
    /* If rook moves from its starting square, lose that castling right */
    if (abs_p == 4) { /* Rook */
        if (from_rank == 0 && from_file == 7) pos->castle_K = false; /* White h1 rook */
        if (from_rank == 0 && from_file == 0) pos->castle_Q = false; /* White a1 rook */
        if (from_rank == 7 && from_file == 7) pos->castle_k = false; /* Black h8 rook */
        if (from_rank == 7 && from_file == 0) pos->castle_q = false; /* Black a8 rook */
    }
    
    /* If a rook is captured on its starting square, remove that right */
    if (is_capture) {
        if (to_rank == 0 && to_file == 7) pos->castle_K = false;
        if (to_rank == 0 && to_file == 0) pos->castle_Q = false;
        if (to_rank == 7 && to_file == 7) pos->castle_k = false;
        if (to_rank == 7 && to_file == 0) pos->castle_q = false;
    }
    
    /* Update en passant square */
    pos->ep_file = -1;
    pos->ep_rank = -1;
    if (is_pawn && abs(to_rank - from_rank) == 2) {
        /* Double pawn push - set en passant square */
        pos->ep_file = from_file;
        pos->ep_rank = (from_rank + to_rank) / 2; /* Square between */
    }
    
    /* Update halfmove clock */
    if (is_pawn || is_capture) {
        pos->halfmove_clock = 0;
    } else {
        pos->halfmove_clock++;
    }
    
    /* Update fullmove number (increments after Black's move) */
    if (!pos->white_to_move) {
        pos->fullmove_number++;
    }
    
    /* Toggle side to move */
    pos->white_to_move = !pos->white_to_move;
    
    (void)is_castling; /* Suppress unused warning */
    
    return true;
}
