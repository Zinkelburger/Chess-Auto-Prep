// Reads a Scid database with Scid's own codec and prints it as PGN.
// Build tool only: this is how a Dart-written database is proved readable.
#include "scidbase.h"
#include <cstdio>
#include <string>

int main(int argc, char** argv) {
    if (argc < 3) { std::fprintf(stderr, "usage: dumpdb SCID4|SCID5 base\n"); return 2; }
    scidBaseT base;
    if (auto err = base.open(argv[1], FMODE_ReadOnly, argv[2])) {
        std::fprintf(stderr, "open failed: %d\n", err);
        return 1;
    }
    std::fprintf(stderr, "games=%u\n", base.numGames());
    for (gamenumT i = 0; i < base.numGames(); i++) {
        const IndexEntry* ie = base.getIndexEntry(i);
        Game g;
        if (auto err = base.getGame(*ie, g)) {
            std::fprintf(stderr, "game %u decode error %d\n", i, err);
            return 1;
        }
        g.SetPgnFormat(PGN_FORMAT_Plain);
        auto [text, len] = g.WriteToPGN(0, true);
        std::fwrite(text, 1, len, stdout);
        std::fputc('\n', stdout);
    }
    base.Close();
    return 0;
}
