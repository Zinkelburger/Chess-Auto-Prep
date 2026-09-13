#include "environment/board.h"
#include "common/globals.h"
#include "search/searchthread.h"
#include "Fairy-Stockfish/src/piece.h"
#include "Fairy-Stockfish/src/bitboard.h"
#include <emscripten.h>
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

const char* bh_search(const char* fen, int team, int timeAdvantage, int required, int millis) {
    try {
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
        SearchInfo info(std::chrono::steady_clock::now(), std::clamp(millis, 250, 30000));
        SearchThread search;
        search.set_search_info(&info); search.set_root_node(root); search.set_runtime_config(config);
        // No background native threads or permanent-brain loop in the web build.
        do {
            search.run_iteration(*board, &engine, timeAdvantage);
        } while (!cancelled() && info.nodes < 10000 && root->get_node_type() == NodeType::UNSOLVED
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
        result = "{\"q\":" + std::to_string(best >= 0 ? root->get_child_q(best) : root->Q())
            + ",\"mate\":" + mate + ",\"nodes\":" + std::to_string(info.nodes.load())
            + ",\"elapsed_ms\":" + std::to_string(info.elapsed()) + ",\"best\":"
            + (best < 0 ? "null" : joint_json(*board, root->get_joint_action(best))) + ",\"lines\":[";
        for (size_t i = 0; i < std::min<size_t>(3, order.size()); i++) {
            if (i) result += ',';
            result += "{\"best\":" + joint_json(*board, root->get_joint_action(order[i])) + '}';
        }
        result += "]}";
    } catch (const std::exception& e) { result = "{\"error\":" + quote(e.what()) + '}'; }
    return result.c_str();
}
}
