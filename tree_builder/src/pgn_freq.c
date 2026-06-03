/**
 * pgn_freq.c - PGN frequency map implementation
 */

#include "pgn_freq.h"
#include "fen_map.h"
#include "chess_logic.h"
#include "san_convert.h"

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define DEFAULT_START_FEN \
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

#define PGN_FREQ_INITIAL_BUCKETS 4096
#define PGN_FREQ_LOAD_FACTOR     0.75
#define PGN_FREQ_INITIAL_MOVES   8
#define PGN_MOVETEXT_BUF_SIZE    (256 * 1024)
#define PGN_MAX_PREFIX_MOVES     256
#define PGN_MOVE_HISTORY_LEN     16
#define PGN_HDR_FIELD_LEN        128
#define PGN_HDR_EVENT_LEN        256

#define PGN_FREQ_MAGIC_BYTES     "PFREQ\x01\x00\x00"
#define PGN_FREQ_CACHE_FILE_VERSION 1u

extern volatile int g_interrupted;

typedef struct PgnGameHeaders {
    char white[PGN_HDR_FIELD_LEN];
    char black[PGN_HDR_FIELD_LEN];
    char event[PGN_HDR_EVENT_LEN];
    char date[PGN_HDR_FIELD_LEN];
    char round[PGN_HDR_FIELD_LEN];
} PgnGameHeaders;

typedef struct PgnMoveHistory {
    char entries[PGN_MOVE_HISTORY_LEN][24];
    int count;
} PgnMoveHistory;

typedef struct PgnFreqEntry {
    PgnFreqPosition pos;
    struct PgnFreqEntry *next;
} PgnFreqEntry;

struct PgnFreqMap {
    PgnFreqEntry **buckets;
    size_t num_buckets;
    size_t count;
    uint64_t total_games;
};

static bool read_line(FILE *fp, char *buf, size_t buf_len);
static const char *skip_whitespace(const char *p);

static void pgn_headers_clear(PgnGameHeaders *hdr) {
    if (!hdr) return;
    memset(hdr, 0, sizeof(*hdr));
}

static void pgn_headers_set(PgnGameHeaders *hdr, const char *tag, const char *value) {
    char *dst = NULL;
    size_t cap = 0;

    if (strcmp(tag, "White") == 0) {
        dst = hdr->white;
        cap = sizeof(hdr->white);
    } else if (strcmp(tag, "Black") == 0) {
        dst = hdr->black;
        cap = sizeof(hdr->black);
    } else if (strcmp(tag, "Event") == 0) {
        dst = hdr->event;
        cap = sizeof(hdr->event);
    } else if (strcmp(tag, "Date") == 0) {
        dst = hdr->date;
        cap = sizeof(hdr->date);
    } else if (strcmp(tag, "Round") == 0) {
        dst = hdr->round;
        cap = sizeof(hdr->round);
    }
    if (dst && value)
        snprintf(dst, cap, "%s", value);
}

static bool parse_tag_line(const char *line, PgnGameHeaders *hdr) {
    const char *p = skip_whitespace(line);
    if (*p != '[') return false;
    p++;

    char tag[64];
    size_t ti = 0;
    while (*p && *p != ' ' && *p != '\t' && *p != ']') {
        if (ti + 1 < sizeof(tag)) tag[ti++] = *p;
        p++;
    }
    tag[ti] = '\0';
    if (!tag[0]) return false;

    while (*p && *p != '"') p++;
    if (*p != '"') return false;
    p++;

    char value[PGN_HDR_EVENT_LEN];
    size_t vi = 0;
    while (*p && *p != '"' && vi + 1 < sizeof(value)) value[vi++] = *p++;
    value[vi] = '\0';
    if (*p != '"') return false;

    pgn_headers_set(hdr, tag, value);
    return true;
}

static void format_san_ply_label(const ChessPosition *pos, const char *san,
                                 char *out, size_t out_len) {
    if (!pos || !san || !out || out_len == 0) return;
    if (pos->white_to_move)
        snprintf(out, out_len, "%d.%s", pos->fullmove_number, san);
    else
        snprintf(out, out_len, "%d...%s", pos->fullmove_number, san);
}

static void history_push(PgnMoveHistory *hist, const char *label) {
    if (!hist || !label || !label[0]) return;
    if (hist->count < PGN_MOVE_HISTORY_LEN) {
        snprintf(hist->entries[hist->count], sizeof(hist->entries[0]),
                 "%s", label);
        hist->count++;
        return;
    }
    for (int i = 1; i < PGN_MOVE_HISTORY_LEN; i++)
        memcpy(hist->entries[i - 1], hist->entries[i],
               sizeof(hist->entries[0]));
    snprintf(hist->entries[PGN_MOVE_HISTORY_LEN - 1],
             sizeof(hist->entries[0]), "%s", label);
    hist->count = PGN_MOVE_HISTORY_LEN;
}

static const char *hdr_or_unknown(const char *s) {
    return (s && s[0]) ? s : "?";
}

static void warn_move_failure(const char *reason, const char *san, int ply,
                              const char *fen, const ChessPosition *pos,
                              const PgnGameHeaders *hdr, int game_num,
                              const PgnMoveHistory *hist) {
    char failed_label[32];
    format_san_ply_label(pos, san, failed_label, sizeof(failed_label));

    fprintf(stderr, "Warning: %s '%s' at ply %d (FEN: %s)\n",
            reason, san, ply, fen);
    fprintf(stderr,
            "  Game #%d: White=%s, Black=%s, Event=%s, Round=%s, Date=%s\n",
            game_num,
            hdr_or_unknown(hdr ? hdr->white : NULL),
            hdr_or_unknown(hdr ? hdr->black : NULL),
            hdr_or_unknown(hdr ? hdr->event : NULL),
            hdr_or_unknown(hdr ? hdr->round : NULL),
            hdr_or_unknown(hdr ? hdr->date : NULL));

    fprintf(stderr, "  Recent moves:");
    int start = 0;
    if (hist && hist->count > 0) {
        start = hist->count > 8 ? hist->count - 8 : 0;
        for (int i = start; i < hist->count; i++)
            fprintf(stderr, " %s", hist->entries[i]);
        fprintf(stderr, " %s", failed_label);
    } else {
        fprintf(stderr, " %s", failed_label);
    }
    fprintf(stderr, "  <-- failed here\n");
    fprintf(stderr, "  Skipping rest of game.\n");
}

static uint32_t pgn_freq_hash(const char *key, size_t num_buckets) {
    uint32_t hash = 2166136261u;
    for (const char *p = key; *p; p++) {
        hash ^= (uint8_t)*p;
        hash *= 16777619u;
    }
    return hash % (uint32_t)num_buckets;
}

static bool pgn_freq_resize(PgnFreqMap *map) {
    size_t new_buckets = map->num_buckets * 2;
    PgnFreqEntry **new_table =
        (PgnFreqEntry **)calloc(new_buckets, sizeof(PgnFreqEntry *));
    if (!new_table) {
        fprintf(stderr,
                "Error: out of memory resizing PGN frequency map\n");
        return false;
    }

    for (size_t i = 0; i < map->num_buckets; i++) {
        PgnFreqEntry *e = map->buckets[i];
        while (e) {
            PgnFreqEntry *next = e->next;
            uint32_t idx = pgn_freq_hash(e->pos.fen_key, new_buckets);
            e->next = new_table[idx];
            new_table[idx] = e;
            e = next;
        }
    }
    free(map->buckets);
    map->buckets = new_table;
    map->num_buckets = new_buckets;
    return true;
}

static void pgn_freq_position_free(PgnFreqPosition *pos) {
    if (!pos) return;
    free(pos->moves);
    pos->moves = NULL;
    pos->move_count = 0;
    pos->move_capacity = 0;
}

static PgnFreqEntry *pgn_freq_find_entry(const PgnFreqMap *map, const char *fen_key) {
    if (!map || !fen_key) return NULL;
    uint32_t idx = pgn_freq_hash(fen_key, map->num_buckets);
    for (PgnFreqEntry *e = map->buckets[idx]; e; e = e->next) {
        if (strcmp(e->pos.fen_key, fen_key) == 0) return e;
    }
    return NULL;
}

static PgnFreqPosition *pgn_freq_get_or_create(PgnFreqMap *map, const char *fen_key) {
    PgnFreqEntry *existing = pgn_freq_find_entry(map, fen_key);
    if (existing) return &existing->pos;

    if ((double)map->count / (double)map->num_buckets >= PGN_FREQ_LOAD_FACTOR &&
        !pgn_freq_resize(map))
        return NULL;

    PgnFreqEntry *e = (PgnFreqEntry *)calloc(1, sizeof(PgnFreqEntry));
    if (!e) return NULL;

    snprintf(e->pos.fen_key, sizeof(e->pos.fen_key), "%s", fen_key);
    e->pos.move_capacity = PGN_FREQ_INITIAL_MOVES;
    e->pos.moves = (PgnFreqMove *)calloc((size_t)e->pos.move_capacity,
                                         sizeof(PgnFreqMove));
    if (!e->pos.moves) {
        free(e);
        return NULL;
    }

    uint32_t idx = pgn_freq_hash(fen_key, map->num_buckets);
    e->next = map->buckets[idx];
    map->buckets[idx] = e;
    map->count++;
    return &e->pos;
}

static bool pgn_freq_record_move(PgnFreqMap *map, const char *fen_key,
                                 const char *uci, const char *san) {
    PgnFreqPosition *pos = pgn_freq_get_or_create(map, fen_key);
    if (!pos) return false;

    for (int i = 0; i < pos->move_count; i++) {
        if (strcmp(pos->moves[i].uci, uci) == 0) {
            pos->moves[i].count++;
            return true;
        }
    }

    if (pos->move_count >= pos->move_capacity) {
        int new_cap = pos->move_capacity ? pos->move_capacity * 2 : PGN_FREQ_INITIAL_MOVES;
        PgnFreqMove *nm = (PgnFreqMove *)realloc(pos->moves,
                                                 (size_t)new_cap * sizeof(PgnFreqMove));
        if (!nm) {
            fprintf(stderr,
                    "Error: out of memory recording move at '%s'\n", fen_key);
            return false;
        }
        pos->moves = nm;
        pos->move_capacity = new_cap;
    }

    PgnFreqMove *m = &pos->moves[pos->move_count++];
    memset(m, 0, sizeof(*m));
    snprintf(m->uci, sizeof(m->uci), "%s", uci);
    snprintf(m->san, sizeof(m->san), "%.15s", san);
    m->count = 1;
    return true;
}

static bool pgn_freq_record_reach(PgnFreqMap *map, const char *fen_key) {
    PgnFreqPosition *pos = pgn_freq_get_or_create(map, fen_key);
    if (!pos) return false;
    pos->reach_count++;
    return true;
}

/** process_game_movetext result codes */
#define PGN_GAME_OK            1
#define PGN_GAME_PREFIX_SKIP   0
#define PGN_GAME_ERROR        -1  /* illegal move etc. — skip game */
#define PGN_GAME_OOM          -2  /* abort entire parse */

static bool is_move_number_token(const char *tok) {
    if (!tok || !*tok) return false;
    const char *p = tok;
    if (!isdigit((unsigned char)*p)) return false;
    while (isdigit((unsigned char)*p)) p++;
    return *p == '.' || *p == '\0';
}

static bool is_result_token(const char *tok) {
    return tok && (strcmp(tok, "1-0") == 0 || strcmp(tok, "0-1") == 0 ||
                   strcmp(tok, "1/2-1/2") == 0 || strcmp(tok, "*") == 0);
}

/** Extract SAN from a PGN token (handles "1.e4", "12.Nf3", "1...c5", bare "e4"). */
static bool token_to_san(const char *tok, char *san_out, size_t san_len) {
    if (!tok || !tok[0] || !san_out || san_len == 0) return false;

    const char *p = tok;
    while (isdigit((unsigned char)*p)) p++;

    if (p > tok) {
        if (*p != '.') {
            snprintf(san_out, san_len, "%.*s",
                     (int)(san_len - 1), tok);
            return san_out[0] != '\0';
        }
        while (*p == '.') p++;
        if (!*p) return false;
        snprintf(san_out, san_len, "%.*s",
                 (int)(san_len - 1), p);
        return san_out[0] != '\0';
    }

    snprintf(san_out, san_len, "%.*s", (int)(san_len - 1), tok);
    return san_out[0] != '\0';
}

static bool san_moves_match(const char *a, const char *b) {
    if (!a || !b) return false;
    if (strcmp(a, b) == 0) return true;

    /* Castling: PGN may use 0-0 while SAN converter normalizes to O-O. */
    if ((strcmp(a, "O-O") == 0 || strcmp(a, "0-0") == 0) &&
        (strcmp(b, "O-O") == 0 || strcmp(b, "0-0") == 0))
        return true;
    if ((strcmp(a, "O-O-O") == 0 || strcmp(a, "0-0-0") == 0) &&
        (strcmp(b, "O-O-O") == 0 || strcmp(b, "0-0-0") == 0))
        return true;
    return false;
}

static int parse_prefix_moves(const char *start_moves,
                              char prefix[PGN_MAX_PREFIX_MOVES][16]) {
    if (!start_moves || !start_moves[0]) return 0;

    char copy[4096];
    snprintf(copy, sizeof(copy), "%s", start_moves);

    int count = 0;
    char *saveptr = NULL;
    for (char *tok = strtok_r(copy, " \t\r\n", &saveptr);
         tok && count < PGN_MAX_PREFIX_MOVES;
         tok = strtok_r(NULL, " \t\r\n", &saveptr)) {
        if (is_move_number_token(tok)) continue;
        if (is_result_token(tok)) break;
        snprintf(prefix[count], 16, "%s", tok);
        count++;
    }
    return count;
}

static const char *skip_whitespace(const char *p) {
    while (*p && isspace((unsigned char)*p)) p++;
    return p;
}

static const char *skip_comment(const char *p) {
    if (*p != '{') return p;
    p++;
    while (*p && *p != '}') p++;
    if (*p == '}') p++;
    return p;
}

static const char *skip_variation(const char *p) {
    if (*p != '(') return p;
    int depth = 1;
    p++;
    while (*p && depth > 0) {
        if (*p == '(') depth++;
        else if (*p == ')') depth--;
        p++;
    }
    return p;
}

/** After a truncated movetext read, skip to the next game boundary. */
static void skip_rest_of_game(FILE *fp) {
    char line[4096];
    while (!g_interrupted && read_line(fp, line, sizeof(line))) {
        const char *p = skip_whitespace(line);
        if (*p == '\0') return;
        if (*p == '[') {
            fseek(fp, -(long)strlen(line), SEEK_CUR);
            return;
        }
    }
}

static const char *next_token(const char *p, char *tok, size_t tok_len) {
    p = skip_whitespace(p);
    if (!*p) {
        tok[0] = '\0';
        return p;
    }

    while (*p == '{' || *p == '(') {
        if (*p == '{') p = skip_comment(p);
        else p = skip_variation(p);
        p = skip_whitespace(p);
        if (!*p) {
            tok[0] = '\0';
            return p;
        }
    }

    size_t i = 0;
    while (*p && !isspace((unsigned char)*p) && *p != '{' && *p != '(') {
        if (i + 1 < tok_len) tok[i++] = *p;
        p++;
    }
    tok[i] = '\0';
    /* Strip CR/LF artifacts from Windows PGN files. */
    while (i > 0 && (tok[i - 1] == '\r' || tok[i - 1] == '\n'))
        tok[--i] = '\0';
    return p;
}

static int process_game_movetext(PgnFreqMap *map, const PgnFreqConfig *cfg,
                                 const char *movetext,
                                 char prefix[PGN_MAX_PREFIX_MOVES][16],
                                 int prefix_len,
                                 const PgnGameHeaders *hdr, int game_num) {
    ChessPosition pos;
    const char *start_fen = (cfg && cfg->start_fen) ? cfg->start_fen : DEFAULT_START_FEN;
    if (!position_from_fen(&pos, start_fen)) return PGN_GAME_ERROR;

    char fen_buf[MAX_FEN_LENGTH];
    position_to_fen(&pos, fen_buf, sizeof(fen_buf));

    bool tracking = (prefix_len == 0);
    int prefix_idx = 0;
    int ply = 0;
    int ply_tracked = 0;
    int max_ply = cfg ? cfg->max_ply : 0;
    PgnMoveHistory history;
    memset(&history, 0, sizeof(history));

    const char *p = movetext;
    char tok[64];

    while (*p) {
        if (g_interrupted) return PGN_GAME_ERROR;

        p = next_token(p, tok, sizeof(tok));
        if (!tok[0]) break;

        char san[16];
        if (!token_to_san(tok, san, sizeof(san))) continue;
        if (is_result_token(san)) break;

        char uci[8];
        if (!san_to_uci(fen_buf, san, uci, sizeof(uci))) {
            warn_move_failure("cannot apply move", san, ply, fen_buf, &pos,
                              hdr, game_num, &history);
            return PGN_GAME_ERROR;
        }

        if (!tracking) {
            if (prefix_idx >= prefix_len ||
                !san_moves_match(san, prefix[prefix_idx])) {
                return PGN_GAME_PREFIX_SKIP;
            }
            char label[24];
            format_san_ply_label(&pos, san, label, sizeof(label));
            if (!position_apply_uci(&pos, uci)) {
                warn_move_failure("cannot apply move", san, ply, fen_buf, &pos,
                                  hdr, game_num, &history);
                return PGN_GAME_ERROR;
            }
            position_to_fen(&pos, fen_buf, sizeof(fen_buf));
            history_push(&history, label);
            ply++;
            prefix_idx++;
            if (prefix_idx >= prefix_len) {
                tracking = true;
                char key[FEN_KEY_MAX_LENGTH];
                fen_map_canonicalize_key(fen_buf, key, sizeof(key));
                if (!pgn_freq_record_reach(map, key))
                    return PGN_GAME_OOM;
            }
            continue;
        }

        if (max_ply > 0 && ply_tracked >= max_ply) break;

        char key[FEN_KEY_MAX_LENGTH];
        fen_map_canonicalize_key(fen_buf, key, sizeof(key));
        if (!pgn_freq_record_move(map, key, uci, san))
            return PGN_GAME_OOM;

        char label[24];
        format_san_ply_label(&pos, san, label, sizeof(label));
        if (!position_apply_uci(&pos, uci)) {
            warn_move_failure("cannot apply move", san, ply, fen_buf, &pos,
                              hdr, game_num, &history);
            return PGN_GAME_ERROR;
        }
        position_to_fen(&pos, fen_buf, sizeof(fen_buf));
        history_push(&history, label);
        ply++;

        char next_key[FEN_KEY_MAX_LENGTH];
        fen_map_canonicalize_key(fen_buf, next_key, sizeof(next_key));
        if (!pgn_freq_record_reach(map, next_key))
            return PGN_GAME_OOM;

        ply_tracked++;
    }

    return tracking ? PGN_GAME_OK : PGN_GAME_PREFIX_SKIP;
}

static bool read_line(FILE *fp, char *buf, size_t buf_len) {
    if (!fgets(buf, (int)buf_len, fp)) return false;
    return true;
}

static bool line_starts_tag(const char *line) {
    const char *p = skip_whitespace(line);
    return *p == '[';
}

static int load_movetext_from_file(FILE *fp, char *buf, size_t buf_len) {
    size_t len = 0;
    buf[0] = '\0';

    while (!g_interrupted && read_line(fp, buf + len, buf_len - len)) {
        size_t line_len = strlen(buf + len);
        if (line_len == 0) continue;

        if (len == 0 && line_starts_tag(buf)) {
            /* Caller should have consumed headers; treat as empty game. */
            fseek(fp, -(long)line_len, SEEK_CUR);
            break;
        }

        if (len > 0 && line_starts_tag(buf + len)) {
            fseek(fp, -(long)line_len, SEEK_CUR);
            break;
        }

        len += line_len;
        if (len + 1 >= buf_len) {
            fprintf(stderr,
                    "Warning: movetext exceeds %zu bytes — skipping rest of game\n",
                    buf_len);
            skip_rest_of_game(fp);
            break;
        }
    }

    return (int)(len > 0);
}

static int pgn_freq_load_stream(PgnFreqMap *map, const PgnFreqConfig *cfg,
                                FILE *fp) {
    char line[4096];
    char movetext[PGN_MOVETEXT_BUF_SIZE];
    char prefix[PGN_MAX_PREFIX_MOVES][16];
    int prefix_len = parse_prefix_moves(cfg ? cfg->start_moves : NULL, prefix);
    int games_parsed = 0;
    int prefix_skipped = 0;
    int game_num = 0;
    PgnGameHeaders hdr;

    while (!feof(fp) && !g_interrupted) {
        /* Skip blank lines between games. */
        long pos = ftell(fp);
        if (!read_line(fp, line, sizeof(line))) break;
        if (line[0] == '\0' || line[0] == '\n' ||
            line[strspn(line, " \t\r\n")] == '\0') {
            continue;
        }

        pgn_headers_clear(&hdr);
        bool has_movetext = false;

        if (line_starts_tag(line)) {
            game_num++;
            parse_tag_line(line, &hdr);
            while (read_line(fp, line, sizeof(line)) && line_starts_tag(line)) {
                if (g_interrupted) goto done;
                parse_tag_line(line, &hdr);
            }
            if (g_interrupted) goto done;

            if (line[0] != '\0' && line[0] != '\n' &&
                line[strspn(line, " \t\r\n")] != '\0') {
                snprintf(movetext, sizeof(movetext), "%s", line);
                has_movetext = load_movetext_from_file(
                    fp, movetext + strlen(movetext),
                    sizeof(movetext) - strlen(movetext)) != 0;
            } else {
                has_movetext =
                    load_movetext_from_file(fp, movetext, sizeof(movetext)) != 0;
            }
        } else {
            game_num++;
            fseek(fp, pos, SEEK_SET);
            has_movetext =
                load_movetext_from_file(fp, movetext, sizeof(movetext)) != 0;
        }

        if (!has_movetext) {
            if (feof(fp)) break;
            continue;
        }

        int game_result = process_game_movetext(map, cfg, movetext, prefix,
                                                prefix_len, &hdr, game_num);
        if (game_result == PGN_GAME_OK) {
            games_parsed++;
            map->total_games++;
        } else if (game_result == PGN_GAME_PREFIX_SKIP) {
            prefix_skipped++;
        } else if (game_result == PGN_GAME_OOM) {
            fprintf(stderr,
                    "Error: out of memory while parsing PGN — aborting\n");
            break;
        }
    }

done:
    if (prefix_skipped > 0 && prefix_len > 0) {
        fprintf(stderr,
                "  %d games skipped (did not match --moves prefix)\n",
                prefix_skipped);
    }
    return games_parsed;
}

PgnFreqMap *pgn_freq_map_create(void) {
    PgnFreqMap *map = (PgnFreqMap *)calloc(1, sizeof(PgnFreqMap));
    if (!map) return NULL;
    map->num_buckets = PGN_FREQ_INITIAL_BUCKETS;
    map->buckets = (PgnFreqEntry **)calloc(map->num_buckets, sizeof(PgnFreqEntry *));
    if (!map->buckets) {
        free(map);
        return NULL;
    }
    return map;
}

void pgn_freq_map_destroy(PgnFreqMap *map) {
    if (!map) return;
    for (size_t i = 0; i < map->num_buckets; i++) {
        PgnFreqEntry *e = map->buckets[i];
        while (e) {
            PgnFreqEntry *next = e->next;
            pgn_freq_position_free(&e->pos);
            free(e);
            e = next;
        }
    }
    free(map->buckets);
    free(map);
}

int pgn_freq_load_file(PgnFreqMap *map, const PgnFreqConfig *cfg,
                       const char *path) {
    if (!map || !path) return 0;

    FILE *fp = fopen(path, "r");
    if (!fp) {
        fprintf(stderr, "Error: cannot open PGN file '%s'\n", path);
        return 0;
    }

    int games = pgn_freq_load_stream(map, cfg, fp);
    fclose(fp);
    return games;
}

const PgnFreqPosition *pgn_freq_get(const PgnFreqMap *map, const char *fen) {
    if (!map || !fen) return NULL;
    char key[FEN_KEY_MAX_LENGTH];
    fen_map_canonicalize_key(fen, key, sizeof(key));
    PgnFreqEntry *e = pgn_freq_find_entry(map, key);
    return e ? &e->pos : NULL;
}

void pgn_freq_stats(const PgnFreqMap *map, size_t *out_positions,
                    uint64_t *out_total_games) {
    if (out_positions) *out_positions = map ? map->count : 0;
    if (out_total_games) *out_total_games = map ? map->total_games : 0;
}

int pgn_freq_filtered_moves(const PgnFreqPosition *pos, int min_games,
                            double min_prob, PgnFreqMove *out_moves,
                            int max_out) {
    if (!pos || !out_moves || max_out <= 0) return 0;

    uint64_t total = 0;
    for (int i = 0; i < pos->move_count; i++)
        total += pos->moves[i].count;
    if (total == 0) return 0;

    int n = 0;
    for (int i = 0; i < pos->move_count && n < max_out; i++) {
        const PgnFreqMove *m = &pos->moves[i];
        if ((int64_t)m->count < min_games) continue;
        double prob = (double)m->count / (double)total;
        if (prob < min_prob) continue;
        out_moves[n++] = *m;
    }
    return n;
}

static bool pgn_freq_merge_move(PgnFreqPosition *dst, const PgnFreqMove *src) {
    for (int i = 0; i < dst->move_count; i++) {
        if (strcmp(dst->moves[i].uci, src->uci) == 0) {
            dst->moves[i].count += src->count;
            return true;
        }
    }

    if (dst->move_count >= dst->move_capacity) {
        int new_cap = dst->move_capacity ? dst->move_capacity * 2 : PGN_FREQ_INITIAL_MOVES;
        PgnFreqMove *nm = (PgnFreqMove *)realloc(dst->moves,
                                                 (size_t)new_cap * sizeof(PgnFreqMove));
        if (!nm) return false;
        dst->moves = nm;
        dst->move_capacity = new_cap;
    }

    PgnFreqMove *m = &dst->moves[dst->move_count++];
    *m = *src;
    return true;
}

bool pgn_freq_map_merge(PgnFreqMap *dst, const PgnFreqMap *src) {
    if (!dst || !src) return false;

    dst->total_games += src->total_games;

    for (size_t bi = 0; bi < src->num_buckets; bi++) {
        for (PgnFreqEntry *e = src->buckets[bi]; e; e = e->next) {
            const PgnFreqPosition *sp = &e->pos;
            PgnFreqPosition *dp = pgn_freq_get_or_create(dst, sp->fen_key);
            if (!dp) return false;
            dp->reach_count += sp->reach_count;

            for (int mi = 0; mi < sp->move_count; mi++) {
                if (!pgn_freq_merge_move(dp, &sp->moves[mi]))
                    return false;
            }
        }
    }
    return true;
}

static bool fread_exact(void *buf, size_t size, FILE *fp) {
    return fread(buf, size, 1, fp) == 1;
}

static bool fwrite_exact(const void *buf, size_t size, FILE *fp) {
    return fwrite(buf, size, 1, fp) == 1;
}

bool pgn_freq_map_save(const PgnFreqMap *map, const char *path,
                       const char *manifest_json) {
    if (!map || !path || !manifest_json) return false;

    size_t manifest_len = strlen(manifest_json);
    if (manifest_len > UINT32_MAX) return false;

    FILE *fp = fopen(path, "wb");
    if (!fp) {
        fprintf(stderr, "Error: cannot write frequency cache '%s': %s\n",
                path, strerror(errno));
        return false;
    }

    bool ok = true;
    uint32_t version = PGN_FREQ_CACHE_FILE_VERSION;
    uint64_t position_count = map->count;
    uint64_t total_games = map->total_games;
    uint32_t mlen = (uint32_t)manifest_len;

    ok = ok && fwrite_exact(PGN_FREQ_MAGIC_BYTES, 8, fp);
    ok = ok && fwrite_exact(&version, sizeof(version), fp);
    ok = ok && fwrite_exact(&position_count, sizeof(position_count), fp);
    ok = ok && fwrite_exact(&total_games, sizeof(total_games), fp);
    ok = ok && fwrite_exact(&mlen, sizeof(mlen), fp);
    ok = ok && fwrite_exact(manifest_json, manifest_len, fp);

    for (size_t bi = 0; bi < map->num_buckets && ok; bi++) {
        for (PgnFreqEntry *e = map->buckets[bi]; e && ok; e = e->next) {
            const PgnFreqPosition *pos = &e->pos;
            uint32_t move_count = (uint32_t)pos->move_count;

            ok = ok && fwrite_exact(pos->fen_key, 128, fp);
            ok = ok && fwrite_exact(&pos->reach_count, sizeof(pos->reach_count), fp);
            ok = ok && fwrite_exact(&move_count, sizeof(move_count), fp);

            for (int mi = 0; mi < pos->move_count && ok; mi++) {
                const PgnFreqMove *m = &pos->moves[mi];
                ok = ok && fwrite_exact(m->uci, 8, fp);
                ok = ok && fwrite_exact(m->san, 16, fp);
                ok = ok && fwrite_exact(&m->count, sizeof(m->count), fp);
            }
        }
    }

    if (!ok) {
        fprintf(stderr, "Error: failed writing frequency cache '%s'\n", path);
        fclose(fp);
        unlink(path);
        return false;
    }

    if (fclose(fp) != 0) {
        fprintf(stderr, "Error: fclose failed for '%s': %s\n",
                path, strerror(errno));
        unlink(path);
        return false;
    }
    return true;
}

PgnFreqMap *pgn_freq_map_load(const char *path, const char *expected_manifest_json) {
    if (!path || !expected_manifest_json) return NULL;
    if (access(path, R_OK) != 0) return NULL;

    FILE *fp = fopen(path, "rb");
    if (!fp) return NULL;

    char magic[8];
    uint32_t version = 0;
    uint64_t position_count = 0;
    uint64_t total_games = 0;
    uint32_t manifest_len = 0;

    if (!fread_exact(magic, sizeof(magic), fp) ||
        memcmp(magic, PGN_FREQ_MAGIC_BYTES, 8) != 0) {
        fclose(fp);
        return NULL;
    }
    if (!fread_exact(&version, sizeof(version), fp) ||
        version != PGN_FREQ_CACHE_FILE_VERSION) {
        fclose(fp);
        return NULL;
    }
    if (!fread_exact(&position_count, sizeof(position_count), fp) ||
        !fread_exact(&total_games, sizeof(total_games), fp) ||
        !fread_exact(&manifest_len, sizeof(manifest_len), fp)) {
        fclose(fp);
        return NULL;
    }

    char *manifest = (char *)malloc((size_t)manifest_len + 1);
    if (!manifest) {
        fclose(fp);
        return NULL;
    }
    if (manifest_len > 0 && !fread_exact(manifest, manifest_len, fp)) {
        free(manifest);
        fclose(fp);
        return NULL;
    }
    manifest[manifest_len] = '\0';

    if (strcmp(manifest, expected_manifest_json) != 0) {
        free(manifest);
        fclose(fp);
        return NULL;
    }
    free(manifest);

    PgnFreqMap *map = pgn_freq_map_create();
    if (!map) {
        fclose(fp);
        return NULL;
    }
    map->total_games = total_games;

    for (uint64_t pi = 0; pi < position_count; pi++) {
        char fen_key[128];
        uint64_t reach_count = 0;
        uint32_t move_count = 0;

        if (!fread_exact(fen_key, sizeof(fen_key), fp) ||
            !fread_exact(&reach_count, sizeof(reach_count), fp) ||
            !fread_exact(&move_count, sizeof(move_count), fp)) {
            pgn_freq_map_destroy(map);
            fclose(fp);
            return NULL;
        }
        fen_key[sizeof(fen_key) - 1] = '\0';

        PgnFreqPosition *pos = pgn_freq_get_or_create(map, fen_key);
        if (!pos) {
            pgn_freq_map_destroy(map);
            fclose(fp);
            return NULL;
        }
        pos->reach_count = reach_count;

        for (uint32_t mi = 0; mi < move_count; mi++) {
            PgnFreqMove m;
            memset(&m, 0, sizeof(m));
            if (!fread_exact(m.uci, 8, fp) ||
                !fread_exact(m.san, 16, fp) ||
                !fread_exact(&m.count, sizeof(m.count), fp)) {
                pgn_freq_map_destroy(map);
                fclose(fp);
                return NULL;
            }
            m.uci[sizeof(m.uci) - 1] = '\0';
            m.san[sizeof(m.san) - 1] = '\0';
            if (!pgn_freq_merge_move(pos, &m)) {
                pgn_freq_map_destroy(map);
                fclose(fp);
                return NULL;
            }
        }
    }

    if (map->count != position_count) {
        pgn_freq_map_destroy(map);
        fclose(fp);
        return NULL;
    }

    fclose(fp);
    return map;
}
