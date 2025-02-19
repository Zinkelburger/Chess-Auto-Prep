from dataclasses import dataclass

@dataclass
class FenNode:
    games: int = 0
    wins: int = 0
    losses: int = 0
    draws: int = 0
