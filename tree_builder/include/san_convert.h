#ifndef SAN_CONVERT_H
#define SAN_CONVERT_H

#include <stdbool.h>
#include <stddef.h>

/**
 * Convert a UCI move to SAN notation.
 *
 * Uses chesslib's legal move generator for correct disambiguation
 * (handles pins, etc.) and appends +/# check/checkmate suffixes.
 *
 * @param fen      FEN of the position before the move
 * @param uci      UCI move string (e.g. "e2e4", "e7e8q", "e1g1")
 * @param san      Output buffer for SAN string
 * @param san_len  Size of output buffer (must be >= 12)
 * @return true on success
 */
bool uci_to_san(const char *fen, const char *uci, char *san, size_t san_len);

/**
 * Convert a SAN move to UCI notation.
 *
 * Generates all legal moves, converts each to SAN, and matches.
 * Handles move number prefixes (e.g. "1." or "1...") by stripping them.
 *
 * @param fen      FEN of the position before the move
 * @param san      SAN move string (e.g. "e4", "Nf3", "O-O", "exd5")
 * @param uci      Output buffer for UCI string
 * @param uci_len  Size of output buffer (must be >= 8)
 * @return true on success
 */
bool san_to_uci(const char *fen, const char *san, char *uci, size_t uci_len);

#endif /* SAN_CONVERT_H */
