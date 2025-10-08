from dataclasses import dataclass, field
from typing import List

@dataclass
class FenNode:
    games: int = 0
    wins: int = 0
    losses: int = 0
    draws: int = 0
    game_urls: List[str] = field(default_factory=list)
