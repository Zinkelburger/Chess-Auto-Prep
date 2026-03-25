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
#include <stdlib.h>
#include <memory.h>

#include "carray.h"
#include "calloc.h"

void chess_array_init(ChessArray* array, size_t elem_size)
{
    array->elem_size = elem_size;
    array->size = 0;
    array->max_size = 0;
}

void chess_array_cleanup(ChessArray* array)
{
    if (array->max_size > 0)
        chess_free(array->data);
}

size_t chess_array_size(const ChessArray* array)
{
    return array->size;
}

const void* chess_array_data(const ChessArray* array)
{
    assert(array->size > 0);
    return array->data;
}

const void* chess_array_elem(const ChessArray* array, size_t index)
{
    assert(index < array->size);
    return (const char*)array->data + (index * array->elem_size);
}

void chess_array_clear(ChessArray* array)
{
    if (array->max_size > 0)
    {
        chess_free(array->data);
        array->size = 0;
        array->max_size = 0;
    }
}

void chess_array_set_elem(ChessArray* array, size_t index, const void* value)
{
    void* dest;
    assert(index < array->size);
    dest = (char*)array->data + (index * array->elem_size);
    memcpy(dest, value, array->elem_size);
}

static void expand(ChessArray* array)
{
    size_t new_size = array->max_size ? array->max_size * 2 : 8;
    if (array->max_size > 0)
        array->data = chess_realloc(array->data, new_size * array->elem_size);
    else
        array->data = chess_alloc(new_size * array->elem_size);
    array->max_size = new_size;
}

void chess_array_push(ChessArray* array, const void* elem)
{
    if (array->size == array->max_size)
    {
        expand(array);
    }
    assert(array->size < array->max_size);
    chess_array_set_elem(array, array->size++, elem);
}

void chess_array_pop(ChessArray* array, void* elem)
{
    assert(array->size > 0);
    if (elem)
    {
        size_t index = array->size - 1;
        void* src = (char*)array->data + (index * array->elem_size);
        memcpy(elem, src, array->elem_size);
    }
    array->size--;
}

void chess_array_prune(ChessArray* array, size_t size)
{
    assert(size <= array->size);
    array->size = size;
}
