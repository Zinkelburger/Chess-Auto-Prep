#!/usr/bin/env python3
import asyncio
import chess
import chess.engine

LC0_PATH = "/var/home/bigman/Documents/CodingProjects/lc0/build/release/lc0"
LC0_NETWORK = "/var/home/bigman/Documents/CodingProjects/lc0/build/release/t3-512x15x16h-distill-swa-2767500.pb.gz"
LC0_THREADS = 4

class SimpleLc0Test:
    def __init__(self):
        self.engine = None

    async def start_engine(self):
        if self.engine is None:
            print("Starting LC0...")
            transport, self.engine = await chess.engine.popen_uci(LC0_PATH)

            print(f"Configuring LC0 with {LC0_THREADS} threads...")
            await self.engine.configure({
                "Backend": "eigen",
                "WeightsFile": LC0_NETWORK,
                "Threads": LC0_THREADS
            })

            await self.engine.ping()
            print("LC0 ready!")

    async def test_parallel_analysis(self):
        await self.start_engine()

        board = chess.Board("r1b2rk1/pp2npbp/2npp1p1/q7/2PPP3/P1N1BN2/1P3PPP/R2QKB1R w KQ - 3 10")
        moves = [chess.Move.from_uci("f3d2"), chess.Move.from_uci("c3d5"), chess.Move.from_uci("f1e2")]

        print(f"Analyzing {len(moves)} moves sequentially...")

        for i, move in enumerate(moves):
            print(f"  -> Move {i+1}: {move}")
            board.push(move)
            info = await self.engine.analyse(board, chess.engine.Limit(nodes=800))
            board.pop()

            if "wdl" in info:
                w, d, l = info["wdl"].wins, info["wdl"].draws, info["wdl"].losses
                q_val = -1 * ((w - l) / (w + d + l))
                print(f"     Q-value: {q_val:.3f}")

        await self.engine.quit()

async def main():
    test = SimpleLc0Test()
    await test.test_parallel_analysis()

if __name__ == "__main__":
    asyncio.run(main())