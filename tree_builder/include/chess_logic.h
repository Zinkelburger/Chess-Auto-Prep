/**
 * chess_logic.h - Minimal Chess Position Logic
 * 
 * Provides FEN parsing, UCI move application, and FEN generation.
 * This is NOT a full chess engine - it trusts that moves from the
 * Lichess API or Stockfish are legal. It just applies them to track
 * board state and generate FENs for subsequent queries.
 */

#ifndef CHESS_LOGIC_H
#define CHESS_LOGIC_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

/* Piece encoding (positive = white, negative = black) */
enum {
    EMPTY    =  0,
    W_PAWN   =  1, W_KNIGHT =  2, W_BISHOP =  3,
    W_ROOK   =  4, W_QUEEN  =  5, W_KING   =  6,
    B_PAWN   = -1, B_KNIGHT = -2, B_BISHOP = -3,
    B_ROOK   = -4, B_QUEEN  = -5, B_KING   = -6,
};

/**
 * Chess position state
 * 
 * Board is indexed as board[rank][file] where:
 *   rank 0 = 1st rank (White's back rank)
 *   rank 7 = 8th rank (Black's back rank)
 *   file 0 = a-file, file 7 = h-file
 */
typedef struct {
    int8_t board[8][8];         /* board[rank][file] */
    bool white_to_move;
    bool castle_K;              /* White kingside (K) */
    bool castle_Q;              /* White queenside (Q) */
    bool castle_k;              /* Black kingside (k) */
    bool castle_q;              /* Black queenside (q) */
    int ep_file;                /* En passant target file (0-7), -1 if none */
    int ep_rank;                /* En passant target rank (2 or 5), -1 if none */
    int halfmove_clock;
    int fullmove_number;
} ChessPosition;

/**
 * Parse a FEN string into a ChessPosition
 * 
 * @param pos Output position
 * @param fen FEN string to parse
 * @return true on success, false on parse error
 */
bool position_from_fen(ChessPosition *pos, const char *fen);

/**
 * Generate a FEN string from a ChessPosition
 * 
 * @param pos The position
 * @param fen Output buffer (must be at least 128 bytes)
 * @param max_len Size of output buffer
 */
void position_to_fen(const ChessPosition *pos, char *fen, size_t max_len);

/**
 * Apply a UCI move to a position
 * 
 * Handles standard moves, captures, castling, en passant, and promotion.
 * Trusts the move is legal (does not validate legality).
 * 
 * @param pos The position to modify (in place)
 * @param uci UCI move string (e.g., "e2e4", "e7e8q", "e1g1")
 * @return true on success, false on parse error
 */
bool position_apply_uci(ChessPosition *pos, const char *uci);

/**
 * Get the piece at a square
 * 
 * @param pos The position
 * @param rank Rank (0-7, 0 = 1st rank)
 * @param file File (0-7, 0 = a-file)
 * @return Piece value (see enum above)
 */
int8_t position_piece_at(const ChessPosition *pos, int rank, int file);

/**
 * Check if a piece is white
 */
bool piece_is_white(int8_t piece);

/**
 * Check if a piece is black
 */
bool piece_is_black(int8_t piece);

/**
 * Initialize to the standard starting position
 */
void position_init_startpos(ChessPosition *pos);

/**
 * Copy a position
 */
void position_copy(ChessPosition *dst, const ChessPosition *src);

/**
 * Convert file index (0-7) to character ('a'-'h')
 */
char file_to_char(int file);

/**
 * Convert rank index (0-7) to character ('1'-'8')
 */
char rank_to_char(int rank);

/**
 * Convert file character ('a'-'h') to index (0-7)
 * Returns -1 on error
 */
int char_to_file(char c);

/**
 * Convert rank character ('1'-'8') to index (0-7)
 * Returns -1 on error
 */
int char_to_rank(char c);

#endif /* CHESS_LOGIC_H */
