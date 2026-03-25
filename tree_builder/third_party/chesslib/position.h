/*
 * Copyright (c) 2012, Alex MDC
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *
 * Source: https://github.com/alexmdc/chesslib
 */

#ifndef CHESSLIB_POSITION_H_
#define CHESSLIB_POSITION_H_

#include "chess.h"
#include "move.h"
#include "unmove.h"

typedef struct
{
    /* Variables that store the current state of the board. */
    ChessPiece piece[64];
    ChessColor to_move;
    ChessCastleState castle;
    ChessFile ep;
    int fifty;
    int move_num;
    /* The remaining members are private and should not be used. */
    ChessSquare wking, bking;
} ChessPosition;

void chess_position_copy(const ChessPosition* from, ChessPosition* to);

/* Validates the given position by checking some simple invariants, and if
 * valid, sets up any extra internal state. This method MUST be called after
 * setting up a new position. If position is invalid, returns CHESS_FALSE.
 *
 * The following invariants are checked:
 *  1. Both sides have one king each.
 *  2. There are no pawns on the first or last rank.
 *  3. The opponent's king can not immediately be captured.
 *
 * In addition, any castle or en-passant states are cleared if they are
 * impossible (e.g. if the king is not on its starting square).
 */
ChessBoolean chess_position_validate(ChessPosition*);

ChessBoolean chess_position_is_check(const ChessPosition*);
ChessBoolean chess_position_move_is_legal(const ChessPosition*, ChessMove);
ChessBoolean chess_position_move_is_capture(const ChessPosition*, ChessMove);
ChessResult chess_position_check_result(const ChessPosition*);

ChessUnmove chess_position_make_move(ChessPosition*, ChessMove);
void chess_position_undo_move(ChessPosition*, ChessUnmove);

#endif /* CHESSLIB_POSITION_H_ */
