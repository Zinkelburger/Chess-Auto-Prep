import asyncio
import math
import chess
import chess.engine
# import torch # Not strictly needed unless you modify maia internals
from maia2 import model, inference

# --- CONFIGURATION ---
LC0_PATH = "/var/home/bigman/Documents/CodingProjects/lc0/build/release/lc0"
LC0_NETWORK = "/var/home/bigman/Documents/CodingProjects/lc0/build/release/lc0/t3-512x15x16h-distill-swa-2767500.pb.gz"
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
            await self.engine.configure({"Backend": "opencl", "WeightsFile": LC0_NETWORK})

    async def stop_engine(self):
        if self.engine:
            await self.engine.quit()
            self.engine = None

    async def get_leela_data(self, board, moves_to_eval):
        results = {}
        max_q = -1.0
        
        # 1. Best Move Search (Objective Ceiling)
        info_best = await self.engine.analyse(board, chess.engine.Limit(nodes=1000))
        if "wdl" in info_best:
            w, d, l = info_best["wdl"].wins, info_best["wdl"].draws, info_best["wdl"].losses
            max_q = (w - l) / (w + d + l)

        # 2. Human Candidate Evaluation
        for move in moves_to_eval:
            if move not in board.legal_moves: continue

            board.push(move)
            # Flip perspective for the opponent's reply
            info = await self.engine.analyse(board, chess.engine.Limit(nodes=800))
            board.pop()

            if "wdl" in info:
                w, d, l = info["wdl"].wins, info["wdl"].draws, info["wdl"].losses
                total = w + d + l
                # Invert score because it's opponent's view
                q_value = -1 * ((w - l) / total)
                results[move.uci()] = q_value
                
                if q_value > max_q: max_q = q_value

        return results, max_q

    async def get_safety_factor(self, board):
        # Quick check of the root position for Draw %
        info = await self.engine.analyse(board, chess.engine.Limit(nodes=1000))
        if "wdl" in info:
            w, d, l = info["wdl"].wins, info["wdl"].draws, info["wdl"].losses
            return d / (w + d + l)
        return 0.5 # Default if fail

    def get_maia_probs(self, board):
        move_probs, _ = inference.inference_each(
            self.maia_model, self.maia_prepared, board.fen(), 1800, 1800
        )
        return move_probs

    async def calculate_ease(self, fen):
        # Ensure engine is running
        await self.start_engine()
        
        board = chess.Board(fen)
        print(f"\n--- Analyzing: {fen} ---")
        
        # 1. Maia
        maia_probs = self.get_maia_probs(board)
        sorted_moves = sorted(maia_probs.items(), key=lambda x: x[1], reverse=True)
        
        candidate_moves = []
        cumulative_prob = 0
        for uci_str, prob in sorted_moves:
            if prob < 0.01: continue 
            candidate_moves.append(chess.Move.from_uci(uci_str))
            cumulative_prob += prob
            if cumulative_prob > 0.90: break
        
        # 2. Leela Data
        leela_evals, q_max = await self.get_leela_data(board, candidate_moves)
        draw_prob = await self.get_safety_factor(board)

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
        
        # 4. Safety Net (Draw Probability)
        # Power of 0.3 means:
        # 50% draw -> 0.81 factor
        # 10% draw -> 0.50 factor
        # 0% draw  -> 0.00 factor
        safety_factor = math.pow(draw_prob, 0.3)
        final_ease = raw_ease * safety_factor
        
        print(f"\nRaw Ease (Skill):       {raw_ease:.4f}")
        print(f"Safety (Draw={draw_prob:.2f}):  x {safety_factor:.4f}")
        print(f"FINAL EASE SCORE:       {final_ease:.4f}")
        
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