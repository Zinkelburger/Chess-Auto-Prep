/**
 * lichess_api.h - Lichess Explorer API Interface
 * 
 * Provides access to Lichess opening explorer data.
 * Uses libcurl for HTTP requests and parses JSON responses.
 */

#ifndef LICHESS_API_H
#define LICHESS_API_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

/* Maximum moves returned from explorer */
#define MAX_EXPLORER_MOVES 64

/* Maximum UCI/SAN move length */
#define MAX_API_MOVE_LENGTH 16


/**
 * ExplorerMove - A single move from the explorer
 */
typedef struct ExplorerMove {
    char uci[MAX_API_MOVE_LENGTH];      /* UCI notation (e.g., "e2e4") */
    char san[MAX_API_MOVE_LENGTH];      /* SAN notation (e.g., "e4") */
    
    uint64_t white_wins;                /* White wins after this move */
    uint64_t draws;                     /* Draws after this move */
    uint64_t black_wins;                /* Black wins after this move */
    
    double probability;                 /* Move probability (calculated) */
    
} ExplorerMove;


/**
 * ExplorerResponse - Response from the Lichess explorer API
 */
typedef struct ExplorerResponse {
    /* Position totals */
    uint64_t total_white_wins;
    uint64_t total_draws;
    uint64_t total_black_wins;
    uint64_t total_games;
    
    /* Available moves */
    ExplorerMove moves[MAX_EXPLORER_MOVES];
    size_t move_count;
    
    /* Opening info */
    char opening_eco[8];            /* ECO code, e.g., "B20" */
    char opening_name[128];         /* Opening name, e.g., "Sicilian Defense" */
    bool has_opening;               /* Whether opening info is available */
    
    /* Status */
    bool success;
    char error_message[256];
    
} ExplorerResponse;


/**
 * LichessExplorer - Explorer API client
 */
typedef struct LichessExplorer {
    /* Configuration */
    char *rating_range;                 /* e.g., "1600,1800,2000,2200" */
    char *speeds;                       /* e.g., "blitz,rapid,classical" */
    char *variant;                      /* e.g., "standard" */
    
    /* Rate limiting */
    int request_delay_ms;               /* Delay between requests */
    uint64_t last_request_time;         /* Timestamp of last request */
    
    /* Statistics */
    uint64_t total_requests;
    uint64_t failed_requests;
    
    /* Authentication */
    char *auth_token;                   /* Lichess API token (Bearer) */
    
    /* Internal state */
    void *curl_handle;                  /* CURL handle */
    
} LichessExplorer;


/**
 * Create a new Lichess explorer instance
 * 
 * @return Newly allocated LichessExplorer, or NULL on failure
 */
LichessExplorer* lichess_explorer_create(void);

/**
 * Free explorer resources
 * 
 * @param explorer The explorer to free
 */
void lichess_explorer_destroy(LichessExplorer *explorer);

/**
 * Set rating range for queries
 * 
 * @param explorer The explorer to configure
 * @param ratings Comma-separated ratings (e.g., "1600,1800,2000,2200")
 */
void lichess_explorer_set_ratings(LichessExplorer *explorer, const char *ratings);

/**
 * Set time control speeds for queries
 * 
 * @param explorer The explorer to configure
 * @param speeds Comma-separated speeds (e.g., "blitz,rapid,classical")
 */
void lichess_explorer_set_speeds(LichessExplorer *explorer, const char *speeds);

/**
 * Set request delay (rate limiting)
 * 
 * @param explorer The explorer to configure
 * @param delay_ms Delay in milliseconds between requests
 */
void lichess_explorer_set_delay(LichessExplorer *explorer, int delay_ms);

/**
 * Set authentication token for API requests
 * 
 * @param explorer The explorer to configure
 * @param token Lichess personal access token or OAuth token
 */
void lichess_explorer_set_token(LichessExplorer *explorer, const char *token);

/**
 * Query the Lichess explorer for a position
 * 
 * @param explorer The explorer instance
 * @param fen The FEN position to query
 * @param response Output response structure
 * @return true on success, false on failure
 */
bool lichess_explorer_query(LichessExplorer *explorer, const char *fen,
                            ExplorerResponse *response);

/**
 * Query the Lichess masters database
 * 
 * @param explorer The explorer instance
 * @param fen The FEN position to query
 * @param response Output response structure
 * @return true on success, false on failure
 */
bool lichess_explorer_query_masters(LichessExplorer *explorer, const char *fen,
                                    ExplorerResponse *response);

/**
 * Get the opening name for a position (if known)
 * 
 * @param explorer The explorer instance
 * @param fen The FEN position to query
 * @param out_name Output buffer for opening name
 * @param max_len Maximum length of output buffer
 * @return true if opening name found, false otherwise
 */
bool lichess_explorer_get_opening(LichessExplorer *explorer, const char *fen,
                                  char *out_name, size_t max_len);

/**
 * Print explorer statistics
 * 
 * @param explorer The explorer to summarize
 */
void lichess_explorer_print_stats(const LichessExplorer *explorer);

#endif /* LICHESS_API_H */

