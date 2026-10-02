// Direct mate-budget probe. Link against the pinned Hivemind static library.
// stdin: id<TAB>A|B<TAB>dual FEN. No network inference or application writes.
#include "environment/board.h"
#include "environment/constants.h"
#include "environment/joint_action.h"
#include "search/agent.h"
#include "common/globals.h"
#include "Fairy-Stockfish/src/bitboard.h"
#include "Fairy-Stockfish/src/piece.h"
#include "Fairy-Stockfish/src/position.h"
#include "Fairy-Stockfish/src/thread.h"
#include <chrono>
#include <iostream>
#include <sstream>
#include <string>

int main() {
    Stockfish::pieceMap.init();
    Stockfish::variants.init();
    Stockfish::Bitboards::init();
    Stockfish::Position::init();
    Stockfish::Threads.set(1);
    init_policy_index();
    std::string input;
    while (std::getline(std::cin, input)) {
        std::istringstream line(input);
        std::string id, selected, fen;
        std::getline(line, id, '\t');
        std::getline(line, selected, '\t');
        std::getline(line, fen);
        if (fen.empty()) return 2;
        const int which = selected == "A" ? BOARD_A : BOARD_B;
        g_requiredMoveBoard = selected == "A" ? REQUIRE_MOVE_BOARD_A : REQUIRE_MOVE_BOARD_B;
        for (const auto budget : {100, 300, 1000, 2000, 3000, 8000, 10000, 30000, 100000, 300000}) {
            for (int repeat = 0; repeat < 3; ++repeat) {
                Board board;
                board.set(fen);
                const auto beforeA = board.fen(BOARD_A), beforeB = board.fen(BOARD_B);
                const auto team = which == BOARD_A ? board.side_to_move(which) : ~board.side_to_move(which);
                JointActionCandidate action;
                int plies = 0;
                const auto start = std::chrono::steady_clock::now();
                const auto deadline = start + std::chrono::seconds(10);
                const bool found = Agent::find_root_mate(board, team, false, action, plies, budget, deadline);
                const auto end = std::chrono::steady_clock::now();
                const bool restored = beforeA == board.fen(BOARD_A) && beforeB == board.fen(BOARD_B);
                const bool selectedLegal = !found || board.is_legal_move(
                    which, which == BOARD_A ? action.moveA : action.moveB);
                std::cout << "{\"id\":\"" << id << "\",\"budget\":" << budget
                    << ",\"repeat\":" << repeat << ",\"found\":" << (found ? "true" : "false")
                    << ",\"seconds\":" << std::chrono::duration<double>(end-start).count()
                    << ",\"timed_out\":" << (end >= deadline ? "true" : "false")
                    << ",\"restored\":" << (restored ? "true" : "false")
                    << ",\"selected_legal\":" << (selectedLegal ? "true" : "false")
                    << ",\"plies\":" << plies << ",\"move_a\":\""
                    << (found ? board.uci_move(BOARD_A, action.moveA) : "") << "\",\"move_b\":\""
                    << (found ? board.uci_move(BOARD_B, action.moveB) : "") << "\"}" << std::endl;
                if (!restored) return 3;
            }
        }
    }
    Stockfish::Threads.set(0);
}
