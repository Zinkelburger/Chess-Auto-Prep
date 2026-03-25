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

#ifndef CHESSLIB_UNMOVE_H_
#define CHESSLIB_UNMOVE_H_

#include "chess.h"

typedef unsigned int ChessUnmove;

typedef enum
{
    CHESS_UNMOVE_CAPTURED_NONE = 0,
    CHESS_UNMOVE_CAPTURED_PAWN = 1,
    CHESS_UNMOVE_CAPTURED_KNIGHT = 2,
    CHESS_UNMOVE_CAPTURED_BISHOP = 3,
    CHESS_UNMOVE_CAPTURED_ROOK = 4,
    CHESS_UNMOVE_CAPTURED_QUEEN = 5
} ChessUnmoveCaptured;

typedef enum
{
    CHESS_UNMOVE_EP_NONE = 0,
    CHESS_UNMOVE_EP_CAPTURE = 1,
    CHESS_UNMOVE_EP_AVAILABLE = 2
    /* values 2->9 correspond to the file if you subtract 2 */
} ChessUnmoveEp;

/* Constructor */
ChessUnmove chess_unmove_make(
    ChessSquare from, ChessSquare to, ChessUnmoveCaptured captured,
    ChessBoolean promotion, ChessUnmoveEp ep,
    ChessCastleState castle, int fifty);

/* Accessors */
ChessSquare chess_unmove_from(ChessUnmove);
ChessSquare chess_unmove_to(ChessUnmove);
ChessUnmoveCaptured chess_unmove_captured(ChessUnmove);
ChessBoolean chess_unmove_promotion(ChessUnmove);
ChessUnmoveEp chess_unmove_ep(ChessUnmove);
ChessCastleState chess_unmove_castle(ChessUnmove);
int chess_unmove_fifty(ChessUnmove);

#endif /* CHESSLIB_UNMOVE_H_ */
