/**
 * lichess_api.c - Lichess Explorer API Implementation
 * 
 * Uses libcurl for HTTP requests and cJSON for JSON parsing.
 */

#include "lichess_api.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>

#ifdef _WIN32
#include <windows.h>
#define usleep(x) Sleep((x) / 1000)
#else
#include <unistd.h>
#endif

#include <curl/curl.h>
#include "cJSON.h"


/* Lichess API endpoints */
#define LICHESS_EXPLORER_URL "https://explorer.lichess.ovh/lichess"
#define LICHESS_MASTERS_URL  "https://explorer.lichess.ovh/masters"

/* Default rate limit delay (1 second) */
#define DEFAULT_DELAY_MS 1000


/**
 * Buffer for CURL response
 */
typedef struct {
    char *data;
    size_t size;
    size_t capacity;
} ResponseBuffer;


static size_t write_callback(void *contents, size_t size, size_t nmemb, void *userp) {
    size_t realsize = size * nmemb;
    ResponseBuffer *buf = (ResponseBuffer *)userp;
    
    /* Grow buffer if needed */
    if (buf->size + realsize + 1 > buf->capacity) {
        size_t new_cap = buf->capacity * 2;
        if (new_cap < buf->size + realsize + 1) {
            new_cap = buf->size + realsize + 1;
        }
        char *new_data = (char *)realloc(buf->data, new_cap);
        if (!new_data) {
            return 0;
        }
        buf->data = new_data;
        buf->capacity = new_cap;
    }
    
    memcpy(buf->data + buf->size, contents, realsize);
    buf->size += realsize;
    buf->data[buf->size] = '\0';
    
    return realsize;
}


LichessExplorer* lichess_explorer_create(void) {
    /* Initialize CURL globally (if not already done) */
    static int curl_initialized = 0;
    if (!curl_initialized) {
        curl_global_init(CURL_GLOBAL_ALL);
        curl_initialized = 1;
    }
    
    LichessExplorer *explorer = (LichessExplorer *)calloc(1, sizeof(LichessExplorer));
    if (!explorer) {
        return NULL;
    }
    
    /* Initialize CURL handle */
    explorer->curl_handle = curl_easy_init();
    if (!explorer->curl_handle) {
        free(explorer);
        return NULL;
    }
    
    /* Set defaults */
    explorer->rating_range = strdup("2000,2200,2500");
    explorer->speeds = strdup("blitz,rapid,classical");
    explorer->variant = strdup("standard");
    explorer->request_delay_ms = DEFAULT_DELAY_MS;
    explorer->last_request_time = 0;
    explorer->total_requests = 0;
    explorer->failed_requests = 0;
    
    return explorer;
}


void lichess_explorer_destroy(LichessExplorer *explorer) {
    if (!explorer) return;
    
    if (explorer->curl_handle) {
        curl_easy_cleanup(explorer->curl_handle);
    }
    
    free(explorer->rating_range);
    free(explorer->speeds);
    free(explorer->variant);
    free(explorer->auth_token);
    free(explorer);
}


void lichess_explorer_set_ratings(LichessExplorer *explorer, const char *ratings) {
    if (!explorer || !ratings) return;
    
    free(explorer->rating_range);
    explorer->rating_range = strdup(ratings);
}


void lichess_explorer_set_speeds(LichessExplorer *explorer, const char *speeds) {
    if (!explorer || !speeds) return;
    
    free(explorer->speeds);
    explorer->speeds = strdup(speeds);
}


void lichess_explorer_set_delay(LichessExplorer *explorer, int delay_ms) {
    if (!explorer) return;
    explorer->request_delay_ms = delay_ms;
}


void lichess_explorer_set_token(LichessExplorer *explorer, const char *token) {
    if (!explorer) return;
    free(explorer->auth_token);
    explorer->auth_token = token ? strdup(token) : NULL;
}


/**
 * URL-encode a FEN string
 */
static char* url_encode_fen(CURL *curl, const char *fen) {
    return curl_easy_escape(curl, fen, 0);
}


/**
 * Parse explorer response JSON
 */
static bool parse_explorer_response(const char *json_str, ExplorerResponse *response) {
    cJSON *root = cJSON_Parse(json_str);
    if (!root) {
        snprintf(response->error_message, sizeof(response->error_message),
                 "Failed to parse JSON response");
        return false;
    }
    
    response->success = true;
    response->move_count = 0;
    
    /* Parse total stats */
    cJSON *white = cJSON_GetObjectItem(root, "white");
    cJSON *draws = cJSON_GetObjectItem(root, "draws");
    cJSON *black = cJSON_GetObjectItem(root, "black");
    
    response->total_white_wins = white ? (uint64_t)white->valuedouble : 0;
    response->total_draws = draws ? (uint64_t)draws->valuedouble : 0;
    response->total_black_wins = black ? (uint64_t)black->valuedouble : 0;
    response->total_games = response->total_white_wins + 
                            response->total_draws + 
                            response->total_black_wins;
    
    /* Parse moves array */
    cJSON *moves = cJSON_GetObjectItem(root, "moves");
    if (moves && cJSON_IsArray(moves)) {
        cJSON *move_item;
        cJSON_ArrayForEach(move_item, moves) {
            if (response->move_count >= MAX_EXPLORER_MOVES) break;
            
            ExplorerMove *em = &response->moves[response->move_count];
            
            /* Get move notation */
            cJSON *uci = cJSON_GetObjectItem(move_item, "uci");
            cJSON *san = cJSON_GetObjectItem(move_item, "san");
            
            if (uci && cJSON_IsString(uci)) {
                strncpy(em->uci, uci->valuestring, MAX_API_MOVE_LENGTH - 1);
            }
            if (san && cJSON_IsString(san)) {
                strncpy(em->san, san->valuestring, MAX_API_MOVE_LENGTH - 1);
            }
            
            /* Get stats */
            cJSON *mw = cJSON_GetObjectItem(move_item, "white");
            cJSON *md = cJSON_GetObjectItem(move_item, "draws");
            cJSON *mb = cJSON_GetObjectItem(move_item, "black");
            
            em->white_wins = mw ? (uint64_t)mw->valuedouble : 0;
            em->draws = md ? (uint64_t)md->valuedouble : 0;
            em->black_wins = mb ? (uint64_t)mb->valuedouble : 0;
            
            /* Calculate probability (will be normalized by caller) */
            uint64_t move_total = em->white_wins + em->draws + em->black_wins;
            em->probability = response->total_games > 0 ? 
                              (double)move_total / (double)response->total_games : 0.0;
            
            response->move_count++;
        }
    }
    
    /* Parse opening info */
    cJSON *opening = cJSON_GetObjectItem(root, "opening");
    if (opening && cJSON_IsObject(opening)) {
        cJSON *eco = cJSON_GetObjectItem(opening, "eco");
        cJSON *name = cJSON_GetObjectItem(opening, "name");
        
        if (eco && cJSON_IsString(eco)) {
            strncpy(response->opening_eco, eco->valuestring, sizeof(response->opening_eco) - 1);
        }
        if (name && cJSON_IsString(name)) {
            strncpy(response->opening_name, name->valuestring, sizeof(response->opening_name) - 1);
        }
        response->has_opening = true;
    }
    
    cJSON_Delete(root);
    return true;
}


bool lichess_explorer_query(LichessExplorer *explorer, const char *fen,
                            ExplorerResponse *response) {
    if (!explorer || !fen || !response) {
        return false;
    }
    
    memset(response, 0, sizeof(ExplorerResponse));
    
    /* Rate limiting */
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    uint64_t now_ms = now.tv_sec * 1000 + now.tv_nsec / 1000000;
    
    if (explorer->last_request_time > 0) {
        uint64_t elapsed = now_ms - explorer->last_request_time;
        if (elapsed < (uint64_t)explorer->request_delay_ms) {
            usleep((explorer->request_delay_ms - elapsed) * 1000);
        }
    }
    
    CURL *curl = (CURL *)explorer->curl_handle;
    
    /* Build URL */
    char *encoded_fen = url_encode_fen(curl, fen);
    if (!encoded_fen) {
        snprintf(response->error_message, sizeof(response->error_message),
                 "Failed to encode FEN");
        return false;
    }
    
    char url[1024];
    snprintf(url, sizeof(url), 
             "%s?variant=%s&speeds=%s&ratings=%s&fen=%s",
             LICHESS_EXPLORER_URL,
             explorer->variant,
             explorer->speeds,
             explorer->rating_range,
             encoded_fen);
    
    curl_free(encoded_fen);
    
    /* Setup response buffer */
    ResponseBuffer buf = {
        .data = (char *)malloc(4096),
        .size = 0,
        .capacity = 4096
    };
    if (!buf.data) {
        return false;
    }
    
    /* Setup CURL request */
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &buf);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30L);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "tree_builder/1.0");
    
    /* Add auth header if token is set */
    struct curl_slist *headers = NULL;
    if (explorer->auth_token) {
        char auth_header[512];
        snprintf(auth_header, sizeof(auth_header),
                 "Authorization: Bearer %s", explorer->auth_token);
        headers = curl_slist_append(headers, auth_header);
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    }
    
    /* Perform request */
    CURLcode res = curl_easy_perform(curl);
    
    curl_slist_free_all(headers);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, NULL);
    
    clock_gettime(CLOCK_MONOTONIC, &now);
    explorer->last_request_time = now.tv_sec * 1000 + now.tv_nsec / 1000000;
    explorer->total_requests++;
    
    if (res != CURLE_OK) {
        snprintf(response->error_message, sizeof(response->error_message),
                 "CURL error: %s", curl_easy_strerror(res));
        explorer->failed_requests++;
        free(buf.data);
        return false;
    }
    
    /* Check HTTP response code */
    long http_code;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);
    
    if (http_code != 200) {
        snprintf(response->error_message, sizeof(response->error_message),
                 "HTTP error: %ld", http_code);
        explorer->failed_requests++;
        free(buf.data);
        return false;
    }
    
    /* Parse response */
    bool success = parse_explorer_response(buf.data, response);
    
    free(buf.data);
    
    if (!success) {
        explorer->failed_requests++;
    }
    
    return success;
}


bool lichess_explorer_query_masters(LichessExplorer *explorer, const char *fen,
                                    ExplorerResponse *response) {
    if (!explorer || !fen || !response) {
        return false;
    }
    
    memset(response, 0, sizeof(ExplorerResponse));
    
    /* Rate limiting */
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    uint64_t now_ms = now.tv_sec * 1000 + now.tv_nsec / 1000000;
    
    if (explorer->last_request_time > 0) {
        uint64_t elapsed = now_ms - explorer->last_request_time;
        if (elapsed < (uint64_t)explorer->request_delay_ms) {
            usleep((explorer->request_delay_ms - elapsed) * 1000);
        }
    }
    
    CURL *curl = (CURL *)explorer->curl_handle;
    
    /* Build URL */
    char *encoded_fen = url_encode_fen(curl, fen);
    if (!encoded_fen) {
        return false;
    }
    
    char url[1024];
    snprintf(url, sizeof(url), "%s?fen=%s", LICHESS_MASTERS_URL, encoded_fen);
    curl_free(encoded_fen);
    
    /* Setup response buffer */
    ResponseBuffer buf = {
        .data = (char *)malloc(4096),
        .size = 0,
        .capacity = 4096
    };
    if (!buf.data) {
        return false;
    }
    
    /* Setup and perform request */
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &buf);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30L);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "tree_builder/1.0");
    
    struct curl_slist *headers = NULL;
    if (explorer->auth_token) {
        char auth_header[512];
        snprintf(auth_header, sizeof(auth_header),
                 "Authorization: Bearer %s", explorer->auth_token);
        headers = curl_slist_append(headers, auth_header);
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    }
    
    CURLcode res = curl_easy_perform(curl);
    
    curl_slist_free_all(headers);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, NULL);
    
    clock_gettime(CLOCK_MONOTONIC, &now);
    explorer->last_request_time = now.tv_sec * 1000 + now.tv_nsec / 1000000;
    explorer->total_requests++;
    
    if (res != CURLE_OK) {
        explorer->failed_requests++;
        free(buf.data);
        return false;
    }
    
    long http_code;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);
    
    if (http_code != 200) {
        explorer->failed_requests++;
        free(buf.data);
        return false;
    }
    
    bool success = parse_explorer_response(buf.data, response);
    free(buf.data);
    
    if (!success) {
        explorer->failed_requests++;
    }
    
    return success;
}


bool lichess_explorer_get_opening(LichessExplorer *explorer, const char *fen,
                                  char *out_name, size_t max_len) {
    if (!explorer || !fen || !out_name || max_len == 0) {
        return false;
    }
    
    /* Query the explorer and check for opening name in response */
    /* Note: The Lichess API includes opening info in the response */
    /* This would require parsing the "opening" field from the JSON */
    
    /* For now, return false - could be implemented by modifying parse_explorer_response */
    out_name[0] = '\0';
    return false;
}


void lichess_explorer_print_stats(const LichessExplorer *explorer) {
    if (!explorer) {
        printf("Explorer: (null)\n");
        return;
    }
    
    printf("\n=== Lichess Explorer Stats ===\n");
    printf("Total requests: %lu\n", (unsigned long)explorer->total_requests);
    printf("Failed requests: %lu\n", (unsigned long)explorer->failed_requests);
    
    double success_rate = explorer->total_requests > 0 ?
        (double)(explorer->total_requests - explorer->failed_requests) / 
        (double)explorer->total_requests * 100.0 : 0.0;
    
    printf("Success rate: %.1f%%\n", success_rate);
    printf("Rating range: %s\n", explorer->rating_range ? explorer->rating_range : "(none)");
    printf("Speeds: %s\n", explorer->speeds ? explorer->speeds : "(none)");
    printf("Request delay: %d ms\n", explorer->request_delay_ms);
    printf("==============================\n\n");
}

