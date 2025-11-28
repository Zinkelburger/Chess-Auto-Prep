import asyncio
import math
import chess
import chess.engine
import time
from maia2 import model, inference

LC0_PATH = "/var/home/bigman/Documents/CodingProjects/lc0/build/release/lc0"
LC0_NETWORK = "/var/home/bigman/Downloads/11258-112x9-se.pb.gz"
MAIA_DEVICE = "cpu"

# --- FORMULA PARAMETERS ---
ALPHA = 1/3
BETA = 1.5

class EaseCalculator:
    def __init__(self):
        print("Loading Maia2...")
        self.maia_model = model.from_pretrained(type="rapid", device=MAIA_DEVICE)
        self.maia_prepared = inference.prepare()
        print("Maia2 Loaded.")
        self.engine = None # We will hold the Lc0 process here

    async def start_engine(self):
        """Starts Lc0 once and keeps it running."""
        if self.engine is None:
            # print("Starting Lc0...")
            transport, self.engine = await chess.engine.popen_uci(LC0_PATH)

            await self.engine.configure({
                "Backend": "opencl",        # <--- Switch to CPU backend
                "WeightsFile": LC0_NETWORK,
                "Threads": 2,              # Use 8 CPU threads (give it some power)
                "MinibatchSize": 32,        # CPU prefers batch size 1 usually
                "UCI_ShowWDL": True
            })
            # Ping to ensure it's actually ready before we move on
            await self.engine.ping()

    async def stop_engine(self):
        if self.engine:
            await self.engine.quit()
            self.engine = None

    async def get_leela_data(self, board, moves_to_eval):
        results = {}
        max_q = -1.0

        try:
            # 1. Best Move Search (Objective Ceiling)
            print(f"  -> Analyzing best move for position...")
            info_best = await self.engine.analyse(board, chess.engine.Limit(nodes=1000))
            print(f"  -> Best move analysis complete: {info_best}")

            if "wdl" in info_best:
                wdl = info_best["wdl"].pov(chess.WHITE)
                w, d, l = wdl.wins, wdl.draws, wdl.losses
                max_q = (w - l) / (w + d + l)
                print(f"  -> Best move WDL: W={w} D={d} L={l}, Q={max_q:.3f}")
            else:
                print(f"  -> WARNING: No WDL data in best move analysis!")

            # 2. Human Candidate Evaluation
            print(f"  -> Evaluating {len(moves_to_eval)} candidate moves...")
            for i, move in enumerate(moves_to_eval):
                if move not in board.legal_moves:
                    print(f"     Move {move.uci()} not legal, skipping")
                    continue

                print(f"     Analyzing move {i+1}/{len(moves_to_eval)}: {move.uci()}")
                board.push(move)
                info = await self.engine.analyse(board, chess.engine.Limit(nodes=800))
                board.pop()

                print(f"     Analysis result: {info}")

                if "wdl" in info:
                    wdl = info["wdl"].pov(chess.WHITE)
                    w, d, l = wdl.wins, wdl.draws, wdl.losses
                    total = w + d + l
                    q_value = -1 * ((w - l) / total)
                    results[move.uci()] = q_value
                    print(f"     {move.uci()}: WDL=({w},{d},{l}) Q={q_value:.3f}")

                    if q_value > max_q: max_q = q_value
                else:
                    print(f"     WARNING: No WDL data for move {move.uci()}!")

        except Exception as e:
            print(f"  -> ERROR in get_leela_data: {e}")
            import traceback
            traceback.print_exc()

        print(f"  -> LC0 evaluation complete. Found {len(results)} valid evaluations, max_q={max_q}")
        return results, max_q

    async def get_safety_factor(self, board):
        # Quick check of the root position
        info = await self.engine.analyse(board, chess.engine.Limit(nodes=1000))
        if "wdl" in info:
            # Get WDL from the perspective of the side to move
            wdl = info["wdl"].pov(board.turn)
            total = wdl.wins + wdl.draws + wdl.losses

            # 1. Calculate raw "Non-Losing Probability"
            raw_safety = (wdl.wins + wdl.draws) / total

            # 2. Scale it so we don't punish playable positions too hard
            # A lower exponent (0.25) makes the curve flatter at the top
            scaled_safety = math.pow(raw_safety, 0.25)

            print(f"  -> Safety: {raw_safety:.3f} -> Scaled: {scaled_safety:.3f}")
            return scaled_safety
        return 1.0

    # Wrapper to run Maia blocking code
    def _run_maia_blocking(self, board):
        # This function runs inside a thread
        return inference.inference_each(
            self.maia_model, self.maia_prepared, board.fen(), 1800, 1800
        )

    async def calculate_ease(self, fen):
        await self.start_engine()

        board = chess.Board(fen)
        print(f"\n--- Analyzing: {fen} ---")

        # 1. Maia (RUN IN EXECUTOR)
        print("  -> Running Maia inference (this may take a few seconds)...")
        loop = asyncio.get_running_loop()

        # This keeps the loop alive while the CPU crunches numbers
        maia_probs, _ = await loop.run_in_executor(None, self._run_maia_blocking, board)
        print("  -> Maia finished.")

        sorted_moves = sorted(maia_probs.items(), key=lambda x: x[1], reverse=True)

        print("  -> Top Maia moves:")

        candidate_moves = []
        cumulative_prob = 0.0

        # Iterate through the sorted list just once
        for i, (uci_str, prob) in enumerate(sorted_moves):

            # Logic: Print only the top 5 for visual logging
            if i < 5:
                print(f"     {uci_str}: {prob:.3f}")

            # Logic: Filter out absolute noise (moves < 1% chance)
            if prob < 0.01:
                continue

            # Logic: Add to candidates for Leela analysis
            candidate_moves.append(chess.Move.from_uci(uci_str))
            cumulative_prob += prob

            # Logic: Stop adding moves once we account for 90% of human probability
            # (This prevents analyzing 30 different moves that essentially have 0% chance)
            if cumulative_prob > 0.90:
                break

        # 2. Leela Data
        print(f"  -> Querying Lc0 for {len(candidate_moves) + 1} positions...")
        leela_evals, q_max = await self.get_leela_data(board, candidate_moves)
        safety_factor = await self.get_safety_factor(board)

        # 3. Calculate Ease
        sum_weighted_regret = 0.0
        
        print(f"{'Move':<8} | {'Prob':<6} | {'Q-Val':<7} | {'Regret':<7}")
        
        for move_uci, prob in maia_probs.items():
            if move_uci in leela_evals:
                q_val = leela_evals[move_uci]
                regret = max(0.0, q_max - q_val) # Ensure no negative regret
                term = (prob ** BETA) * regret
                sum_weighted_regret += term
                print(f"{move_uci:<8} | {prob:.3f}  | {q_val:.3f}   | {regret:.3f}")

        raw_ease = 1 - math.pow(sum_weighted_regret / 2, ALPHA)

        # 4. Safety Net (Non-Losing Probability with Power Scaling)
        # The safety_factor is already scaled with pow(0.25) to avoid bias
        # against Black pieces and dynamic positions
        final_ease = raw_ease * safety_factor

        print(f"\nRaw Ease (Skill):         {raw_ease:.4f}")
        print(f"Safety Factor:            x {safety_factor:.4f}")
        print(f"FINAL EASE SCORE:         {final_ease:.4f}")
        
        return final_ease

# --- EXAMPLE USAGE ---
async def main():
    calc = EaseCalculator()
    
    # Sharp KID
    fen1 = "r1b2rk1/pp2npbp/2npp1p1/q7/2PPP3/P1N1BN2/1P3PPP/R2QKB1R w KQ - 3 10"
    # Safe French Exchange
    fen2 = "rnbqk2r/ppp2ppp/4pn2/3p4/3P4/2N2N2/PPP1PPPP/R2QKB1R w KQkq - 2 5"
    
    await calc.calculate_ease(fen1)
    await calc.calculate_ease(fen2)
    
    await calc.stop_engine()

if __name__ == "__main__":
    asyncio.run(main())