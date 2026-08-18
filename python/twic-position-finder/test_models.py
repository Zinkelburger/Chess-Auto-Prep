"""Subscription helpers — delete must succeed even after matched games exist."""

import sqlite3
import tempfile
import unittest
from pathlib import Path

from models import (
    add_subscription,
    create_user,
    delete_subscription,
    get_db,
    get_matched_games,
    get_subscriptions,
    insert_game,
    record_notification,
    update_subscription,
)


class SubscriptionLifecycleTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.db = get_db(Path(self._tmp.name) / "test.db")
        user = create_user(self.db, "player@example.com")
        self.user_id = user["id"]

    def tearDown(self):
        self.db.close()
        self._tmp.cleanup()

    def _sub(self, **kwargs):
        defaults = {"player": "Carlsen", "label": "Test"}
        defaults.update(kwargs)
        return add_subscription(self.db, self.user_id, **defaults)

    def _game(self, twic=1600):
        return insert_game(
            self.db,
            {"Event": "Test", "White": "A", "Black": "B", "Result": "1-0"},
            "1. e4 e5 2. Nf3 *",
            "test.pgn",
            twic,
        )

    def test_get_matched_games_returns_owned_rows(self):
        sub = self._sub()
        game_id = self._game(1600)
        record_notification(self.db, sub["id"], game_id, 1600)
        self.db.commit()
        games = get_matched_games(self.db, sub["id"], self.user_id, 1600)
        self.assertIsNotNone(games)
        self.assertEqual(len(games), 1)
        self.assertEqual(games[0]["id"], game_id)
        self.assertEqual(games[0]["white"], "A")

    def test_get_matched_games_rejects_other_users(self):
        sub = self._sub()
        other = create_user(self.db, "other@example.com")
        self.assertIsNone(get_matched_games(self.db, sub["id"], other["id"], 1600))

    def test_get_matched_games_empty_for_other_issue(self):
        sub = self._sub()
        game_id = self._game(1600)
        record_notification(self.db, sub["id"], game_id, 1600)
        self.db.commit()
        games = get_matched_games(self.db, sub["id"], self.user_id, 1599)
        self.assertEqual(games, [])

    def test_delete_subscription_without_matches(self):
        sub = self._sub()
        self.assertTrue(delete_subscription(self.db, sub["id"], self.user_id))
        self.assertEqual(get_subscriptions(self.db, self.user_id), [])

    def test_delete_subscription_after_matches_does_not_raise(self):
        """Regression: FK from notifications_sent used to block DELETE."""
        sub = self._sub()
        game_id = self._game()
        record_notification(self.db, sub["id"], game_id, 1600)
        self.db.commit()

        self.assertTrue(delete_subscription(self.db, sub["id"], self.user_id))
        self.assertEqual(get_subscriptions(self.db, self.user_id), [])
        leftover = self.db.execute(
            "SELECT COUNT(*) FROM notifications_sent WHERE subscription_id = ?",
            (sub["id"],),
        ).fetchone()[0]
        self.assertEqual(leftover, 0)

    def test_delete_rejects_other_users_subscription(self):
        sub = self._sub()
        other = create_user(self.db, "other@example.com")
        self.assertFalse(delete_subscription(self.db, sub["id"], other["id"]))
        self.assertEqual(len(get_subscriptions(self.db, self.user_id)), 1)

    def test_update_subscription_replaces_filters(self):
        sub = self._sub(player="Carlsen", label="Old")
        updated = update_subscription(
            self.db, sub["id"], self.user_id,
            label="New", player="Nakamura", eco="B90",
        )
        self.assertIsNotNone(updated)
        self.assertEqual(updated["label"], "New")
        self.assertEqual(updated["player"], "Nakamura")
        self.assertEqual(updated["eco"], "B90")

    def test_update_missing_subscription_returns_none(self):
        self.assertIsNone(
            update_subscription(self.db, 999, self.user_id, label="x", player="A")
        )

    def test_bare_sql_delete_still_blocked_without_child_cleanup(self):
        """Documents why delete_subscription must clear notifications_sent first.

        New databases get ON DELETE CASCADE, but production DBs created before
        that change do not. A raw DELETE of the parent must still fail there;
        the helper always deletes children first so both schemas work.
        """
        sub = self._sub()
        game_id = self._game()
        record_notification(self.db, sub["id"], game_id, 1600)
        self.db.commit()

        fk_rows = self.db.execute(
            "PRAGMA foreign_key_list(notifications_sent)"
        ).fetchall()
        on_delete = next(
            (row[6] for row in fk_rows if row[2] == "subscriptions"),
            "NO ACTION",
        )
        if str(on_delete).upper() == "CASCADE":
            self.skipTest("fresh schema already cascades")

        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute(
                "DELETE FROM subscriptions WHERE id = ?",
                (sub["id"],),
            )


if __name__ == "__main__":
    unittest.main()
