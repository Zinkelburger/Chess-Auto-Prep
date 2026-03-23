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

#ifndef cJSON__h
#define cJSON__h

#ifdef __cplusplus
extern "C"
{
#endif

#include <stddef.h>

/* cJSON Types: */
#define cJSON_Invalid (0)
#define cJSON_False  (1 << 0)
#define cJSON_True   (1 << 1)
#define cJSON_NULL   (1 << 2)
#define cJSON_Number (1 << 3)
#define cJSON_String (1 << 4)
#define cJSON_Array  (1 << 5)
#define cJSON_Object (1 << 6)
#define cJSON_Raw    (1 << 7) /* raw json */

#define cJSON_IsReference 256
#define cJSON_StringIsConst 512

/* The cJSON structure: */
typedef struct cJSON
{
    struct cJSON *next;
    struct cJSON *prev;
    struct cJSON *child;
    int type;
    char *valuestring;
    int valueint;
    double valuedouble;
    char *string;
} cJSON;

typedef struct cJSON_Hooks
{
      void *(*malloc_fn)(size_t sz);
      void (*free_fn)(void *ptr);
} cJSON_Hooks;

typedef int cJSON_bool;

#define CJSON_PUBLIC(type)   type

/* Supply malloc, realloc and free functions to cJSON */
CJSON_PUBLIC(void) cJSON_InitHooks(cJSON_Hooks* hooks);

/* Memory Management */
CJSON_PUBLIC(void) cJSON_free(void *object);

/* Supply a block of JSON, and this returns a cJSON object you can interrogate. */
CJSON_PUBLIC(cJSON *) cJSON_Parse(const char *value);
CJSON_PUBLIC(cJSON *) cJSON_ParseWithLength(const char *value, size_t buffer_length);
/* Render a cJSON entity to text for transfer/storage. */
CJSON_PUBLIC(char *) cJSON_Print(const cJSON *item);
/* Render a cJSON entity to text for transfer/storage without any formatting. */
CJSON_PUBLIC(char *) cJSON_PrintUnformatted(const cJSON *item);
/* Delete a cJSON entity and all subentities. */
CJSON_PUBLIC(void) cJSON_Delete(cJSON *item);

/* Returns the number of items in an array (or object). */
CJSON_PUBLIC(int) cJSON_GetArraySize(const cJSON *array);
/* Retrieve item number "index" from array "array". Returns NULL if unsuccessful. */
CJSON_PUBLIC(cJSON *) cJSON_GetArrayItem(const cJSON *array, int index);
/* Get item "string" from object. Case insensitive. */
CJSON_PUBLIC(cJSON *) cJSON_GetObjectItem(const cJSON * const object, const char * const string);
CJSON_PUBLIC(cJSON *) cJSON_GetObjectItemCaseSensitive(const cJSON * const object, const char * const string);
CJSON_PUBLIC(cJSON_bool) cJSON_HasObjectItem(const cJSON *object, const char *string);

/* Check if the item is a string and return its valuestring */
CJSON_PUBLIC(char *) cJSON_GetStringValue(const cJSON * const item);
/* Check if the item is a number and return its valuedouble */
CJSON_PUBLIC(double) cJSON_GetNumberValue(const cJSON * const item);

/* These functions check the type of an item */
CJSON_PUBLIC(cJSON_bool) cJSON_IsInvalid(const cJSON * const item);
CJSON_PUBLIC(cJSON_bool) cJSON_IsFalse(const cJSON * const item);
CJSON_PUBLIC(cJSON_bool) cJSON_IsTrue(const cJSON * const item);
CJSON_PUBLIC(cJSON_bool) cJSON_IsBool(const cJSON * const item);
CJSON_PUBLIC(cJSON_bool) cJSON_IsNull(const cJSON * const item);
CJSON_PUBLIC(cJSON_bool) cJSON_IsNumber(const cJSON * const item);
CJSON_PUBLIC(cJSON_bool) cJSON_IsString(const cJSON * const item);
CJSON_PUBLIC(cJSON_bool) cJSON_IsArray(const cJSON * const item);
CJSON_PUBLIC(cJSON_bool) cJSON_IsObject(const cJSON * const item);
CJSON_PUBLIC(cJSON_bool) cJSON_IsRaw(const cJSON * const item);

/* These calls create a cJSON item of the appropriate type. */
CJSON_PUBLIC(cJSON *) cJSON_CreateNull(void);
CJSON_PUBLIC(cJSON *) cJSON_CreateTrue(void);
CJSON_PUBLIC(cJSON *) cJSON_CreateFalse(void);
CJSON_PUBLIC(cJSON *) cJSON_CreateBool(cJSON_bool boolean);
CJSON_PUBLIC(cJSON *) cJSON_CreateNumber(double num);
CJSON_PUBLIC(cJSON *) cJSON_CreateString(const char *string);
CJSON_PUBLIC(cJSON *) cJSON_CreateRaw(const char *raw);
CJSON_PUBLIC(cJSON *) cJSON_CreateArray(void);
CJSON_PUBLIC(cJSON *) cJSON_CreateObject(void);

/* Create a string where valuestring references a string so it will not be freed by cJSON_Delete */
CJSON_PUBLIC(cJSON *) cJSON_CreateStringReference(const char *string);
/* Create an object/array that only references it's elements so they will not be freed by cJSON_Delete */
CJSON_PUBLIC(cJSON *) cJSON_CreateObjectReference(const cJSON *child);
CJSON_PUBLIC(cJSON *) cJSON_CreateArrayReference(const cJSON *child);

/* These utilities create an Array of count items. */
CJSON_PUBLIC(cJSON *) cJSON_CreateIntArray(const int *numbers, int count);
CJSON_PUBLIC(cJSON *) cJSON_CreateFloatArray(const float *numbers, int count);
CJSON_PUBLIC(cJSON *) cJSON_CreateDoubleArray(const double *numbers, int count);
CJSON_PUBLIC(cJSON *) cJSON_CreateStringArray(const char *const *strings, int count);

/* Append item to the specified array/object. */
CJSON_PUBLIC(cJSON_bool) cJSON_AddItemToArray(cJSON *array, cJSON *item);
CJSON_PUBLIC(cJSON_bool) cJSON_AddItemToObject(cJSON *object, const char *string, cJSON *item);
/* Use this when string is definitely const (i.e. a literal, or as good as), and will definitely survive the cJSON object. */
CJSON_PUBLIC(cJSON_bool) cJSON_AddItemToObjectCS(cJSON *object, const char *string, cJSON *item);
/* Append reference to item to the specified array/object. Use this when you want to add an existing cJSON to a new cJSON, but don't want to corrupt your existing cJSON. */
CJSON_PUBLIC(cJSON_bool) cJSON_AddItemReferenceToArray(cJSON *array, cJSON *item);
CJSON_PUBLIC(cJSON_bool) cJSON_AddItemReferenceToObject(cJSON *object, const char *string, cJSON *item);

/* Remove/Detach items from Arrays/Objects. */
CJSON_PUBLIC(cJSON *) cJSON_DetachItemViaPointer(cJSON *parent, cJSON * const item);
CJSON_PUBLIC(cJSON *) cJSON_DetachItemFromArray(cJSON *array, int which);
CJSON_PUBLIC(void) cJSON_DeleteItemFromArray(cJSON *array, int which);
CJSON_PUBLIC(cJSON *) cJSON_DetachItemFromObject(cJSON *object, const char *string);
CJSON_PUBLIC(cJSON *) cJSON_DetachItemFromObjectCaseSensitive(cJSON *object, const char *string);
CJSON_PUBLIC(void) cJSON_DeleteItemFromObject(cJSON *object, const char *string);
CJSON_PUBLIC(void) cJSON_DeleteItemFromObjectCaseSensitive(cJSON *object, const char *string);

/* Update array items. */
CJSON_PUBLIC(cJSON_bool) cJSON_InsertItemInArray(cJSON *array, int which, cJSON *newitem);
CJSON_PUBLIC(cJSON_bool) cJSON_ReplaceItemViaPointer(cJSON * const parent, cJSON * const item, cJSON * replacement);
CJSON_PUBLIC(cJSON_bool) cJSON_ReplaceItemInArray(cJSON *array, int which, cJSON *newitem);
CJSON_PUBLIC(cJSON_bool) cJSON_ReplaceItemInObject(cJSON *object,const char *string,cJSON *newitem);
CJSON_PUBLIC(cJSON_bool) cJSON_ReplaceItemInObjectCaseSensitive(cJSON *object,const char *string,cJSON *newitem);

/* Duplicate a cJSON item */
CJSON_PUBLIC(cJSON *) cJSON_Duplicate(const cJSON *item, cJSON_bool recurse);
/* Duplicate will create a new, identical cJSON item to the one you pass, in new memory that will need to be released. */
/* With recurse!=0, it will duplicate any children connected to the item. */
/* The item->next and ->prev pointers are always zero on return from Duplicate. */

/* Minify a strings, remove blank characters(such as ' ', '\t', '\r', '\n') from strings. */
CJSON_PUBLIC(void) cJSON_Minify(char *json);

/* Helper functions for creating and adding items to an object at the same time. */
CJSON_PUBLIC(cJSON*) cJSON_AddNullToObject(cJSON * const object, const char * const name);
CJSON_PUBLIC(cJSON*) cJSON_AddTrueToObject(cJSON * const object, const char * const name);
CJSON_PUBLIC(cJSON*) cJSON_AddFalseToObject(cJSON * const object, const char * const name);
CJSON_PUBLIC(cJSON*) cJSON_AddBoolToObject(cJSON * const object, const char * const name, const cJSON_bool boolean);
CJSON_PUBLIC(cJSON*) cJSON_AddNumberToObject(cJSON * const object, const char * const name, const double number);
CJSON_PUBLIC(cJSON*) cJSON_AddStringToObject(cJSON * const object, const char * const name, const char * const string);
CJSON_PUBLIC(cJSON*) cJSON_AddRawToObject(cJSON * const object, const char * const name, const char * const raw);
CJSON_PUBLIC(cJSON*) cJSON_AddObjectToObject(cJSON * const object, const char * const name);
CJSON_PUBLIC(cJSON*) cJSON_AddArrayToObject(cJSON * const object, const char * const name);

/* Macro for iterating over an array or object */
#define cJSON_ArrayForEach(element, array) for(element = (array != NULL) ? (array)->child : NULL; element != NULL; element = element->next)

#ifdef __cplusplus
}
#endif

#endif

