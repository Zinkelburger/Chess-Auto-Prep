#!/usr/bin/env python3
import asyncio
import chess
import chess.engine

LC0_PATH = "/var/home/bigman/Documents/CodingProjects/lc0/build/release/lc0"
LC0_NETWORK = "/var/home/bigman/Documents/CodingProjects/lc0/build/release/t3-512x15x16h-distill-swa-2767500.pb.gz"
LC0_THREADS = 4

async def test_lc0():
    print("Starting LC0 with threading...")
    transport, engine = await chess.engine.popen_uci(LC0_PATH)

    print("Configuring LC0...")
    await engine.configure({
        "Backend": "eigen",
        "WeightsFile": LC0_NETWORK,
        "Threads": LC0_THREADS
    })

    print("Pinging engine...")
    await engine.ping()
    print("Engine ready!")

    # Quick test analysis
    board = chess.Board("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
    print("Running quick analysis...")

    info = await engine.analyse(board, chess.engine.Limit(nodes=100))
    print(f"Analysis complete: {info}")

    await engine.quit()
    print("Test complete!")

if __name__ == "__main__":
    asyncio.run(test_lc0())