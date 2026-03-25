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

#ifndef CHESSLIB_MOVE_H_
#define CHESSLIB_MOVE_H_

#include "chess.h"

typedef int ChessMove;

typedef enum
{
    CHESS_MOVE_PROMOTE_NONE = 0,
    CHESS_MOVE_PROMOTE_KNIGHT = 1,
    CHESS_MOVE_PROMOTE_BISHOP = 2,
    CHESS_MOVE_PROMOTE_ROOK = 3,
    CHESS_MOVE_PROMOTE_QUEEN = 4
} ChessMovePromote;

extern ChessMove CHESS_MOVE_NULL;

ChessMovePromote chess_move_promote_from_char(char);
char chess_move_promote_to_char(ChessMovePromote);

ChessSquare chess_move_from(ChessMove);
ChessSquare chess_move_to(ChessMove);
ChessMovePromote chess_move_promotes(ChessMove);

ChessMove chess_move_make(ChessSquare from, ChessSquare to);
ChessMove chess_move_make_promote(ChessSquare from, ChessSquare to, ChessMovePromote);

#endif /* CHESSLIB_MOVE_H_ */
