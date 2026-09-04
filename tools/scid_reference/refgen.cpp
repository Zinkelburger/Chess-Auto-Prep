// Reference generator: PGN -> SCID4/SCID5, using Scid's own codec.
// Build tool only; never shipped. Used to produce ground-truth files that the
// Dart writer is diffed against.
#include "scidbase.h"
#include <cstdio>
#include <string>

int main(int argc, char** argv) {
    if (argc < 4) {
        std::fprintf(stderr, "usage: refgen SCID4|SCID5 out.pgn outbase\n");
        return 2;
    }
    const std::string dbType = argv[1];
    const char* pgn = argv[2];
    const char* out = argv[3];

    scidBaseT base;
    if (auto err = base.open(dbType, FMODE_Create, out)) {
        std::fprintf(stderr, "open failed: %d\n", err);
        return 1;
    }
    std::string errorMsg;
    auto err = base.importGames(ICodecDatabase::PGN, pgn, Progress(), errorMsg);
    if (err) {
        std::fprintf(stderr, "import failed: %d %s\n", err, errorMsg.c_str());
        base.Close();
        return 1;
    }
    std::printf("games=%u\n", base.numGames());
    base.Close();
    return 0;
}
