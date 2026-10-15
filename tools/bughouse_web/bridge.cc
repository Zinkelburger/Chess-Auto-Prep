#include "environment/board.h"
#include "environment/planes.h"
#include "common/globals.h"
#include "search/searchthread.h"
#include "Fairy-Stockfish/src/piece.h"
#include "Fairy-Stockfish/src/bitboard.h"
#include <emscripten.h>
#include <algorithm>
#include <cctype>
#include <numeric>
#include <stdexcept>

using namespace Stockfish;
namespace {
std::string result;
const std::string start = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1";
std::string quote(const std::string& s) {
    std::string out = "\"";
    for (unsigned char c : s) {
        if (c == '\\' || c == '"') out += '\\';
        if (c >= 32) out += c;
    }
    return out + '"';
}
std::string colour(Color c) { return c == WHITE ? "white" : "black"; }
std::string move_san(Board& board, int which, Move move) {
    if (move == MOVE_NONE) return "sit";
    return SAN::move_to_san(*board.pos[which], move, NOTATION_SAN);
}
std::string move_uci(Board& board, int which, Move move) {
    return move == MOVE_NONE ? "pass" : UCI::move(*board.pos[which], move);
}

// Position::set assumes valid chess input. Validate structure before entering
// it, including kings/back ranks and castling rooks, to keep malformed pasted
// FEN from reaching native array indexing assumptions.
int validate_fen(const std::string& fen) {
    if (fen.size() > 512) throw std::runtime_error("FEN is too long.");
    std::istringstream in(fen);
    std::string placement, turn, castles, ep, half, full, extra;
    if (!(in >> placement >> turn >> castles >> ep >> half >> full) || in >> extra)
        throw std::runtime_error("Each FEN needs six fields.");
    if (turn != "w" && turn != "b") throw std::runtime_error("Invalid side to move.");
    for (const auto& number : {half, full}) {
        if (number.empty() || number.size() > 5 || number.find_first_not_of("0123456789") != std::string::npos)
            throw std::runtime_error("Invalid FEN move counters.");
    }
    if (std::stoi(full) == 0) throw std::runtime_error("Move number starts at one.");
    const auto bracket = placement.find('[');
    std::string pocket;
    if (bracket != std::string::npos) {
        if (placement.back() != ']') throw std::runtime_error("Unclosed reserve in FEN.");
        pocket = placement.substr(bracket + 1, placement.size() - bracket - 2);
        placement.resize(bracket);
    }
    if (pocket.find_first_not_of("PNBRQpnbrq") != std::string::npos)
        throw std::runtime_error("Invalid reserve piece. Kings cannot be dropped.");
    int rank = 7, file = 0, kings[2] = {0, 0}, material = static_cast<int>(pocket.size());
    std::array<char, 64> squares{};
    char previous = 0;
    for (char c : placement) {
        if (c == '~') {
            if (std::string("NBRQnbrq").find(previous) == std::string::npos)
                throw std::runtime_error("Invalid promoted-piece marker.");
            previous = 0;
            continue;
        }
        if (c == '/') {
            if (file != 8 || --rank < 0) throw std::runtime_error("FEN needs eight ranks of eight squares.");
            file = 0;
        } else if (c >= '1' && c <= '8') file += c - '0';
        else {
            if (file >= 8 || rank < 0 || std::string("PNBRQKpnbrqk").find(c) == std::string::npos)
                throw std::runtime_error("Invalid FEN piece placement.");
            if ((c == 'P' || c == 'p') && (rank == 0 || rank == 7))
                throw std::runtime_error("Pawns cannot occupy the first or eighth rank.");
            squares[rank * 8 + file++] = c;
            kings[0] += c == 'K'; kings[1] += c == 'k'; material++;
        }
        if (file > 8) throw std::runtime_error("Too many squares in a rank.");
        previous = c;
    }
    if (rank != 0 || file != 8 || kings[0] != 1 || kings[1] != 1)
        throw std::runtime_error("Each board needs eight ranks and one king per colour.");
    if (castles != "-") {
        std::string seen;
        for (char c : castles) {
            if (std::string("KQkq").find(c) == std::string::npos || seen.find(c) != std::string::npos)
                throw std::runtime_error("Invalid castling rights.");
            seen += c;
            bool white = std::isupper(c);
            int row = white ? 0 : 56;
            if (squares[row + 4] != (white ? 'K' : 'k')
                || squares[row + (std::tolower(c) == 'k' ? 7 : 0)] != (white ? 'R' : 'r'))
                throw std::runtime_error("Castling rights require the king and rook on their starting squares.");
        }
    }
    if (ep != "-" && (ep.size() != 2 || ep[0] < 'a' || ep[0] > 'h'
        || ep[1] != (turn == "w" ? '6' : '3')))
        throw std::runtime_error("Invalid en passant square.");
    if (ep != "-") {
        const int target = (ep[1] - '1') * 8 + ep[0] - 'a';
        const int step = turn == "w" ? -8 : 8;
        if (squares[target] || squares[target - step]
            || squares[target + step] != (turn == "w" ? 'p' : 'P'))
            throw std::runtime_error("En passant requires a pawn that just advanced two squares.");
    }
    return material;
}

std::unique_ptr<Board> load_board(std::string fen) {
    if (fen.empty()) fen = start + "|" + start;
    const auto separator = fen.find('|');
    if (separator == std::string::npos) fen += "|" + start;
    const auto split = fen.find('|');
    const int material = validate_fen(fen.substr(0, split)) + validate_fen(fen.substr(split + 1));
    if (material > 64) throw std::runtime_error("Two boards cannot contain more than 64 pieces.");
    auto board = std::make_unique<Board>();
    board->set(fen);
    for (int i = 0; i < 2; i++) {
        const auto& p = *board->pos[i];
        if (p.attackers_to(p.square<KING>(~p.side_to_move())) & p.pieces(p.side_to_move()))
            throw std::runtime_error("The side that just moved cannot leave its king in check.");
    }
    return board;
}

std::string joint_json(Board& board, const JointActionCandidate& action) {
    return "{\"A\":" + quote(move_san(board, 0, action.moveA))
        + ",\"B\":" + quote(move_san(board, 1, action.moveB))
        + ",\"uci\":" + quote("(" + move_uci(board, 0, action.moveA) + "," + move_uci(board, 1, action.moveB) + ")") + "}";
}
}

EM_JS(int, cancelled, (), { return Module.cancelled ? 1 : 0; });
EM_JS(void, frozen_report, (const char* json), { Module.onFrozenReport?.(UTF8ToString(json)); });

namespace {
// Principal variation in the native UCI "pv" text format: joint actions
// "(moveA,moveB)" with "pass" for a sitting board. Mirrors native
// Agent::extract_pv_from_child: the first step is the reported best root
// child, then each expanded node follows get_best_move_idx_with_q_weight
// (solver-aware, Q veto/weight), falling back to its most-visited child.
std::string pv_json(const Board& start_board, const std::shared_ptr<Node>& root, int best,
                    const SearchParams::RuntimeConfig& config, int max_depth) {
    std::string out = "[";
    if (best < 0 || !root->is_expanded()) return out + "]";
    Board board(start_board);
    std::shared_ptr<Node> node = root;
    int index = best;
    for (int depth = 0; depth < max_depth; depth++) {
        if (depth > 0) {
            if (!node || !node->is_expanded()) break;
            auto children = node->get_children();
            auto visits = node->get_child_visits();
            if (children.empty() || visits.empty()) break;
            index = node->get_best_move_idx_with_q_weight(config.qVetoDelta, config.qValueWeight);
            if (index < 0) {
                index = 0;
                int most = 0;
                for (size_t i = 0; i < children.size() && i < visits.size(); i++)
                    if (visits[i] > most) { most = visits[i]; index = static_cast<int>(i); }
            }
        }
        const JointActionCandidate action = node->get_joint_action(index);
        if (depth) out += ',';
        out += quote("(" + move_uci(board, 0, action.moveA) + "," + move_uci(board, 1, action.moveB) + ")");
        board.make_moves(action.moveA, action.moveB);
        node = node->get_child(index);
    }
    return out + "]";
}

// Each board's own moves among the root's expanded joint actions, with that
// board's policy prior and the visits of every joint action containing it,
// most visited first. A sitting board is left out. BughouseDB spends its
// per-move searches on the first few of each board.
std::string board_moves_json(Board& board, const std::shared_ptr<Node>& root,
                             const std::vector<int>& visits) {
    struct Entry { int which; Move move; float prior; int visits; };
    std::vector<Entry> entries;
    for (size_t i = 0; i < visits.size(); i++) {
        const JointActionCandidate action = root->get_joint_action(static_cast<int>(i));
        const Move moves[2] = {action.moveA, action.moveB};
        const float priors[2] = {action.priorA, action.priorB};
        for (int which = 0; which < 2; which++) {
            if (moves[which] == MOVE_NONE) continue;
            auto found = std::find_if(entries.begin(), entries.end(), [&](const Entry& e) {
                return e.which == which && e.move == moves[which];
            });
            if (found == entries.end()) entries.push_back({which, moves[which], priors[which], visits[i]});
            else found->visits += visits[i];
        }
    }
    std::stable_sort(entries.begin(), entries.end(), [](const Entry& a, const Entry& b) {
        return a.visits != b.visits ? a.visits > b.visits : a.prior > b.prior;
    });
    std::string out = "[";
    for (size_t i = 0; i < entries.size(); i++) {
        if (i) out += ',';
        const Entry& e = entries[i];
        out += "{\"board\":" + quote(e.which ? "B" : "A") + ",\"uci\":" + quote(move_uci(board, e.which, e.move))
            + ",\"prior\":" + std::to_string(e.prior) + ",\"visits\":" + std::to_string(e.visits) + "}";
    }
    return out + "]";
}

// One bounded MCTS search. bh_search keeps its exact stopping rule and output;
// bh_search_nodes (detailed) adds a node budget, a root-aware q and a PV.
std::string run_search(const char* fen, int team, int timeAdvantage, int required,
                       int nodeCap, int millis, bool detailed) {
    auto board = load_board(fen);
    Color side = static_cast<Color>(team);
    if (required && (board->side_to_move(required - 1) != (required == 1 ? side : ~side)
        || !board->has_any_legal_move(required - 1)))
        throw std::runtime_error("Our team cannot move on the required board.");
    if (!((board->side_to_move(0) == side && board->has_any_legal_move(0))
        || (board->side_to_move(1) == ~side && board->has_any_legal_move(1))))
        throw std::runtime_error("This team has no move available. Choose the other team or update the position.");
    g_requiredMoveBoard = static_cast<RequiredMoveBoard>(required);
    Engine engine(0, 1);
    SearchParams::RuntimeConfig config;
    auto root = std::make_shared<Node>(side);
    root->configure_root_search(config, false);
    SearchInfo info(std::chrono::steady_clock::now(), millis);
    SearchThread search;
    search.set_search_info(&info); search.set_root_node(root); search.set_runtime_config(config);
    // No background native threads or permanent-brain loop in the web build.
    do {
        search.run_iteration(*board, &engine, timeAdvantage);
    } while (!cancelled() && info.nodes < nodeCap && root->get_node_type() == NodeType::UNSOLVED
             && (info.nodes < 2 || info.remaining_time() > 0));
    search.finish_pending_iteration(*board, &engine, timeAdvantage);
    const int best = root->get_best_move_idx_with_q_weight();
    std::vector<int> visits = root->get_child_visits();
    std::vector<int> order(visits.size());
    std::iota(order.begin(), order.end(), 0);
    std::sort(order.begin(), order.end(), [&](int a, int b) {
        if (a == best || b == best) return a == best && b != best;
        return visits[a] > visits[b];
    });
    auto type = root->get_node_type();
    std::string mate = "null";
    if (type == NodeType::WIN || type == NodeType::LOSS)
        mate = std::to_string((type == NodeType::WIN ? 1 : -1) * std::max(1, root->get_end_in_ply()));
    // q is from the searched team's side (the root node's side). Native UCI
    // "score cp" is 180*tan(1.56*q) where q is the reported best child's edge
    // Q, except that a solved root reports its own proof (win 1, loss -1,
    // draw 0). The detailed search follows that rule exactly.
    float q = best >= 0 ? root->get_child_q(best) : root->Q();
    if (detailed && type != NodeType::UNSOLVED) q = root->Q();
    std::string out = "{\"q\":" + std::to_string(q)
        + ",\"mate\":" + mate + ",\"nodes\":" + std::to_string(info.nodes.load())
        + ",\"elapsed_ms\":" + std::to_string(info.elapsed()) + ",\"best\":"
        + (best < 0 ? "null" : joint_json(*board, root->get_joint_action(best)));
    if (detailed) out += ",\"pv\":" + pv_json(*board, root, best, config, 8);
    out += ",\"lines\":[";
    for (size_t i = 0; i < std::min<size_t>(3, order.size()); i++) {
        if (i) out += ',';
        out += "{\"best\":" + joint_json(*board, root->get_joint_action(order[i])) + '}';
    }
    out += ']';
    if (detailed) out += ",\"moves\":" + board_moves_json(*board, root, visits);
    return out + '}';
}
}

namespace {
// One-board analysis. Board B is the starting position held still behind
// board A (see g_frozenBoardB), with the opponent's colour to move there, so
// our team only ever moves on A. Nobody's sit plane is set: nothing arrives.
struct FrozenScope {
    FrozenScope() { g_frozenBoardB = true; g_frozenValueOffset = 0; g_requiredMoveBoard = REQUIRE_MOVE_NONE; }
    ~FrozenScope() { g_frozenBoardB = false; g_frozenValueOffset = 0; }
};

// Pieces are conserved in bughouse: a piece missing from board A (on the
// board, as a promoted pawn, or in a hand) was captured there and went to the
// capturer's partner. Putting it in that pocket on B lets the network count
// A's material; without it the network barely notices a missing queen.
std::string conserved_pockets(const Position& a) {
    std::string pocket;
    for (Color c : {WHITE, BLACK}) {
        for (PieceType t : {PAWN, KNIGHT, BISHOP, ROOK, QUEEN}) {
            int have = popcount(a.pieces(c, t) & ~a.promotedPieces) + a.count_in_hand(c, t);
            if (t == PAWN) have += popcount(a.pieces(c) & a.promotedPieces);
            const int full = t == PAWN ? 8 : t == QUEEN ? 1 : 2;
            pocket += std::string(std::max(0, full - have), a.piece_to_char()[make_piece(c, t)]);
        }
    }
    return pocket;
}

std::unique_ptr<Board> load_frozen(const std::string& fen, Color& side) {
    if (fen.find('|') != std::string::npos) throw std::runtime_error("Give one board's FEN.");
    if (validate_fen(fen) > 64) throw std::runtime_error("One board cannot hold more than 64 pieces.");
    side = fen.find(" w ") != std::string::npos ? WHITE : BLACK;
    auto board = std::make_unique<Board>();
    board->set(fen + "|" + start);
    std::string backdrop = start;
    backdrop.replace(backdrop.find("[]"), 2, "[" + conserved_pockets(*board->pos[0]) + "]");
    if (side == BLACK) backdrop.replace(backdrop.find(" w "), 3, " b ");
    board->set(fen + "|" + backdrop);
    const auto& p = *board->pos[0];
    if (p.attackers_to(p.square<KING>(~p.side_to_move())) & p.pieces(p.side_to_move()))
        throw std::runtime_error("The side that just moved cannot leave its king in check.");
    return board;
}

// Board A's moves along a line, from a "(a,b)" pv token list.
std::string frozen_line(Board board, std::shared_ptr<Node> node, int index,
                        const SearchParams::RuntimeConfig& config, int maxDepth) {
    std::string out = "[";
    for (int depth = 0; depth < maxDepth && node && index >= 0; depth++) {
        const JointActionCandidate action = node->get_joint_action(index);
        if (action.moveA == MOVE_NONE) break;
        if (depth) out += ',';
        out += quote(move_uci(board, 0, action.moveA));
        board.make_moves(action.moveA, action.moveB);
        node = node->get_child(index);
        if (!node || !node->is_expanded()) break;
        auto visits = node->get_child_visits();
        if (visits.empty()) break;
        index = node->get_best_move_idx_with_q_weight(config.qVetoDelta, config.qValueWeight);
        if (index < 0) index = static_cast<int>(std::max_element(visits.begin(), visits.end()) - visits.begin());
    }
    return out + "]";
}

// Mate distance in plies from the root side for a root child, or "null".
std::string child_mate(const std::shared_ptr<Node>& root, int index) {
    auto child = root->get_child(index);
    if (!child) return "null";
    // The child is from the opponent's side: their loss is our win.
    if (child->get_node_type() == NodeType::LOSS) return std::to_string(child->get_end_in_ply() + 1);
    if (child->get_node_type() == NodeType::WIN) return std::to_string(-(child->get_end_in_ply() + 1));
    return "null";
}

// The network's value from the side to move and from the other side, each
// with no sit plane. Their mean is the shared offset; half their difference
// is the static score from the side to move.
std::array<float, 2> frozen_values(Board& board, Color side, Engine& engine) {
    std::vector<float> input(NB_INPUT_VALUES());
    std::array<float, 2> values{};
    for (int i = 0; i < 2; i++) {
        board_to_planes(board, input.data(), i ? ~side : side, false);
        Engine::HalfInferenceOutputs output;
        if (cancelled() || !engine.enqueueInferenceHalf(input.data())
            || !engine.synchronizeInferenceHalf(output))
            throw std::runtime_error("Static evaluation interrupted.");
        values[i] = output.value[0];
    }
    return values;
}

std::string frozen_json(Board& board, const std::shared_ptr<Node>& root, const SearchInfo& info,
                        const SearchParams::RuntimeConfig& config, int lines, bool done) {
    std::vector<int> visits = root->get_child_visits();
    const int best = root->get_best_move_idx_with_q_weight();
    std::vector<int> order;
    for (size_t i = 0; i < visits.size(); i++) if (visits[i] > 0 || static_cast<int>(i) == best) order.push_back(static_cast<int>(i));
    std::stable_sort(order.begin(), order.end(), [&](int a, int b) {
        if (a == best || b == best) return a == best && b != best;
        return visits[a] > visits[b];
    });
    std::string mate = "null";
    const auto type = root->get_node_type();
    if (type == NodeType::WIN || type == NodeType::LOSS)
        mate = std::to_string((type == NodeType::WIN ? 1 : -1) * std::max(1, root->get_end_in_ply()));
    float q = best >= 0 ? root->get_child_q(best) : root->Q();
    if (type != NodeType::UNSOLVED) q = root->Q();
    std::string out = "{\"q\":" + std::to_string(q) + ",\"mate\":" + mate
        + ",\"nodes\":" + std::to_string(info.nodes.load())
        + ",\"depth\":" + std::to_string(info.get_max_depth())
        + ",\"elapsed_ms\":" + std::to_string(info.elapsed())
        + ",\"offset\":" + std::to_string(g_frozenValueOffset)
        + ",\"done\":" + (done ? "true" : "false") + ",\"lines\":[";
    for (size_t i = 0; i < order.size() && static_cast<int>(i) < lines; i++) {
        const int index = order[i];
        if (i) out += ',';
        out += "{\"q\":" + std::to_string(root->get_child_q(index)) + ",\"mate\":" + child_mate(root, index)
            + ",\"visits\":" + std::to_string(visits[index])
            + ",\"prior\":" + std::to_string(root->get_joint_action(index).priorA)
            + ",\"pv\":" + frozen_line(board, root, index, config, 16) + "}";
    }
    return out + "]}";
}

// The last search asked to keep its tree (the shown position's analysis), so
// a later search of the same position carries on from it instead of starting
// again: infinite analysis after the sit panel's rows, or a position the
// player comes back to.
struct KeptSearch {
    std::string fen;
    std::unique_ptr<Board> board;
    Color side = WHITE;
    std::shared_ptr<Node> root;
    float offset = 0;
    float staticScore = 0;
    int nodes = 0;
    int depth = 0;
};
KeptSearch g_kept;
}

extern "C" {
void bh_init() {
    pieceMap.init(); variants.init(); Bitboards::init(); Position::init();
    Threads.set(1); init_policy_index();
}

const char* bh_position(const char* fen, const char* moves, int team) {
    try {
        auto board = load_board(fen);
        std::array<std::string, 2> movetext;
        std::istringstream tokens(moves);
        std::string token;
        int count = 0;
        while (tokens >> token) {
            if (++count > 256 || token.size() > 20) throw std::runtime_error("Use up to 256 board-tagged SAN or UCI moves.");
            int which = 0;
            if (token.size() > 2 && token[1] == ':') {
                if (token[0] != 'A' && token[0] != 'B') throw std::runtime_error("Tag moves with A: or B:.");
                which = token[0] == 'B'; token = token.substr(2);
            }
            Move chosen = MOVE_NONE;
            for (Move m : board->legal_moves(which)) {
                if (token == move_uci(*board, which, m) || token == move_san(*board, which, m)) { chosen = m; break; }
            }
            if (chosen == MOVE_NONE) throw std::runtime_error("Illegal move on board " + std::string(which ? "B: " : "A: ") + token);
            if (!movetext[which].empty()) movetext[which] += ' ';
            if (board->side_to_move(which) == WHITE)
                movetext[which] += std::to_string(board->pos[which]->game_ply() / 2 + 1) + ". ";
            else if (movetext[which].empty())
                movetext[which] += std::to_string(board->pos[which]->game_ply() / 2 + 1) + "... ";
            movetext[which] += move_san(*board, which, chosen);
            board->push_move(which, chosen);
        }
        result = "{\"dual_fen\":" + quote(board->fen(0) + "|" + board->fen(1)) + ",\"boards\":{";
        for (int i = 0; i < 2; i++) {
            if (i) result += ',';
            auto& p = *board->pos[i];
            result += quote(i ? "B" : "A") + ":{\"fen\":" + quote(board->fen(i))
                + ",\"turn\":" + quote(colour(p.side_to_move()))
                + ",\"we_play\":" + quote(colour(static_cast<Color>(i ? !team : team)))
                + ",\"movetext\":" + quote(movetext[i])
                + ",\"check\":" + (p.checkers() ? "true" : "false") + ",\"pieces\":{";
            bool first = true;
            for (int s = 0; s < 64; s++) {
                Piece piece = p.piece_on(static_cast<Square>(s));
                if (piece == NO_PIECE) continue;
                if (!first) result += ','; first = false;
                std::string square; square += 'a' + s % 8; square += '1' + s / 8;
                result += quote(square) + ':' + quote(std::string(1, p.piece_to_char()[piece]));
            }
            result += "},\"pockets\":{";
            for (Color c : {WHITE, BLACK}) {
                if (c == BLACK) result += ',';
                std::string pocket;
                for (PieceType t : {PAWN, KNIGHT, BISHOP, ROOK, QUEEN})
                    pocket += std::string(p.count_in_hand(c, t), p.piece_to_char()[make_piece(BLACK, t)]);
                result += quote(colour(c)) + ':' + quote(pocket);
            }
            result += "},\"legal_moves\":[";
            first = true;
            for (Move m : board->legal_moves(i)) {
                if (!first) result += ','; first = false;
                result += "{\"uci\":" + quote(move_uci(*board, i, m)) + ",\"san\":" + quote(move_san(*board, i, m)) + '}';
            }
            result += "]}";
        }
        result += "}}";
    } catch (const std::exception& e) { result = "{\"error\":" + quote(e.what()) + '}'; }
    return result.c_str();
}

// Static values remain defined when a team currently has no legal turn.
// Their mean removes the network's shared value offset, as in native policy.
const char* bh_values(const char* fen, int team, int ourAhead, int theirAhead) {
    try {
        auto board = load_board(fen);
        Engine engine(0, 1);
        std::vector<float> input(NB_INPUT_VALUES());
        result = "[";
        for (int i = 0; i < 2; i++) {
            board_to_planes(*board, input.data(), static_cast<Color>(i ? !team : team),
                            i ? theirAhead : ourAhead);
            Engine::HalfInferenceOutputs output;
            if (cancelled() || !engine.enqueueInferenceHalf(input.data())
                || !engine.synchronizeInferenceHalf(output))
                throw std::runtime_error("Static evaluation interrupted.");
            if (i) result += ',';
            result += std::to_string(output.value[0]);
        }
        result += ']';
    } catch (const std::exception& e) { result = "{\"error\":" + quote(e.what()) + '}'; }
    return result.c_str();
}

const char* bh_search(const char* fen, int team, int timeAdvantage, int required, int millis) {
    try { result = run_search(fen, team, timeAdvantage, required, 10000, std::clamp(millis, 250, 30000), false); }
    catch (const std::exception& e) { result = "{\"error\":" + quote(e.what()) + '}'; }
    return result.c_str();
}

// Stops at the node budget (1..100000), the time cap (1..120000 ms), a solved
// root or Stop, whichever comes first. Adds "pv" to bh_search's output.
const char* bh_search_nodes(const char* fen, int team, int timeAdvantage, int required,
                            int nodes, int millisCap) {
    try {
        result = run_search(fen, team, timeAdvantage, required, std::clamp(nodes, 1, 100000),
                            std::clamp(millisCap, 1, 120000), true);
    } catch (const std::exception& e) { result = "{\"error\":" + quote(e.what()) + '}'; }
    return result.c_str();
}
}

extern "C" {
// One board searched with the partner board held still (g_frozenBoardB) for
// the side to move. Stops at the node budget (1..1000000), the time cap
// (1..3600000 ms), a solved root or Stop. Every reportMs it hands the current
// lines to Module.onFrozenReport. q values are from the side to move. `batch`
// (1..64) leaves are evaluated together: one at a time suits a CPU, while a
// GPU needs batches to be fast. With `keep`, the search keeps its tree for
// later and carries on from the kept tree when that was the same position;
// its node count and depth then continue from the kept search, and
// "resumed_nodes" says how many of the nodes were searched before.
const char* bh_frozen_search(const char* fen, int nodes, int millisCap, int lines, int reportMs, int batch, int keep) {
    try {
        FrozenScope frozen;
        SearchParams::RuntimeConfig config;
        // The offset is measured on the value head alone.
        config.enableWdlEval = false;
        Engine engine(0, std::clamp(batch, 1, 64));
        const bool resume = keep && g_kept.root && g_kept.fen == fen;
        KeptSearch run;
        if (resume) run = std::move(g_kept);
        else {
            // A new tree replaces the kept one; free that one first.
            if (keep) g_kept = KeptSearch{};
            run.fen = fen;
            run.board = load_frozen(fen, run.side);
            if (!run.board->has_any_legal_move(0)) throw std::runtime_error("The side to move has no move.");
            // The static values evaluate one position each; the search fills whole batches.
            Engine single(0, 1);
            const auto values = frozen_values(*run.board, run.side, single);
            run.offset = (values[0] + values[1]) / 2;
            run.staticScore = (values[0] - values[1]) / 2;
            run.root = std::make_shared<Node>(run.side);
            run.root->configure_root_search(config, false);
        }
        g_frozenValueOffset = run.offset;
        frozen_report(("{\"static\":" + std::to_string(run.staticScore) + "}").c_str());
        Board& board = *run.board;
        const auto& root = run.root;
        SearchInfo info(std::chrono::steady_clock::now(), std::clamp(millisCap, 1, 3600000));
        info.nodes.store(run.nodes);
        info.maxDepth.store(run.depth);
        SearchThread search;
        search.set_search_info(&info); search.set_root_node(root); search.set_runtime_config(config);
        const int cap = std::clamp(nodes, 1, 1000000);
        lines = std::clamp(lines, 1, 5);
        double lastReport = 0;
        const auto json = [&](bool done) {
            std::string out = frozen_json(board, root, info, config, lines, done);
            out.insert(out.size() - 1, ",\"resumed_nodes\":" + std::to_string(run.nodes));
            return out;
        };
        // A kept tree that is already solved or past the cap answers at once.
        if (!resume || (info.nodes < cap && root->get_node_type() == NodeType::UNSOLVED)) {
            do {
                search.run_iteration(board, &engine, false);
                if (reportMs > 0 && info.elapsed() - lastReport >= reportMs && root->is_expanded()) {
                    lastReport = info.elapsed();
                    frozen_report(json(false).c_str());
                }
            } while (!cancelled() && info.nodes < cap && root->get_node_type() == NodeType::UNSOLVED
                     && (info.nodes < 2 || info.remaining_time() > 0));
            search.finish_pending_iteration(board, &engine, false);
        }
        result = json(true);
        if (keep) {
            run.nodes = info.nodes.load();
            run.depth = info.get_max_depth();
            g_kept = std::move(run);
        }
    } catch (const std::exception& e) { result = "{\"error\":" + quote(e.what()) + '}'; }
    return result.c_str();
}

}
