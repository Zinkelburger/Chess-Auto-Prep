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

#include <string.h>
#include <assert.h>

#include "chess.h"
#include "move.h"

static const char promote_chars[] = "nbrq";

ChessMove CHESS_MOVE_NULL = 0x80000000;

ChessMovePromote chess_move_promote_from_char(char c)
{
    char* s = strchr(promote_chars, c);
    return (s && *s) ? CHESS_MOVE_PROMOTE_KNIGHT + (s - promote_chars) : CHESS_MOVE_PROMOTE_NONE;
}

char chess_move_promote_to_char(ChessMovePromote promote)
{
    assert(promote >= CHESS_MOVE_PROMOTE_KNIGHT && promote <= CHESS_MOVE_PROMOTE_QUEEN);
    return promote_chars[promote - CHESS_MOVE_PROMOTE_KNIGHT];
}

ChessSquare chess_move_from(ChessMove move)
{
    return move & 077;
}

ChessSquare chess_move_to(ChessMove move)
{
    return (move >> 6) & 077;
}

ChessMovePromote chess_move_promotes(ChessMove move)
{
    return (move >> 12) & 017;
}

ChessMove chess_move_make(ChessSquare from, ChessSquare to)
{
    return from | (to << 6);
}

ChessMove chess_move_make_promote(ChessSquare from, ChessSquare to, ChessMovePromote promote)
{
    return from | (to << 6) | (promote << 12);
}
