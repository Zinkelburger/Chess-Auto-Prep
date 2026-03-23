/*
  Copyright (c) 2009-2017 Dave Gamble and cJSON contributors

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
  THE SOFTWARE.
*/

/* cJSON */
/* JSON parser in C. */

/* Minimal implementation for tree_builder - core functions only */

#include <string.h>
#include <stdio.h>
#include <math.h>
#include <stdlib.h>
#include <limits.h>
#include <ctype.h>
#include <float.h>

#include "cJSON.h"

/* Internal malloc/free */
static void *(*global_malloc)(size_t sz) = malloc;
static void (*global_free)(void *ptr) = free;

CJSON_PUBLIC(void) cJSON_InitHooks(cJSON_Hooks* hooks) {
    if (hooks == NULL) {
        global_malloc = malloc;
        global_free = free;
        return;
    }
    global_malloc = (hooks->malloc_fn != NULL) ? hooks->malloc_fn : malloc;
    global_free = (hooks->free_fn != NULL) ? hooks->free_fn : free;
}

static cJSON *cJSON_New_Item(void) {
    cJSON *node = (cJSON*)global_malloc(sizeof(cJSON));
    if (node) memset(node, 0, sizeof(cJSON));
    return node;
}

CJSON_PUBLIC(void) cJSON_Delete(cJSON *item) {
    cJSON *next = NULL;
    while (item != NULL) {
        next = item->next;
        if (!(item->type & cJSON_IsReference) && item->child != NULL) {
            cJSON_Delete(item->child);
        }
        if (!(item->type & cJSON_IsReference) && item->valuestring != NULL) {
            global_free(item->valuestring);
        }
        if (!(item->type & cJSON_StringIsConst) && item->string != NULL) {
            global_free(item->string);
        }
        global_free(item);
        item = next;
    }
}

CJSON_PUBLIC(void) cJSON_free(void *object) {
    global_free(object);
}

/* Type checking functions */
CJSON_PUBLIC(cJSON_bool) cJSON_IsInvalid(const cJSON * const item) {
    return item == NULL || (item->type & 0xFF) == cJSON_Invalid;
}
CJSON_PUBLIC(cJSON_bool) cJSON_IsFalse(const cJSON * const item) {
    return item != NULL && (item->type & 0xFF) == cJSON_False;
}
CJSON_PUBLIC(cJSON_bool) cJSON_IsTrue(const cJSON * const item) {
    return item != NULL && (item->type & 0xFF) == cJSON_True;
}
CJSON_PUBLIC(cJSON_bool) cJSON_IsBool(const cJSON * const item) {
    return cJSON_IsTrue(item) || cJSON_IsFalse(item);
}
CJSON_PUBLIC(cJSON_bool) cJSON_IsNull(const cJSON * const item) {
    return item != NULL && (item->type & 0xFF) == cJSON_NULL;
}
CJSON_PUBLIC(cJSON_bool) cJSON_IsNumber(const cJSON * const item) {
    return item != NULL && (item->type & 0xFF) == cJSON_Number;
}
CJSON_PUBLIC(cJSON_bool) cJSON_IsString(const cJSON * const item) {
    return item != NULL && (item->type & 0xFF) == cJSON_String;
}
CJSON_PUBLIC(cJSON_bool) cJSON_IsArray(const cJSON * const item) {
    return item != NULL && (item->type & 0xFF) == cJSON_Array;
}
CJSON_PUBLIC(cJSON_bool) cJSON_IsObject(const cJSON * const item) {
    return item != NULL && (item->type & 0xFF) == cJSON_Object;
}
CJSON_PUBLIC(cJSON_bool) cJSON_IsRaw(const cJSON * const item) {
    return item != NULL && (item->type & 0xFF) == cJSON_Raw;
}

CJSON_PUBLIC(char *) cJSON_GetStringValue(const cJSON * const item) {
    if (!cJSON_IsString(item)) return NULL;
    return item->valuestring;
}

CJSON_PUBLIC(double) cJSON_GetNumberValue(const cJSON * const item) {
    if (!cJSON_IsNumber(item)) return NAN;
    return item->valuedouble;
}

/* Parsing */
static const char *skip_whitespace(const char *in) {
    while (in && *in && ((unsigned char)*in <= 32)) in++;
    return in;
}

static const char *parse_string(cJSON *item, const char *str) {
    const char *ptr = str + 1;
    const char *end_ptr = ptr;
    char *out;
    size_t len = 0;
    
    if (*str != '\"') return NULL;
    
    /* Find end of string */
    while (*end_ptr != '\"' && *end_ptr) {
        if (*end_ptr == '\\') end_ptr++;
        end_ptr++;
    }
    
    len = end_ptr - ptr;
    out = (char*)global_malloc(len + 1);
    if (!out) return NULL;
    
    /* Simple copy (no escape handling for brevity) */
    char *out_ptr = out;
    while (ptr < end_ptr) {
        if (*ptr == '\\') {
            ptr++;
            switch (*ptr) {
                case 'n': *out_ptr++ = '\n'; break;
                case 't': *out_ptr++ = '\t'; break;
                case 'r': *out_ptr++ = '\r'; break;
                case '\\': *out_ptr++ = '\\'; break;
                case '\"': *out_ptr++ = '\"'; break;
                case '/': *out_ptr++ = '/'; break;
                default: *out_ptr++ = *ptr; break;
            }
        } else {
            *out_ptr++ = *ptr;
        }
        ptr++;
    }
    *out_ptr = '\0';
    
    item->valuestring = out;
    item->type = cJSON_String;
    
    return end_ptr + 1;
}

static const char *parse_number(cJSON *item, const char *num) {
    double n = 0;
    int sign = 1;
    int scale = 0;
    int subscale = 0;
    int signsubscale = 1;
    
    if (*num == '-') { sign = -1; num++; }
    if (*num == '0') num++;
    
    if (*num >= '1' && *num <= '9') {
        do {
            n = n * 10.0 + (*num++ - '0');
        } while (*num >= '0' && *num <= '9');
    }
    
    if (*num == '.' && num[1] >= '0' && num[1] <= '9') {
        num++;
        do {
            n = n * 10.0 + (*num++ - '0');
            scale--;
        } while (*num >= '0' && *num <= '9');
    }
    
    if (*num == 'e' || *num == 'E') {
        num++;
        if (*num == '+') num++;
        else if (*num == '-') { signsubscale = -1; num++; }
        while (*num >= '0' && *num <= '9') {
            subscale = subscale * 10 + (*num++ - '0');
        }
    }
    
    n = sign * n * pow(10.0, scale + subscale * signsubscale);
    
    item->valuedouble = n;
    item->valueint = (int)n;
    item->type = cJSON_Number;
    
    return num;
}

static const char *parse_value(cJSON *item, const char *value);
static const char *parse_array(cJSON *item, const char *value);
static const char *parse_object(cJSON *item, const char *value);

static const char *parse_value(cJSON *item, const char *value) {
    if (!value) return NULL;
    
    value = skip_whitespace(value);
    
    if (!strncmp(value, "null", 4)) { item->type = cJSON_NULL; return value + 4; }
    if (!strncmp(value, "false", 5)) { item->type = cJSON_False; return value + 5; }
    if (!strncmp(value, "true", 4)) { item->type = cJSON_True; item->valueint = 1; return value + 4; }
    if (*value == '\"') return parse_string(item, value);
    if (*value == '-' || (*value >= '0' && *value <= '9')) return parse_number(item, value);
    if (*value == '[') return parse_array(item, value);
    if (*value == '{') return parse_object(item, value);
    
    return NULL;
}

static const char *parse_array(cJSON *item, const char *value) {
    cJSON *child;
    
    if (*value != '[') return NULL;
    item->type = cJSON_Array;
    value = skip_whitespace(value + 1);
    if (*value == ']') return value + 1;
    
    item->child = child = cJSON_New_Item();
    if (!item->child) return NULL;
    
    value = skip_whitespace(parse_value(child, skip_whitespace(value)));
    if (!value) return NULL;
    
    while (*value == ',') {
        cJSON *new_item = cJSON_New_Item();
        if (!new_item) return NULL;
        child->next = new_item;
        new_item->prev = child;
        child = new_item;
        value = skip_whitespace(parse_value(child, skip_whitespace(value + 1)));
        if (!value) return NULL;
    }
    
    if (*value == ']') return value + 1;
    return NULL;
}

static const char *parse_object(cJSON *item, const char *value) {
    cJSON *child;
    
    if (*value != '{') return NULL;
    item->type = cJSON_Object;
    value = skip_whitespace(value + 1);
    if (*value == '}') return value + 1;
    
    item->child = child = cJSON_New_Item();
    if (!item->child) return NULL;
    
    value = skip_whitespace(parse_string(child, skip_whitespace(value)));
    if (!value) return NULL;
    child->string = child->valuestring;
    child->valuestring = NULL;
    
    if (*value != ':') return NULL;
    value = skip_whitespace(parse_value(child, skip_whitespace(value + 1)));
    if (!value) return NULL;
    
    while (*value == ',') {
        cJSON *new_item = cJSON_New_Item();
        if (!new_item) return NULL;
        child->next = new_item;
        new_item->prev = child;
        child = new_item;
        
        value = skip_whitespace(parse_string(child, skip_whitespace(value + 1)));
        if (!value) return NULL;
        child->string = child->valuestring;
        child->valuestring = NULL;
        
        if (*value != ':') return NULL;
        value = skip_whitespace(parse_value(child, skip_whitespace(value + 1)));
        if (!value) return NULL;
    }
    
    if (*value == '}') return value + 1;
    return NULL;
}

CJSON_PUBLIC(cJSON *) cJSON_Parse(const char *value) {
    cJSON *c = cJSON_New_Item();
    if (!c) return NULL;
    
    if (!parse_value(c, skip_whitespace(value))) {
        cJSON_Delete(c);
        return NULL;
    }
    return c;
}

CJSON_PUBLIC(cJSON *) cJSON_ParseWithLength(const char *value, size_t buffer_length) {
    (void)buffer_length;
    return cJSON_Parse(value);
}

/* Printing */
typedef struct {
    char *buffer;
    size_t length;
    size_t offset;
    int depth;
    int format;
} printbuffer;

static void ensure(printbuffer *p, size_t needed) {
    if (p->offset + needed >= p->length) {
        size_t newsize = p->length * 2;
        if (newsize < p->offset + needed) newsize = p->offset + needed + 256;
        char *newbuffer = (char*)global_malloc(newsize);
        if (newbuffer) {
            memcpy(newbuffer, p->buffer, p->offset);
            global_free(p->buffer);
            p->buffer = newbuffer;
            p->length = newsize;
        }
    }
}

static void print_string(printbuffer *p, const char *str) {
    size_t len = str ? strlen(str) : 0;
    ensure(p, len + 3);
    p->buffer[p->offset++] = '\"';
    for (size_t i = 0; i < len; i++) {
        char c = str[i];
        if (c == '\"' || c == '\\') {
            p->buffer[p->offset++] = '\\';
        }
        p->buffer[p->offset++] = c;
    }
    p->buffer[p->offset++] = '\"';
}

static void print_value(const cJSON *item, printbuffer *p);

static void print_number(const cJSON *item, printbuffer *p) {
    ensure(p, 64);
    double d = item->valuedouble;
    
    if (isnan(d) || isinf(d)) {
        p->offset += sprintf(p->buffer + p->offset, "null");
    } else if (d == (double)item->valueint) {
        p->offset += sprintf(p->buffer + p->offset, "%d", item->valueint);
    } else {
        p->offset += sprintf(p->buffer + p->offset, "%g", d);
    }
}

static void print_array(const cJSON *item, printbuffer *p) {
    ensure(p, 1);
    p->buffer[p->offset++] = '[';
    
    cJSON *child = item->child;
    while (child) {
        print_value(child, p);
        child = child->next;
        if (child) {
            ensure(p, 2);
            p->buffer[p->offset++] = ',';
            if (p->format) p->buffer[p->offset++] = ' ';
        }
    }
    
    ensure(p, 1);
    p->buffer[p->offset++] = ']';
}

static void print_object(const cJSON *item, printbuffer *p) {
    ensure(p, 2);
    p->buffer[p->offset++] = '{';
    if (p->format) p->buffer[p->offset++] = '\n';
    
    p->depth++;
    
    cJSON *child = item->child;
    while (child) {
        if (p->format) {
            ensure(p, p->depth * 2);
            for (int i = 0; i < p->depth * 2; i++) {
                p->buffer[p->offset++] = ' ';
            }
        }
        
        print_string(p, child->string);
        ensure(p, 2);
        p->buffer[p->offset++] = ':';
        if (p->format) p->buffer[p->offset++] = ' ';
        
        print_value(child, p);
        
        child = child->next;
        if (child) {
            ensure(p, 1);
            p->buffer[p->offset++] = ',';
        }
        if (p->format) {
            ensure(p, 1);
            p->buffer[p->offset++] = '\n';
        }
    }
    
    p->depth--;
    
    if (p->format) {
        ensure(p, p->depth * 2 + 1);
        for (int i = 0; i < p->depth * 2; i++) {
            p->buffer[p->offset++] = ' ';
        }
    }
    
    p->buffer[p->offset++] = '}';
}

static void print_value(const cJSON *item, printbuffer *p) {
    if (!item) return;
    
    switch (item->type & 0xFF) {
        case cJSON_NULL:
            ensure(p, 5);
            strcpy(p->buffer + p->offset, "null");
            p->offset += 4;
            break;
        case cJSON_False:
            ensure(p, 6);
            strcpy(p->buffer + p->offset, "false");
            p->offset += 5;
            break;
        case cJSON_True:
            ensure(p, 5);
            strcpy(p->buffer + p->offset, "true");
            p->offset += 4;
            break;
        case cJSON_Number:
            print_number(item, p);
            break;
        case cJSON_String:
            print_string(p, item->valuestring);
            break;
        case cJSON_Array:
            print_array(item, p);
            break;
        case cJSON_Object:
            print_object(item, p);
            break;
        case cJSON_Raw:
            if (item->valuestring) {
                size_t len = strlen(item->valuestring);
                ensure(p, len + 1);
                memcpy(p->buffer + p->offset, item->valuestring, len);
                p->offset += len;
            }
            break;
    }
}

CJSON_PUBLIC(char *) cJSON_Print(const cJSON *item) {
    printbuffer p;
    p.buffer = (char*)global_malloc(256);
    p.length = 256;
    p.offset = 0;
    p.depth = 0;
    p.format = 1;
    
    if (!p.buffer) return NULL;
    
    print_value(item, &p);
    ensure(&p, 1);
    p.buffer[p.offset] = '\0';
    
    return p.buffer;
}

CJSON_PUBLIC(char *) cJSON_PrintUnformatted(const cJSON *item) {
    printbuffer p;
    p.buffer = (char*)global_malloc(256);
    p.length = 256;
    p.offset = 0;
    p.depth = 0;
    p.format = 0;
    
    if (!p.buffer) return NULL;
    
    print_value(item, &p);
    ensure(&p, 1);
    p.buffer[p.offset] = '\0';
    
    return p.buffer;
}

/* Creating items */
CJSON_PUBLIC(cJSON *) cJSON_CreateNull(void) {
    cJSON *item = cJSON_New_Item();
    if (item) item->type = cJSON_NULL;
    return item;
}

CJSON_PUBLIC(cJSON *) cJSON_CreateTrue(void) {
    cJSON *item = cJSON_New_Item();
    if (item) item->type = cJSON_True;
    return item;
}

CJSON_PUBLIC(cJSON *) cJSON_CreateFalse(void) {
    cJSON *item = cJSON_New_Item();
    if (item) item->type = cJSON_False;
    return item;
}

CJSON_PUBLIC(cJSON *) cJSON_CreateBool(cJSON_bool b) {
    cJSON *item = cJSON_New_Item();
    if (item) item->type = b ? cJSON_True : cJSON_False;
    return item;
}

CJSON_PUBLIC(cJSON *) cJSON_CreateNumber(double num) {
    cJSON *item = cJSON_New_Item();
    if (item) {
        item->type = cJSON_Number;
        item->valuedouble = num;
        item->valueint = (int)num;
    }
    return item;
}

CJSON_PUBLIC(cJSON *) cJSON_CreateString(const char *string) {
    cJSON *item = cJSON_New_Item();
    if (item) {
        item->type = cJSON_String;
        item->valuestring = string ? strdup(string) : NULL;
    }
    return item;
}

CJSON_PUBLIC(cJSON *) cJSON_CreateRaw(const char *raw) {
    cJSON *item = cJSON_New_Item();
    if (item) {
        item->type = cJSON_Raw;
        item->valuestring = raw ? strdup(raw) : NULL;
    }
    return item;
}

CJSON_PUBLIC(cJSON *) cJSON_CreateArray(void) {
    cJSON *item = cJSON_New_Item();
    if (item) item->type = cJSON_Array;
    return item;
}

CJSON_PUBLIC(cJSON *) cJSON_CreateObject(void) {
    cJSON *item = cJSON_New_Item();
    if (item) item->type = cJSON_Object;
    return item;
}

CJSON_PUBLIC(cJSON *) cJSON_CreateStringReference(const char *string) {
    cJSON *item = cJSON_New_Item();
    if (item) {
        item->type = cJSON_String | cJSON_IsReference;
        item->valuestring = (char*)string;
    }
    return item;
}

CJSON_PUBLIC(cJSON *) cJSON_CreateObjectReference(const cJSON *child) {
    cJSON *item = cJSON_New_Item();
    if (item) {
        item->type = cJSON_Object | cJSON_IsReference;
        item->child = (cJSON*)child;
    }
    return item;
}

CJSON_PUBLIC(cJSON *) cJSON_CreateArrayReference(const cJSON *child) {
    cJSON *item = cJSON_New_Item();
    if (item) {
        item->type = cJSON_Array | cJSON_IsReference;
        item->child = (cJSON*)child;
    }
    return item;
}

/* Array operations */
CJSON_PUBLIC(int) cJSON_GetArraySize(const cJSON *array) {
    cJSON *child = array ? array->child : NULL;
    int size = 0;
    while (child) { size++; child = child->next; }
    return size;
}

CJSON_PUBLIC(cJSON *) cJSON_GetArrayItem(const cJSON *array, int index) {
    cJSON *child = array ? array->child : NULL;
    while (child && index > 0) { index--; child = child->next; }
    return child;
}

CJSON_PUBLIC(cJSON *) cJSON_GetObjectItem(const cJSON * const object, const char * const string) {
    cJSON *child = object ? object->child : NULL;
    while (child && child->string && strcasecmp(child->string, string) != 0) {
        child = child->next;
    }
    return child;
}

CJSON_PUBLIC(cJSON *) cJSON_GetObjectItemCaseSensitive(const cJSON * const object, const char * const string) {
    cJSON *child = object ? object->child : NULL;
    while (child && child->string && strcmp(child->string, string) != 0) {
        child = child->next;
    }
    return child;
}

CJSON_PUBLIC(cJSON_bool) cJSON_HasObjectItem(const cJSON *object, const char *string) {
    return cJSON_GetObjectItem(object, string) != NULL;
}

/* Adding items */
static cJSON_bool add_item_to_array(cJSON *array, cJSON *item) {
    if (!array || !item) return 0;
    
    cJSON *child = array->child;
    if (!child) {
        array->child = item;
    } else {
        while (child->next) child = child->next;
        child->next = item;
        item->prev = child;
    }
    return 1;
}

CJSON_PUBLIC(cJSON_bool) cJSON_AddItemToArray(cJSON *array, cJSON *item) {
    return add_item_to_array(array, item);
}

static cJSON_bool add_item_to_object(cJSON *object, const char *string, cJSON *item, int constant_key) {
    if (!object || !string || !item) return 0;
    
    if (constant_key) {
        item->string = (char*)string;
        item->type |= cJSON_StringIsConst;
    } else {
        item->string = strdup(string);
        if (!item->string) return 0;
    }
    
    return add_item_to_array(object, item);
}

CJSON_PUBLIC(cJSON_bool) cJSON_AddItemToObject(cJSON *object, const char *string, cJSON *item) {
    return add_item_to_object(object, string, item, 0);
}

CJSON_PUBLIC(cJSON_bool) cJSON_AddItemToObjectCS(cJSON *object, const char *string, cJSON *item) {
    return add_item_to_object(object, string, item, 1);
}

CJSON_PUBLIC(cJSON_bool) cJSON_AddItemReferenceToArray(cJSON *array, cJSON *item) {
    if (!array || !item) return 0;
    return add_item_to_array(array, cJSON_CreateObjectReference(item));
}

CJSON_PUBLIC(cJSON_bool) cJSON_AddItemReferenceToObject(cJSON *object, const char *string, cJSON *item) {
    if (!object || !string || !item) return 0;
    return add_item_to_object(object, string, cJSON_CreateObjectReference(item), 0);
}

/* Helper functions for adding to object */
CJSON_PUBLIC(cJSON*) cJSON_AddNullToObject(cJSON * const object, const char * const name) {
    cJSON *null_item = cJSON_CreateNull();
    if (add_item_to_object(object, name, null_item, 0)) return null_item;
    cJSON_Delete(null_item);
    return NULL;
}

CJSON_PUBLIC(cJSON*) cJSON_AddTrueToObject(cJSON * const object, const char * const name) {
    cJSON *true_item = cJSON_CreateTrue();
    if (add_item_to_object(object, name, true_item, 0)) return true_item;
    cJSON_Delete(true_item);
    return NULL;
}

CJSON_PUBLIC(cJSON*) cJSON_AddFalseToObject(cJSON * const object, const char * const name) {
    cJSON *false_item = cJSON_CreateFalse();
    if (add_item_to_object(object, name, false_item, 0)) return false_item;
    cJSON_Delete(false_item);
    return NULL;
}

CJSON_PUBLIC(cJSON*) cJSON_AddBoolToObject(cJSON * const object, const char * const name, const cJSON_bool boolean) {
    cJSON *bool_item = cJSON_CreateBool(boolean);
    if (add_item_to_object(object, name, bool_item, 0)) return bool_item;
    cJSON_Delete(bool_item);
    return NULL;
}

CJSON_PUBLIC(cJSON*) cJSON_AddNumberToObject(cJSON * const object, const char * const name, const double number) {
    cJSON *number_item = cJSON_CreateNumber(number);
    if (add_item_to_object(object, name, number_item, 0)) return number_item;
    cJSON_Delete(number_item);
    return NULL;
}

CJSON_PUBLIC(cJSON*) cJSON_AddStringToObject(cJSON * const object, const char * const name, const char * const string) {
    cJSON *string_item = cJSON_CreateString(string);
    if (add_item_to_object(object, name, string_item, 0)) return string_item;
    cJSON_Delete(string_item);
    return NULL;
}

CJSON_PUBLIC(cJSON*) cJSON_AddRawToObject(cJSON * const object, const char * const name, const char * const raw) {
    cJSON *raw_item = cJSON_CreateRaw(raw);
    if (add_item_to_object(object, name, raw_item, 0)) return raw_item;
    cJSON_Delete(raw_item);
    return NULL;
}

CJSON_PUBLIC(cJSON*) cJSON_AddObjectToObject(cJSON * const object, const char * const name) {
    cJSON *new_item = cJSON_CreateObject();
    if (add_item_to_object(object, name, new_item, 0)) return new_item;
    cJSON_Delete(new_item);
    return NULL;
}

CJSON_PUBLIC(cJSON*) cJSON_AddArrayToObject(cJSON * const object, const char * const name) {
    cJSON *new_item = cJSON_CreateArray();
    if (add_item_to_object(object, name, new_item, 0)) return new_item;
    cJSON_Delete(new_item);
    return NULL;
}

/* Detach/Delete operations */
CJSON_PUBLIC(cJSON *) cJSON_DetachItemViaPointer(cJSON *parent, cJSON * const item) {
    if (!parent || !item) return NULL;
    
    if (item->prev) item->prev->next = item->next;
    if (item->next) item->next->prev = item->prev;
    if (parent->child == item) parent->child = item->next;
    
    item->prev = NULL;
    item->next = NULL;
    
    return item;
}

CJSON_PUBLIC(cJSON *) cJSON_DetachItemFromArray(cJSON *array, int which) {
    return cJSON_DetachItemViaPointer(array, cJSON_GetArrayItem(array, which));
}

CJSON_PUBLIC(void) cJSON_DeleteItemFromArray(cJSON *array, int which) {
    cJSON_Delete(cJSON_DetachItemFromArray(array, which));
}

CJSON_PUBLIC(cJSON *) cJSON_DetachItemFromObject(cJSON *object, const char *string) {
    return cJSON_DetachItemViaPointer(object, cJSON_GetObjectItem(object, string));
}

CJSON_PUBLIC(cJSON *) cJSON_DetachItemFromObjectCaseSensitive(cJSON *object, const char *string) {
    return cJSON_DetachItemViaPointer(object, cJSON_GetObjectItemCaseSensitive(object, string));
}

CJSON_PUBLIC(void) cJSON_DeleteItemFromObject(cJSON *object, const char *string) {
    cJSON_Delete(cJSON_DetachItemFromObject(object, string));
}

CJSON_PUBLIC(void) cJSON_DeleteItemFromObjectCaseSensitive(cJSON *object, const char *string) {
    cJSON_Delete(cJSON_DetachItemFromObjectCaseSensitive(object, string));
}

/* Insert/Replace */
CJSON_PUBLIC(cJSON_bool) cJSON_InsertItemInArray(cJSON *array, int which, cJSON *newitem) {
    cJSON *after_item = cJSON_GetArrayItem(array, which);
    if (!after_item) return cJSON_AddItemToArray(array, newitem);
    
    newitem->next = after_item;
    newitem->prev = after_item->prev;
    if (after_item->prev) after_item->prev->next = newitem;
    after_item->prev = newitem;
    if (array->child == after_item) array->child = newitem;
    
    return 1;
}

CJSON_PUBLIC(cJSON_bool) cJSON_ReplaceItemViaPointer(cJSON * const parent, cJSON * const item, cJSON * replacement) {
    if (!parent || !item || !replacement) return 0;
    
    if (replacement == item) return 1;
    
    replacement->next = item->next;
    replacement->prev = item->prev;
    
    if (replacement->next) replacement->next->prev = replacement;
    if (parent->child == item) {
        parent->child = replacement;
    } else if (replacement->prev) {
        replacement->prev->next = replacement;
    }
    
    item->next = NULL;
    item->prev = NULL;
    cJSON_Delete(item);
    
    return 1;
}

CJSON_PUBLIC(cJSON_bool) cJSON_ReplaceItemInArray(cJSON *array, int which, cJSON *newitem) {
    return cJSON_ReplaceItemViaPointer(array, cJSON_GetArrayItem(array, which), newitem);
}

CJSON_PUBLIC(cJSON_bool) cJSON_ReplaceItemInObject(cJSON *object, const char *string, cJSON *newitem) {
    if (!newitem || !newitem->string) {
        if (newitem) newitem->string = strdup(string);
    }
    return cJSON_ReplaceItemViaPointer(object, cJSON_GetObjectItem(object, string), newitem);
}

CJSON_PUBLIC(cJSON_bool) cJSON_ReplaceItemInObjectCaseSensitive(cJSON *object, const char *string, cJSON *newitem) {
    if (!newitem || !newitem->string) {
        if (newitem) newitem->string = strdup(string);
    }
    return cJSON_ReplaceItemViaPointer(object, cJSON_GetObjectItemCaseSensitive(object, string), newitem);
}

/* Duplicate */
CJSON_PUBLIC(cJSON *) cJSON_Duplicate(const cJSON *item, cJSON_bool recurse) {
    cJSON *newitem, *child, *next, *newchild;
    
    if (!item) return NULL;
    
    newitem = cJSON_New_Item();
    if (!newitem) return NULL;
    
    newitem->type = item->type & (~cJSON_IsReference);
    newitem->valueint = item->valueint;
    newitem->valuedouble = item->valuedouble;
    
    if (item->valuestring) {
        newitem->valuestring = strdup(item->valuestring);
        if (!newitem->valuestring) { cJSON_Delete(newitem); return NULL; }
    }
    if (item->string) {
        newitem->string = strdup(item->string);
        if (!newitem->string) { cJSON_Delete(newitem); return NULL; }
    }
    
    if (!recurse) return newitem;
    
    child = item->child;
    while (child) {
        newchild = cJSON_Duplicate(child, 1);
        if (!newchild) { cJSON_Delete(newitem); return NULL; }
        if (next) {
            next->next = newchild;
            newchild->prev = next;
        } else {
            newitem->child = newchild;
        }
        next = newchild;
        child = child->next;
    }
    
    return newitem;
}

/* Minify */
CJSON_PUBLIC(void) cJSON_Minify(char *json) {
    char *into = json;
    if (!json) return;
    
    while (*json) {
        if (*json == ' ' || *json == '\t' || *json == '\r' || *json == '\n') {
            json++;
        } else if (*json == '\"') {
            *into++ = *json++;
            while (*json && *json != '\"') {
                if (*json == '\\') *into++ = *json++;
                *into++ = *json++;
            }
            *into++ = *json++;
        } else {
            *into++ = *json++;
        }
    }
    *into = '\0';
}

/* Array creators */
CJSON_PUBLIC(cJSON *) cJSON_CreateIntArray(const int *numbers, int count) {
    cJSON *a = cJSON_CreateArray();
    if (!a) return NULL;
    for (int i = 0; i < count; i++) {
        if (!cJSON_AddItemToArray(a, cJSON_CreateNumber(numbers[i]))) {
            cJSON_Delete(a);
            return NULL;
        }
    }
    return a;
}

CJSON_PUBLIC(cJSON *) cJSON_CreateFloatArray(const float *numbers, int count) {
    cJSON *a = cJSON_CreateArray();
    if (!a) return NULL;
    for (int i = 0; i < count; i++) {
        if (!cJSON_AddItemToArray(a, cJSON_CreateNumber(numbers[i]))) {
            cJSON_Delete(a);
            return NULL;
        }
    }
    return a;
}

CJSON_PUBLIC(cJSON *) cJSON_CreateDoubleArray(const double *numbers, int count) {
    cJSON *a = cJSON_CreateArray();
    if (!a) return NULL;
    for (int i = 0; i < count; i++) {
        if (!cJSON_AddItemToArray(a, cJSON_CreateNumber(numbers[i]))) {
            cJSON_Delete(a);
            return NULL;
        }
    }
    return a;
}

CJSON_PUBLIC(cJSON *) cJSON_CreateStringArray(const char *const *strings, int count) {
    cJSON *a = cJSON_CreateArray();
    if (!a) return NULL;
    for (int i = 0; i < count; i++) {
        if (!cJSON_AddItemToArray(a, cJSON_CreateString(strings[i]))) {
            cJSON_Delete(a);
            return NULL;
        }
    }
    return a;
}

