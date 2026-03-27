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

#endif /* SAN_CONVERT_H */
