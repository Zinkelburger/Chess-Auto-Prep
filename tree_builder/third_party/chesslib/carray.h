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

#ifndef CHESSLIB_ARRAY_H_
#define CHESSLIB_ARRAY_H_

typedef struct ChessArray
{
    size_t elem_size;
    size_t size;
    size_t max_size;
    void* data;
} ChessArray;

void chess_array_init(ChessArray*, size_t elem_size);
void chess_array_cleanup(ChessArray*);

size_t chess_array_size(const ChessArray*);
const void* chess_array_data(const ChessArray*);
const void* chess_array_elem(const ChessArray*, size_t index);

void chess_array_clear(ChessArray*);
void chess_array_set_elem(ChessArray*, size_t index, const void* elem);
void chess_array_push(ChessArray*, const void* elem);
void chess_array_pop(ChessArray*, void* elem);
void chess_array_prune(ChessArray*, size_t size);

#endif /* CHESSLIB_ARRAY_H_ */
