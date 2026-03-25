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

#include <assert.h>

#include "unmove.h"

ChessUnmove chess_unmove_make(
    ChessSquare from, ChessSquare to, ChessUnmoveCaptured captured,
    ChessBoolean promotion, ChessUnmoveEp ep,
    ChessCastleState castle, int fifty)
{
    /* When capturing ep, captured piece must be NONE */
    assert(ep != CHESS_UNMOVE_EP_CAPTURE || captured == CHESS_UNMOVE_CAPTURED_NONE);
    assert(ep >= CHESS_UNMOVE_EP_NONE);
    assert((int)ep <= CHESS_UNMOVE_EP_AVAILABLE + CHESS_FILE_H);

    return from             /* 6 bits */
        | (to << 6)         /* 6 bits */
        | (captured << 12)  /* 3 bits */
        | (promotion << 15) /* 1 bit */
        | (ep << 16)        /* 4 bits */
        | (castle << 20)    /* 4 bits */
        | (fifty << 24);    /* remaining 8 bits */
}

ChessSquare chess_unmove_from(ChessUnmove unmove)
{
    return unmove & 077;
}

ChessSquare chess_unmove_to(ChessUnmove unmove)
{
    return (unmove >> 6) & 077;
}

ChessUnmoveCaptured chess_unmove_captured(ChessUnmove unmove)
{
    return (unmove >> 12) & 07;
}

ChessBoolean chess_unmove_promotion(ChessUnmove unmove)
{
    return (unmove >> 15) & 1;
}

ChessUnmoveEp chess_unmove_ep(ChessUnmove unmove)
{
    return (unmove >> 16) & 0xf;
}

ChessCastleState chess_unmove_castle(ChessUnmove unmove)
{
    return (unmove >> 20) & 0xf;
}

int chess_unmove_fifty(ChessUnmove unmove)
{
    return (unmove >> 24);
}
