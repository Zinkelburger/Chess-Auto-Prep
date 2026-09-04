#!/usr/bin/env python3
"""Property tests for the Swiss pairer and the event simulator.

`chess_prep/swiss.py` is the one module here whose output is checkable
without an engine, a network or a fixture: a pairing sheet either partitions
the field or it does not, either repeats an opponent or it does not. So
rather than pin a handful of sheets, this suite generates hundreds of
tournaments from a seeded RNG — odd and even fields, 0 to 24 players, 1 to 8
rounds, withholds, requested byes, accelerated pairings, rating ties — and
replays each one round by round against an independent shadow model built
only from the emitted sheets.

Everything asserted below is a rule the implementation *intends* to enforce
(its module docstring lists them). Four things it does **not** promise, and
which are therefore not asserted:

  * `forced=True` does not actually imply that no legal pairing existed. The
    pairer is greedy and never revisits a board it has already emitted (see
    `_cross_pair`), so it can strand the last player in a group and force a
    rematch that a full matching would have avoided.
  * Colour *alternation* is not guaranteed. Equalization is: the imbalance
    stays within ±3 across every tournament generated here. But runs of five
    consecutive same-colour games occur, so USCF 29E5's "never three in a
    row" is out of scope.
  * Score groups only bind when they can. A player with no legal opponent in
    their own group drops down, by design, so pairings do cross groups. The
    assertion here is conditional: when every group is even *and* every
    intra-group pair is legal, nothing crosses.
  * `SimulationResult.expected_score` and `.bye_prob` are not unbiased when
    `attendance_prob` is in play. `simulate` discards any trial in which
    fewer than two entrants turn up but still divides by the full trial
    count, so both read low. The attendance test below therefore compares
    one entrant against themselves rather than trusting the totals.

Zero dependencies (unittest only), no network, no engine.

    python tools/mcp/test_swiss.py
"""

from __future__ import annotations

import itertools
import random
import statistics
import sys
import unittest
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from chess_prep.roster import Roster, RosterEntry  # noqa: E402
from chess_prep.swiss import (  # noqa: E402
    BLACK,
    WHITE,
    PairingConstraint,
    RoundPairings,
    SimulationConfig,
    SwissPairer,
    SwissRules,
    SwissSeed,
    _COLOR_SEARCH_WINDOW,
    _color_preference,
    _colors_compatible,
    _PlayerState,
    _sample_result,
    simulate,
)

#: Every generated case derives from this. Printed with any failure, so a
#: red run always names the tournament that produced it.
CORPUS_SEED = 20260904

#: Widest imbalance seen across the whole corpus. Asserted rather than
#: merely observed: equalization is the colour rule the pairer does claim,
#: and losing it shows up here as unbounded drift.
MAX_COLOR_IMBALANCE = 3


# ── Shadow model ────────────────────────────────────────────────────────────


class _Shadow:
    """What the sheets say has happened, tracked independently of the pairer.

    Nothing here reads the pairer's internals: scores, opponent sets, colour
    balances and bye history are all reconstructed from the emitted
    `RoundPairings`, so agreeing with `standings()` is a real check rather
    than a tautology.
    """

    def __init__(self, seeds: list[SwissSeed]):
        self.ids = [s.id for s in seeds]
        self.rating = {s.id: s.rating for s in seeds}
        self.half_point = {s.id: set(s.half_point_bye_rounds) for s in seeds}
        self.score = {s.id: s.initial_score for s in seeds}
        self.opponents: dict[str, set[str]] = {s.id: set() for s in seeds}
        self.balance = {s.id: 0 for s in seeds}
        self.last_color: dict[str, str | None] = {s.id: None for s in seeds}
        self.full_byes = {s.id: 0 for s in seeds}
        self.games = {s.id: 0 for s in seeds}

    def pool_for(self, rnd: int) -> list[str]:
        return [i for i in self.ids if rnd not in self.half_point[i]]

    def apply(self, sheet: RoundPairings, white_scores: dict[str, float]) -> None:
        for p in sheet.pairings:
            ws = white_scores[p.white_id]
            self.score[p.white_id] += ws
            self.score[p.black_id] += 1.0 - ws
            self.opponents[p.white_id].add(p.black_id)
            self.opponents[p.black_id].add(p.white_id)
            self.balance[p.white_id] += 1
            self.balance[p.black_id] -= 1
            self.last_color[p.white_id] = WHITE
            self.last_color[p.black_id] = BLACK
            self.games[p.white_id] += 1
            self.games[p.black_id] += 1
        for b in sheet.byes:
            self.score[b.player_id] += b.points
            if not b.requested:
                self.full_byes[b.player_id] += 1


def _case(seed: int) -> tuple[list[SwissSeed], SwissRules]:
    """One randomly shaped event. Small fields and long schedules are as
    interesting as large ones — that is where pairings run out."""
    rng = random.Random(seed)
    count = rng.randint(0, 24)
    rounds = rng.randint(1, 8)
    # Ratings repeat on purpose: the tie-break by id is what keeps the
    # pairing total, and a corpus of distinct ratings would never test it.
    ratings = [rng.choice([1000, 1200, 1200, 1450, 1600, 1600, 1800, 2100, 2400])
               for _ in range(count)]
    seeds = []
    for i in range(count):
        byes = frozenset(
            rng.sample(range(1, rounds + 1), rng.randint(0, 1))
        ) if rng.random() < 0.25 else frozenset()
        seeds.append(SwissSeed(id=f"p{i:02d}", rating=ratings[i], half_point_bye_rounds=byes))
    constraints: list[PairingConstraint] = []
    if count >= 4 and rng.random() < 0.4:
        for _ in range(rng.randint(1, 2)):
            a, b = rng.sample([s.id for s in seeds], 2)
            constraints.append(PairingConstraint(a, b, "withhold"))
    rules = SwissRules(
        rounds=rounds,
        accelerated=rng.random() < 0.25,
        accelerated_rounds=rng.randint(1, 2),
        constraints=tuple(constraints),
    )
    return seeds, rules


def _results(sheet: RoundPairings, rng: random.Random) -> dict[str, float]:
    return {p.white_id: rng.choice([0.0, 0.5, 1.0]) for p in sheet.pairings}


CORPUS = [_case(CORPUS_SEED + i) for i in range(400)]


# ── The sweep ───────────────────────────────────────────────────────────────


class PairingInvariants(unittest.TestCase):
    """One pass over the corpus, asserting every structural rule per round.

    Kept as a single traversal because the invariants are about a *sequence*
    of sheets; re-running 400 tournaments once per assertion would cost eight
    times as much and test nothing extra.
    """

    def test_every_generated_tournament_is_well_formed(self):
        for index, (seeds, rules) in enumerate(CORPUS):
            case_seed = CORPUS_SEED + index
            with self.subTest(case_seed=case_seed, players=len(seeds), rounds=rules.rounds):
                self._replay(case_seed, seeds, rules)

    def _replay(self, case_seed: int, seeds: list[SwissSeed], rules: SwissRules) -> None:
        rng = random.Random(case_seed * 7919 + 1)
        pairer = SwissPairer(seeds, rules)
        shadow = _Shadow(seeds)
        where = f"case_seed={case_seed} n={len(seeds)}"

        self.assertEqual(pairer.player_count, len(seeds), where)

        for rnd in range(1, rules.rounds + 1):
            at = f"{where} round={rnd}"
            pre_score = dict(shadow.score)
            pre_balance = dict(shadow.balance)
            pre_last = dict(shadow.last_color)
            sheet = pairer.next_round()

            self.assertEqual(sheet.round, rnd, at)
            self.assertEqual(pairer.rounds_paired, rnd, at)

            self._assert_partitions_the_field(sheet, shadow, at)
            self._assert_boards_are_numbered_from_one(sheet, at)
            self._assert_byes_follow_the_rule(sheet, shadow, rnd, pre_score, at)
            self._assert_illegal_pairings_are_flagged(sheet, shadow, rules, at)
            self._assert_colors_follow_the_rule(sheet, pre_balance, pre_last, at)
            self._assert_score_groups_hold_when_they_can(
                sheet, shadow, rnd, pre_score, rules, at
            )
            self._assert_accessors_agree(sheet, shadow, at)

            results = _results(sheet, rng)
            pairer.record_results(sheet, results)
            shadow.apply(sheet, results)

            self._assert_totals_are_conserved(sheet, shadow, pre_score, at)
            self._assert_standings_match(pairer, shadow, at)

        for pid in shadow.ids:
            self.assertLessEqual(
                abs(shadow.balance[pid]),
                MAX_COLOR_IMBALANCE,
                f"{where}: {pid} colour balance {shadow.balance[pid]} drifted",
            )

    # ── individual rules ───────────────────────────────────────────────────

    def _assert_partitions_the_field(self, sheet, shadow, at):
        """Every entrant plays exactly one game or takes exactly one bye."""
        seen: list[str] = []
        for p in sheet.pairings:
            seen.extend((p.white_id, p.black_id))
        seen.extend(b.player_id for b in sheet.byes)
        self.assertEqual(
            sorted(seen), sorted(shadow.ids),
            f"{at}: sheet does not partition the field "
            f"(missing={sorted(set(shadow.ids) - set(seen))}, "
            f"duplicated={sorted(x for x in set(seen) if seen.count(x) > 1)})",
        )
        for p in sheet.pairings:
            self.assertNotEqual(p.white_id, p.black_id, f"{at}: {p.white_id} paired with self")

    def _assert_boards_are_numbered_from_one(self, sheet, at):
        boards = [p.board for p in sheet.pairings]
        self.assertEqual(
            boards, list(range(1, len(boards) + 1)),
            f"{at}: boards {boards} are not 1..{len(boards)} in order",
        )

    def _assert_byes_follow_the_rule(self, sheet, shadow, rnd, pre_score, at):
        requested = {b.player_id for b in sheet.byes if b.requested}
        full = [b for b in sheet.byes if not b.requested]
        pool = shadow.pool_for(rnd)

        self.assertEqual(
            requested, {i for i in shadow.ids if rnd in shadow.half_point[i]},
            f"{at}: requested byes do not match the declared rounds",
        )
        for b in sheet.byes:
            self.assertEqual(b.points, 0.5 if b.requested else 1.0, f"{at}: {b}")

        self.assertLessEqual(len(full), 1, f"{at}: {len(full)} full-point byes")
        self.assertEqual(
            len(full), len(pool) % 2,
            f"{at}: pool of {len(pool)} got {len(full)} full-point bye(s)",
        )
        if not full:
            return

        # Lowest score, then lowest rating, then id — among those who have not
        # already had one, falling back to the whole pool once everyone has.
        eligible = [i for i in pool if shadow.full_byes[i] == 0] or list(pool)
        want = min(eligible, key=lambda i: (pre_score[i], shadow.rating[i], i))
        self.assertEqual(
            full[0].player_id, want,
            f"{at}: bye went to {full[0].player_id} "
            f"(score {pre_score[full[0].player_id]}, rating {shadow.rating[full[0].player_id]}, "
            f"prior byes {shadow.full_byes[full[0].player_id]}) rather than {want} "
            f"(score {pre_score[want]}, rating {shadow.rating[want]})",
        )
        self.assertNotIn(full[0].player_id, requested, f"{at}: two byes for one player")

    def _assert_illegal_pairings_are_flagged(self, sheet, shadow, rules, at):
        """A rematch or a withheld pair may only appear as ``forced``."""
        for p in sheet.pairings:
            rematch = p.black_id in shadow.opponents[p.white_id]
            withheld = any(c.involves(p.white_id, p.black_id) for c in rules.constraints)
            if rematch or withheld:
                self.assertTrue(
                    p.forced,
                    f"{at}: board {p.board} {p.white_id}-{p.black_id} is a "
                    f"{'rematch' if rematch else 'withheld pair'} but is not flagged forced",
                )
            else:
                self.assertFalse(
                    p.forced,
                    f"{at}: board {p.board} {p.white_id}-{p.black_id} is legal "
                    "but is flagged forced",
                )
        self.assertEqual(
            sheet.forced_count, sum(1 for p in sheet.pairings if p.forced), at
        )

    def _assert_colors_follow_the_rule(self, sheet, pre_balance, pre_last, at):
        """Equalization first (the player with more Blacks gets White), then
        alternation (whoever played Black last gets White)."""
        for p in sheet.pairings:
            w, b = p.white_id, p.black_id
            if pre_balance[w] != pre_balance[b]:
                self.assertLess(
                    pre_balance[w], pre_balance[b],
                    f"{at}: board {p.board} gave White to {w} (balance "
                    f"{pre_balance[w]}) over {b} (balance {pre_balance[b]}); "
                    "the player owed White is the one with more Blacks",
                )
            elif pre_last[w] != pre_last[b]:
                self.assertNotEqual(
                    pre_last[w], WHITE,
                    f"{at}: board {p.board} gave White to {w} again while "
                    f"{b} (last {pre_last[b]}) was due to alternate",
                )
                self.assertNotEqual(
                    pre_last[b], BLACK,
                    f"{at}: board {p.board} gave Black to {b} again while "
                    f"{w} (last {pre_last[w]}) was due to alternate",
                )

    def _assert_score_groups_hold_when_they_can(
        self, sheet, shadow, rnd, pre_score, rules, at
    ):
        """When no group needs a pair-down and no group is internally blocked,
        nobody crosses a score group. (Acceleration rewrites the groups, so
        this only applies once the virtual points are gone.)"""
        if rules.accelerated and rnd <= rules.accelerated_rounds:
            return
        pool = [i for i in shadow.pool_for(rnd) if not sheet.has_bye(i)]
        groups: dict[float, list[str]] = defaultdict(list)
        for i in pool:
            groups[pre_score[i]].append(i)
        blocked = any(
            b in shadow.opponents[a] or any(c.involves(a, b) for c in rules.constraints)
            for members in groups.values()
            for a, b in itertools.combinations(members, 2)
        )
        if blocked or any(len(v) % 2 for v in groups.values()):
            return
        for p in sheet.pairings:
            self.assertEqual(
                pre_score[p.white_id], pre_score[p.black_id],
                f"{at}: board {p.board} pairs {pre_score[p.white_id]} against "
                f"{pre_score[p.black_id]} although every score group was even "
                "and every pairing inside it was legal",
            )

    def _assert_accessors_agree(self, sheet, shadow, at):
        for pid in shadow.ids:
            found = sheet.for_player(pid)
            has_bye = sheet.has_bye(pid)
            self.assertNotEqual(
                found is None, not has_bye,
                f"{at}: {pid} is {'in a pairing' if found else 'absent'} and "
                f"{'has' if has_bye else 'has no'} bye",
            )
            if found is None:
                continue
            opp = found.opponent_of(pid)
            self.assertIsNotNone(opp, at)
            self.assertEqual(found.opponent_of(opp), pid, at)
            self.assertEqual(
                found.color_of(pid),
                WHITE if pid == found.white_id else BLACK,
                f"{at}: {pid} is the {'White' if pid == found.white_id else 'Black'} "
                f"player on board {found.board} but color_of says {found.color_of(pid)}",
            )
            self.assertNotEqual(found.color_of(pid), found.color_of(opp), at)
            self.assertIsNone(found.color_of("nobody"), at)

    def _assert_totals_are_conserved(self, sheet, shadow, pre_score, at):
        """One point is distributed per board, plus whatever the byes pay."""
        awarded = sum(shadow.score[i] - pre_score[i] for i in shadow.ids)
        expected = len(sheet.pairings) + sum(b.points for b in sheet.byes)
        self.assertAlmostEqual(
            awarded, expected, places=9,
            msg=f"{at}: {awarded} points awarded for {len(sheet.pairings)} "
                f"game(s) and {len(sheet.byes)} bye(s) worth {expected}",
        )

    def _assert_standings_match(self, pairer, shadow, at):
        standings = pairer.standings()
        self.assertEqual(len(standings), len(shadow.ids), at)
        for s in standings:
            self.assertAlmostEqual(s.score, shadow.score[s.player_id], places=9, msg=at)
            self.assertEqual(s.rating, shadow.rating[s.player_id], at)
            self.assertEqual(
                s.color_balance, shadow.balance[s.player_id],
                f"{at}: {s.player_id} balance {s.color_balance} != {shadow.balance[s.player_id]}",
            )
            self.assertAlmostEqual(pairer.score_of(s.player_id), s.score, places=9, msg=at)
        keys = [(-s.score, -s.rating, s.player_id) for s in standings]
        self.assertEqual(keys, sorted(keys), f"{at}: standings are out of order")


# ── Round one, exactly ──────────────────────────────────────────────────────


def _seeds(count: int, base: int = 2400, step: int = 50) -> list[SwissSeed]:
    return [SwissSeed(id=f"p{i + 1}", rating=base - i * step) for i in range(count)]


class RoundOneIsDetermined(unittest.TestCase):
    """With one score group and no history the sheet is fully determined:
    seed *i* meets seed *i + n/2*, White alternating down the boards."""

    def test_top_half_meets_bottom_half_at_every_even_size(self):
        for n in range(2, 33, 2):
            sheet = SwissPairer(_seeds(n)).next_round()
            half = n // 2
            self.assertEqual(len(sheet.pairings), half, n)
            for board, p in enumerate(sheet.pairings, start=1):
                self.assertEqual(
                    {p.white_id, p.black_id},
                    {f"p{board}", f"p{board + half}"},
                    f"n={n} board {board}",
                )

    def test_white_alternates_down_the_boards(self):
        sheet = SwissPairer(_seeds(6)).next_round()
        self.assertEqual([p.white_id for p in sheet.pairings], ["p1", "p5", "p3"])

    def test_odd_size_byes_the_bottom_seed_then_pairs_the_rest_across(self):
        sheet = SwissPairer(_seeds(9)).next_round()
        (bye,) = sheet.byes
        self.assertEqual((bye.player_id, bye.points, bye.requested), ("p9", 1.0, False))
        self.assertEqual(
            [{p.white_id, p.black_id} for p in sheet.pairings],
            [{"p1", "p5"}, {"p2", "p6"}, {"p3", "p7"}, {"p4", "p8"}],
        )

    def test_equal_ratings_still_produce_a_total_order(self):
        seeds = [SwissSeed(id=f"p{i}", rating=1500) for i in range(6)]
        sheet = SwissPairer(seeds).next_round()
        self.assertEqual(
            [{p.white_id, p.black_id} for p in sheet.pairings],
            [{"p0", "p3"}, {"p1", "p4"}, {"p2", "p5"}],
        )


# ── Degenerate fields ───────────────────────────────────────────────────────


class DegenerateFields(unittest.TestCase):
    def test_empty_field_pairs_nothing(self):
        pairer = SwissPairer([])
        sheet = pairer.next_round()
        self.assertEqual((sheet.pairings, sheet.byes), ([], []))
        self.assertEqual(pairer.rounds_paired, 1)
        self.assertEqual(pairer.standings(), [])
        self.assertEqual(pairer.score_of("nobody"), 0.0)

    def test_one_player_byes_every_round(self):
        pairer = SwissPairer(_seeds(1))
        for rnd in range(1, 5):
            sheet = pairer.next_round()
            self.assertEqual(sheet.pairings, [])
            (bye,) = sheet.byes
            self.assertEqual((bye.player_id, bye.points, bye.requested), ("p1", 1.0, False))
            pairer.record_results(sheet, {})
        self.assertEqual(pairer.score_of("p1"), 4.0)

    def test_two_players_alternate_colors_and_flag_every_rematch(self):
        pairer = SwissPairer(_seeds(2))
        whites = []
        for rnd in range(1, 6):
            (p,) = pairer.next_round().pairings
            self.assertEqual(p.forced, rnd > 1, f"round {rnd}")
            whites.append(p.white_id)
            sheet = RoundPairings(round=rnd, pairings=[p])
            pairer.record_results(sheet, {p.white_id: 0.5})
        self.assertEqual(whites, ["p1", "p2", "p1", "p2", "p1"])

    def test_three_players_rotate_the_bye_before_repeating_one(self):
        pairer = SwissPairer(_seeds(3))
        byes = []
        for _ in range(3):
            sheet = pairer.next_round()
            self.assertEqual(len(sheet.pairings), 1)
            (bye,) = sheet.byes
            byes.append(bye.player_id)
            pairer.record_results(sheet, {p.white_id: 1.0 for p in sheet.pairings})
        self.assertEqual(sorted(byes), ["p1", "p2", "p3"])

    def test_a_fourth_round_hands_a_second_bye_out_rather_than_stalling(self):
        pairer = SwissPairer(_seeds(3))
        seen = []
        for _ in range(4):
            sheet = pairer.next_round()
            seen.extend(b.player_id for b in sheet.byes)
            self.assertEqual(len(sheet.byes), 1)
            pairer.record_results(sheet, {p.white_id: 1.0 for p in sheet.pairings})
        self.assertEqual(len(seen), 4)
        self.assertEqual(len(set(seen)), 3, seen)

    def test_a_field_with_every_pairing_used_up_keeps_pairing(self):
        """Four players exhaust their three legal rounds; round four cannot be
        legal, and must be a flagged rematch rather than a dropped player."""
        pairer = SwissPairer(_seeds(4))
        met: set[frozenset[str]] = set()
        for rnd in range(1, 4):
            sheet = pairer.next_round()
            self.assertEqual(sheet.forced_count, 0, f"round {rnd}")
            met.update(frozenset((p.white_id, p.black_id)) for p in sheet.pairings)
            pairer.record_results(sheet, {p.white_id: 0.5 for p in sheet.pairings})
        self.assertEqual(len(met), 6)

        fourth = pairer.next_round()
        self.assertEqual(len(fourth.pairings), 2)
        self.assertEqual(fourth.forced_count, 2)
        self.assertEqual(
            sorted(i for p in fourth.pairings for i in (p.white_id, p.black_id)),
            ["p1", "p2", "p3", "p4"],
        )

    def test_a_whole_field_on_requested_byes_plays_no_games(self):
        seeds = [SwissSeed(id=f"p{i}", rating=1500, half_point_bye_rounds=frozenset({1}))
                 for i in range(5)]
        pairer = SwissPairer(seeds)
        sheet = pairer.next_round()
        self.assertEqual(sheet.pairings, [])
        self.assertEqual(len(sheet.byes), 5)
        self.assertTrue(all(b.requested and b.points == 0.5 for b in sheet.byes))
        pairer.record_results(sheet, {})
        self.assertEqual([s.score for s in pairer.standings()], [0.5] * 5)

    def test_a_requested_bye_never_doubles_as_the_odd_field_bye(self):
        seeds = [
            SwissSeed("p1", 2000),
            SwissSeed("p2", 1900),
            SwissSeed("p3", 1800, frozenset({1})),
            SwissSeed("p4", 1700),
        ]
        sheet = SwissPairer(seeds).next_round()
        self.assertEqual(len(sheet.byes), 2)
        self.assertEqual(
            sorted((b.player_id, b.points, b.requested) for b in sheet.byes),
            [("p3", 0.5, True), ("p4", 1.0, False)],
        )
        self.assertEqual(len(sheet.pairings), 1)

    def test_an_odd_score_group_pairs_down_its_lowest_player(self):
        """The player who drops into the next group is the bottom of the odd
        group, not the top of it: a leader must not be handed a weaker
        opponent because their group happened to be odd."""
        seeds = [
            SwissSeed("a", 2000, initial_score=1.0),
            SwissSeed("b", 1900, initial_score=1.0),
            SwissSeed("c", 1800, initial_score=1.0),
            SwissSeed("d", 1700, initial_score=0.0),
            SwissSeed("e", 1600, initial_score=0.0),
            SwissSeed("f", 1500, initial_score=0.0),
        ]
        sheet = SwissPairer(seeds).next_round()
        self.assertEqual(
            [{p.white_id, p.black_id} for p in sheet.pairings],
            [{"a", "b"}, {"c", "e"}, {"d", "f"}],
        )

    def test_a_blocked_group_takes_the_highest_ranked_legal_opponent(self):
        """When no bottom-half candidate can satisfy both colour preferences,
        the pairing falls back to the *first* legal one — the smallest
        transposition — rather than the last one it happened to look at."""
        pairer = SwissPairer(_seeds(6))
        first = pairer.next_round()
        self.assertEqual(
            [(p.white_id, p.black_id) for p in first.pairings],
            [("p1", "p4"), ("p5", "p2"), ("p3", "p6")],
        )
        pairer.record_results(first, {"p1": 1.0, "p5": 0.5, "p3": 1.0})

        # p2 and p5 both sit on 0.5 and have already met, so both drop into
        # the 0.0 group, where every candidate is due White just as they are.
        second = pairer.next_round()
        self.assertEqual(second.forced_count, 0)
        self.assertEqual(
            [(p.white_id, p.black_id) for p in second.pairings],
            [("p1", "p3"), ("p4", "p2"), ("p6", "p5")],
        )

    def test_a_colour_compatible_opponent_is_preferred_to_the_nearest_one(self):
        """Inside the search window the pairer will pass over a legal opponent
        to reach one whose colour preference opposes its own. Here p3 is due
        Black and so is p1, the rating-nearest candidate; p2 is due White, so
        p3 crosses to p2 and p1 drops to p6."""
        pairer = SwissPairer(_seeds(6))
        first = pairer.next_round()
        pairer.record_results(first, {"p1": 0.0, "p5": 1.0, "p3": 0.5})
        self.assertEqual(
            {s.player_id: (s.score, s.color_balance) for s in pairer.standings()},
            {
                "p4": (1.0, -1), "p5": (1.0, 1), "p3": (0.5, 1),
                "p6": (0.5, -1), "p1": (0.0, 1), "p2": (0.0, -1),
            },
        )
        second = pairer.next_round()
        self.assertEqual(second.forced_count, 0)
        self.assertEqual(
            [(p.white_id, p.black_id) for p in second.pairings],
            [("p4", "p5"), ("p2", "p3"), ("p6", "p1")],
        )

    def test_everyone_on_the_same_score_is_one_group(self):
        pairer = SwissPairer(_seeds(8))
        r1 = pairer.next_round()
        pairer.record_results(r1, {p.white_id: 0.5 for p in r1.pairings})
        for s in pairer.standings():
            self.assertEqual(s.score, 0.5)
        r2 = pairer.next_round()
        self.assertEqual(len(r2.pairings), 4)
        self.assertEqual(r2.forced_count, 0)

    def test_initial_scores_carry_into_the_first_score_groups(self):
        seeds = [
            SwissSeed("a", 1500, initial_score=2.0),
            SwissSeed("b", 1400, initial_score=2.0),
            SwissSeed("c", 1300, initial_score=0.0),
            SwissSeed("d", 1200, initial_score=0.0),
        ]
        sheet = SwissPairer(seeds).next_round()
        self.assertEqual(
            [{p.white_id, p.black_id} for p in sheet.pairings], [{"a", "b"}, {"c", "d"}]
        )


class Withholds(unittest.TestCase):
    def test_a_withhold_is_honoured_when_a_transposition_reaches_it(self):
        rules = SwissRules(constraints=(PairingConstraint("p1", "p5", "siblings"),))
        sheet = SwissPairer(_seeds(8), rules).next_round()
        self.assertEqual(sheet.forced_count, 0)
        self.assertNotEqual(sheet.for_player("p1").opponent_of("p1"), "p5")

    def test_a_withhold_that_is_broken_is_always_flagged(self):
        """Two entrants who may not meet, and nobody else: the sheet says so."""
        rules = SwissRules(constraints=(PairingConstraint("p1", "p2"),))
        (p,) = SwissPairer(_seeds(2), rules).next_round().pairings
        self.assertTrue(p.forced)

    def test_a_withhold_binds_in_both_directions(self):
        rules = SwissRules(constraints=(PairingConstraint("p5", "p1"),))
        sheet = SwissPairer(_seeds(8), rules).next_round()
        self.assertNotEqual(sheet.for_player("p1").opponent_of("p1"), "p5")


def _state(pid: str, balance: int = 0, last: str | None = None) -> _PlayerState:
    p = _PlayerState(pid, 1500, 0, frozenset(), 0.0)
    p.color_balance = balance
    p.last_color = last
    return p


class ColorPreferenceRules(unittest.TestCase):
    """The preference table the candidate search is built on. Read as: how
    many more Whites than Blacks, and what colour last time, decide what a
    player is owed — and equalization wins where the two disagree."""

    def test_more_blacks_than_whites_means_you_are_owed_white(self):
        self.assertEqual(_color_preference(_state("a", balance=-2)), 1)
        self.assertEqual(_color_preference(_state("a", balance=2)), -1)

    def test_level_players_simply_alternate(self):
        self.assertEqual(_color_preference(_state("a", balance=0, last=BLACK)), 1)
        self.assertEqual(_color_preference(_state("a", balance=0, last=WHITE)), -1)

    def test_equalization_outranks_alternation(self):
        """One Black down and coming off a Black: still owed White. If
        alternation won here a player could never climb out of a deficit."""
        self.assertEqual(_color_preference(_state("a", balance=-1, last=BLACK)), 1)
        self.assertEqual(_color_preference(_state("a", balance=1, last=WHITE)), -1)

    def test_an_unplayed_player_is_owed_nothing(self):
        self.assertEqual(_color_preference(_state("a")), 0)

    def test_two_players_owed_the_same_colour_do_not_fit(self):
        self.assertFalse(_colors_compatible(_state("a", -1), _state("b", -1)))
        self.assertFalse(_colors_compatible(_state("a", 1), _state("b", 1)))
        self.assertTrue(_colors_compatible(_state("a", -1), _state("b", 1)))

    def test_a_player_owed_nothing_fits_anyone(self):
        for other in (-2, 0, 2):
            self.assertTrue(_colors_compatible(_state("a"), _state("b", other)), other)


class CandidateSearch(unittest.TestCase):
    """`_find_partner` will pass over candidates whose colours clash, but only
    so far: past the window the rating distortion costs more than the colour
    is worth, so it settles for the nearest legal opponent instead."""

    def setUp(self):
        self.pairer = SwissPairer(_seeds(2))

    def test_it_reaches_past_a_clash_to_a_compatible_opponent(self):
        me = _state("me", balance=-1)
        bottom = [_state(f"b{i}", balance=-1) for i in range(_COLOR_SEARCH_WINDOW - 1)]
        bottom.append(_state("fits", balance=1))
        self.assertEqual(self.pairer._find_partner(me, bottom), len(bottom) - 1)

    def test_it_gives_up_after_the_window_and_takes_the_nearest(self):
        me = _state("me", balance=-1)
        bottom = [_state(f"b{i}", balance=-1) for i in range(_COLOR_SEARCH_WINDOW)]
        bottom.append(_state("fits", balance=1))
        self.assertEqual(self.pairer._find_partner(me, bottom), 0)

    def test_an_illegal_candidate_is_skipped_without_spending_the_window(self):
        me = _state("me", balance=-1)
        me.opponents = {"b0"}
        bottom = [_state("b0", balance=1)] + [
            _state(f"b{i}", balance=-1) for i in range(1, _COLOR_SEARCH_WINDOW)
        ]
        bottom.append(_state("fits", balance=1))
        self.assertEqual(self.pairer._find_partner(me, bottom), len(bottom) - 1)

    def test_no_legal_candidate_means_no_partner(self):
        me = _state("me")
        me.opponents = {"b0", "b1"}
        self.assertIsNone(
            self.pairer._find_partner(me, [_state("b0"), _state("b1")])
        )


class Acceleration(unittest.TestCase):
    def test_virtual_points_split_the_field_into_quarters(self):
        """The virtual point goes to the *top* half, so the first four boards
        are the top quarter against the second — not the bottom half playing
        itself on board one."""
        rules = SwissRules(accelerated=True, accelerated_rounds=2)
        sheet = SwissPairer(_seeds(16), rules).next_round()
        for board, p in enumerate(sheet.pairings, start=1):
            top = board <= 4
            i = board if top else board + 4
            self.assertEqual(
                {p.white_id, p.black_id}, {f"p{i}", f"p{i + 4}"},
                f"board {board}",
            )

    def test_the_virtual_point_expires_after_the_announced_rounds(self):
        rules = SwissRules(rounds=3, accelerated=True, accelerated_rounds=1)
        accelerated = SwissPairer(_seeds(16), rules)
        plain = SwissPairer(_seeds(16), SwissRules(rounds=3))
        for pairer in (accelerated, plain):
            for _ in range(2):
                sheet = pairer.next_round()
                pairer.record_results(sheet, {p.white_id: 1.0 for p in sheet.pairings})
        # Round one differed, so the standings differ; what must be true is
        # that round three groups purely on real score again.
        third = accelerated.next_round()
        scores = {s.player_id: s.score for s in accelerated.standings()}
        blocked = any(p.forced for p in third.pairings)
        if not blocked:
            for p in third.pairings:
                self.assertEqual(scores[p.white_id], scores[p.black_id], p)


class Determinism(unittest.TestCase):
    def test_two_pairers_on_the_same_inputs_agree_move_for_move(self):
        seeds, rules = CORPUS[3]

        def run() -> list[tuple]:
            pairer = SwissPairer(seeds, rules)
            rng = random.Random(99)
            out = []
            for _ in range(rules.rounds):
                sheet = pairer.next_round()
                out.append(
                    (
                        tuple((p.board, p.white_id, p.black_id, p.forced) for p in sheet.pairings),
                        tuple((b.player_id, b.points, b.requested) for b in sheet.byes),
                    )
                )
                pairer.record_results(sheet, _results(sheet, rng))
            return out

        self.assertEqual(run(), run())

    def test_seed_order_does_not_depend_on_input_order(self):
        seeds, rules = CORPUS[11]
        shuffled = list(seeds)
        random.Random(5).shuffle(shuffled)

        def first_sheet(order):
            sheet = SwissPairer(order, rules).next_round()
            return [(p.board, p.white_id, p.black_id) for p in sheet.pairings]

        self.assertEqual(first_sheet(seeds), first_sheet(shuffled))


# ── The result model ────────────────────────────────────────────────────────


class ResultSampling(unittest.TestCase):
    def test_only_chess_results_come_out(self):
        rng = random.Random(1)
        self.assertEqual(
            {_sample_result(1500, 1800, 0.3, rng) for _ in range(5000)}, {0.0, 0.5, 1.0}
        )

    def test_the_mean_is_the_elo_expectation(self):
        """The draw rate reshapes the distribution but must not move its mean;
        a draw stolen from the wrong side would show here."""
        rng = random.Random(2)
        for white, black in [(2000, 2000), (2000, 1800), (1700, 2100), (2400, 1200)]:
            expected = 1.0 / (1.0 + 10 ** ((black - white) / 400.0))
            got = statistics.fmean(
                _sample_result(white, black, 0.30, rng) for _ in range(60000)
            )
            self.assertAlmostEqual(got, expected, delta=0.01, msg=f"{white} v {black}")

    def test_a_zero_draw_rate_produces_no_draws(self):
        rng = random.Random(3)
        self.assertNotIn(
            0.5, {_sample_result(1900, 1850, 0.0, rng) for _ in range(5000)}
        )

    def test_rating_advantage_is_monotone(self):
        rng = random.Random(4)

        def mean(white):
            return statistics.fmean(
                _sample_result(white, 1800, 0.30, rng) for _ in range(20000)
            )

        means = [mean(w) for w in (1400, 1700, 1800, 1900, 2200)]
        self.assertEqual(means, sorted(means), means)


# ── The simulator ───────────────────────────────────────────────────────────


def _roster(count: int, rounds: int = 4, **kw) -> Roster:
    entries = [
        RosterEntry(id=f"p{i}", name=f"Player {i}", rating=kw.pop("rating", None) or 2000 - 40 * i)
        for i in range(count)
    ]
    entries[0].is_me = True
    return Roster(event_name="Test Open", rounds=rounds, entries=entries, **kw)


class SimulationInvariants(unittest.TestCase):
    def test_you_are_paired_or_byed_in_every_round_of_every_trial(self):
        """With a full even field there are no byes, so the per-round pairing
        mass must be exactly one — no trial may lose you."""
        result = simulate(_roster(8, rounds=4), SimulationConfig(trials=300, seed=11))
        self.assertEqual(result.bye_prob, 0.0)
        for rnd in range(4):
            self.assertAlmostEqual(
                sum(o.prob_by_round[rnd] for o in result.opponents), 1.0, places=9,
                msg=f"round {rnd + 1}",
            )

    def test_an_odd_field_splits_the_mass_between_opponents_and_the_bye(self):
        result = simulate(_roster(7, rounds=4), SimulationConfig(trials=300, seed=12))
        self.assertGreater(result.bye_prob, 0.0)
        for rnd in range(4):
            self.assertLessEqual(
                sum(o.prob_by_round[rnd] for o in result.opponents), 1.0 + 1e-9,
                f"round {rnd + 1}",
            )

    def test_probabilities_stay_inside_their_bounds(self):
        result = simulate(_roster(11, rounds=5), SimulationConfig(trials=300, seed=13))
        self.assertTrue(result.opponents)
        for o in result.opponents:
            self.assertGreater(o.prob_any, 0.0, o.player_id)
            self.assertLessEqual(o.prob_any, 1.0, o.player_id)
            # Colour counts are per game, prob_any is per trial, so the split
            # covers the whole of it and may exceed it after a forced rematch.
            self.assertGreaterEqual(
                o.prob_as_white + o.prob_as_black + 1e-9, o.prob_any, o.player_id
            )
            self.assertAlmostEqual(
                sum(o.prob_by_round), o.prob_as_white + o.prob_as_black, places=9,
                msg=o.player_id,
            )
            self.assertEqual(len(o.prob_by_round), 5, o.player_id)
        self.assertNotIn("p0", {o.player_id for o in result.opponents})

    def test_opponents_come_back_ranked(self):
        result = simulate(_roster(12, rounds=5), SimulationConfig(trials=300, seed=14))
        keys = [(-o.prob_any, o.player_id) for o in result.opponents]
        self.assertEqual(keys, sorted(keys))
        # Round one is a deterministic cross-pairing, so the top seed's first
        # opponent is not a probability at all: seed 0 of 12 always meets
        # seed 6, in round one, in every trial. That certainty must rank first.
        first = result.opponents[0]
        self.assertEqual(first.player_id, "p6")
        self.assertEqual(first.prob_any, 1.0)
        self.assertEqual(first.prob_by_round[0], 1.0)
        self.assertEqual(first.most_likely_round, 1)
        # The colours are yours, not theirs: board one of round one gives
        # White to the higher seed, and you are it.
        self.assertEqual((first.prob_as_white, first.prob_as_black), (1.0, 0.0))
        self.assertGreater(sum(o.prob_as_black for o in result.opponents), 0.0)
        self.assertEqual(
            sum(o.prob_by_round[0] for o in result.opponents if o.player_id != "p6"),
            0.0,
        )

    def test_coverage_takes_the_shortest_prefix_that_reaches_the_target(self):
        result = simulate(_roster(14, rounds=5), SimulationConfig(trials=300, seed=15))
        total = sum(o.prob_any for o in result.opponents)
        for coverage in (0.25, 0.5, 0.9, 1.0):
            top = result.top_by_coverage(coverage)
            self.assertEqual(top, result.opponents[: len(top)], coverage)
            self.assertGreaterEqual(
                sum(o.prob_any for o in top) + 1e-9, total * coverage, coverage
            )
            if len(top) > 1:
                self.assertLess(
                    sum(o.prob_any for o in top[:-1]), total * coverage, coverage
                )

    def test_the_favourite_scores_better_than_the_backmarker(self):
        """Catches a colour or result mix-up in `record_results`: the top seed
        of a lopsided field must beat half, the bottom seed must not."""
        strong = simulate(_roster(10, rounds=5), SimulationConfig(trials=400, seed=16))
        weak_roster = _roster(10, rounds=5)
        weak_roster.entries[0].is_me = False
        weak_roster.entries[-1].is_me = True
        weak = simulate(weak_roster, SimulationConfig(trials=400, seed=16))
        self.assertGreater(strong.expected_score, 3.0)
        self.assertLess(weak.expected_score, 2.5)
        self.assertLess(weak.expected_score, strong.expected_score)

    def test_an_even_field_of_equals_scores_half(self):
        entries = [RosterEntry(id=f"p{i}", name=f"P{i}", rating=1600) for i in range(10)]
        entries[0].is_me = True
        result = simulate(
            Roster(event_name="Flat", rounds=6, entries=entries),
            SimulationConfig(trials=500, seed=17),
        )
        self.assertAlmostEqual(result.expected_score, 3.0, delta=0.25)

    def test_the_same_seed_reproduces_the_run_and_a_different_seed_does_not(self):
        roster = _roster(10, rounds=5)
        a = simulate(roster, SimulationConfig(trials=200, seed=21)).to_dict()
        b = simulate(roster, SimulationConfig(trials=200, seed=21)).to_dict()
        c = simulate(roster, SimulationConfig(trials=200, seed=22)).to_dict()
        self.assertEqual(a, b)
        self.assertNotEqual(a, c)

    def test_withdrawn_entrants_are_not_paired(self):
        roster = _roster(8, rounds=4)
        roster.entries[3].withdrawn = True
        result = simulate(roster, SimulationConfig(trials=200, seed=18))
        self.assertNotIn("p3", {o.player_id for o in result.opponents})
        self.assertIn("p4", {o.player_id for o in result.opponents})

    def test_only_your_section_is_simulated(self):
        roster = _roster(10, rounds=4)
        for i, e in enumerate(roster.entries):
            e.section = "Open" if i < 5 else "Reserve"
        result = simulate(roster, SimulationConfig(trials=200, seed=19))
        self.assertEqual(
            {o.player_id for o in result.opponents}, {"p1", "p2", "p3", "p4"}
        )
        self.assertTrue(any("Open" in n for n in result.notes), result.notes)

    def test_a_sectionless_entrant_is_told_the_field_was_not_filtered(self):
        roster = _roster(10, rounds=4)
        for e in roster.entries[1:]:
            e.section = "Open"
        result = simulate(roster, SimulationConfig(trials=100, seed=20))
        self.assertTrue(any("no section" in n for n in result.notes), result.notes)
        self.assertEqual(len(result.opponents), 9)

    def test_withholds_on_the_roster_reach_the_pairer(self):
        roster = _roster(6, rounds=3)
        roster.constraints = [{"a": "p0", "b": "p1", "reason": "siblings"}]
        result = simulate(roster, SimulationConfig(trials=400, seed=23))
        by_id = {o.player_id: o for o in result.opponents}
        self.assertLess(by_id["p1"].prob_any, by_id["p2"].prob_any)

    def test_unrated_entrants_are_seeded_at_the_field_median(self):
        roster = _roster(8, rounds=4)
        roster.entries[5].rating = None
        median = sorted(e.rating for e in roster.entries if e.rating is not None)[3]
        result = simulate(roster, SimulationConfig(trials=100, seed=24))
        self.assertEqual(
            [n for n in result.notes if "unrated" in n],
            [f"1 unrated entrant(s) seeded at {median} (field median)."],
        )

    def test_a_configured_unrated_rating_is_used_and_named(self):
        """Four entrants, three rated and one unknown. Seeded at the median
        the unknown lands beside you and you meet them in round one; seeded
        at 2600 they become the top seed and you meet the bottom one instead
        — so the setting has to reach the pairer, not just the note."""
        roster = _roster(4, rounds=1)
        roster.entries[3].rating = None

        median = simulate(roster, SimulationConfig(trials=50, seed=24))
        self.assertEqual(
            [n for n in median.notes if "unrated" in n],
            ["1 unrated entrant(s) seeded at 1960 (field median)."],
        )
        self.assertEqual([o.player_id for o in median.opponents], ["p3"])

        configured = simulate(
            roster, SimulationConfig(trials=50, seed=24, unrated_rating=2600)
        )
        self.assertEqual(
            [n for n in configured.notes if "unrated" in n],
            ["1 unrated entrant(s) seeded at 2600 (configured)."],
        )
        self.assertEqual([o.player_id for o in configured.opponents], ["p2"])

    def test_attendance_thins_the_field(self):
        """An entrant who may not show up is faced less often, and one who
        certainly will not is never faced at all."""
        def prob_of(pid: str, absent: dict[str, float]) -> float:
            roster = _roster(9, rounds=4)
            for target, prob in absent.items():
                roster.find(target).attendance_prob = prob
            result = simulate(roster, SimulationConfig(trials=600, seed=27))
            return {o.player_id: o.prob_any for o in result.opponents}.get(pid, 0.0)

        always = prob_of("p5", {})
        self.assertGreater(always, 0.1)
        self.assertLess(prob_of("p5", {"p5": 0.5}), always * 0.75)
        self.assertEqual(prob_of("p4", {"p4": 0.0}), 0.0)

    def test_nothing_to_simulate_is_reported_rather_than_guessed(self):
        anonymous = _roster(6)
        anonymous.entries[0].is_me = False
        empty = simulate(anonymous, SimulationConfig(trials=50))
        self.assertEqual((empty.opponents, empty.trials), ([], 0))
        self.assertTrue(any("Mark yourself" in n for n in empty.notes))

        alone = _roster(1)
        solo = simulate(alone, SimulationConfig(trials=50))
        self.assertEqual((solo.opponents, solo.trials), ([], 0))
        self.assertTrue(any("nothing to simulate" in n for n in solo.notes))

    def test_a_requested_bye_shows_up_as_a_bye(self):
        roster = _roster(8, rounds=4)
        roster.entries[0].half_point_byes = [2]
        result = simulate(roster, SimulationConfig(trials=200, seed=25))
        self.assertGreater(result.bye_prob, 0.0)
        self.assertEqual(sum(o.prob_by_round[1] for o in result.opponents), 0.0)

    def test_the_dict_form_rounds_without_losing_the_ranking(self):
        result = simulate(_roster(9, rounds=4), SimulationConfig(trials=200, seed=26))
        data = result.to_dict()
        self.assertEqual(data["rounds"], 4)
        self.assertEqual(data["trials"], 200)
        self.assertEqual(
            [o["player_id"] for o in data["opponents"]],
            [o.player_id for o in result.opponents],
        )
        for o, raw in zip(result.opponents, data["opponents"]):
            self.assertEqual(raw["most_likely_round"], o.most_likely_round)
            self.assertIn(raw["most_likely_round"], range(1, 5))
            self.assertEqual(len(raw["prob_by_round"]), 4)


if __name__ == "__main__":
    unittest.main(verbosity=2)
