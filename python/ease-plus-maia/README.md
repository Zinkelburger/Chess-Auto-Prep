I've been thinking about this for  along time, but its inspired by this blog: https://lichess.org/@/matstc/blog/a-chess-metric-ease-for-humans/dIqTm3AJ

Ease Score:
Close to 1.0: The most natural human moves are also the best moves. (Easy to play).
Close to 0.0: The most natural human moves are blunders. (You are walking into a trap).


Modify the metric to punish positions where the Draw Probability is low. If a position is "Win or Die" (Low Draw %), it is inherently harder for a human because you have no safety net.

We can add a Volatility Penalty to the Ease Score.

New Ease=Old Ease×(Draw Probability)γ
(Where γ is a small tuning number, e.g., 0.5)
In Scenario A (80% Draw): Penalty is small. Score stays high.
In Scenario B (0% Draw): Penalty is maximum. Ease score drops to 0.

Maia: "What do I want to play?"
Lc0 (Q): "Is that move actually a blunder?" (The Regret)
Lc0 (Draw%): "Is this position a coin-flip?" (The Safety Factor)
