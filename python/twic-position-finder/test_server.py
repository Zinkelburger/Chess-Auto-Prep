# A None here fails the test on its own, so pyright's None checks add nothing.
# pyright: reportOptionalMemberAccess=false, reportOptionalSubscript=false
"""The public API under hostile input: bounds, ownership, rate-limit keys."""

import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_TMP = tempfile.TemporaryDirectory()
for _name, _file in (("TWIC_DB_PATH", "positions.db"), ("BUGHOUSEDB_PATH", "bughousedb.db"),
                     ("BOOKING_DATABASE_PATH", "bookings.db"),
                     ("BUGHOUSE_EXPECTIMAX_PATH", "expectimax.db")):
    os.environ[_name] = str(Path(_TMP.name) / _file)
os.environ.pop("TURNSTILE_SECRET_KEY", None)

from fastapi.testclient import TestClient  # noqa: E402

import booking  # noqa: E402
import models  # noqa: E402
import server  # noqa: E402
import weekly  # noqa: E402

CLOUDFLARE_EDGE = ("173.245.48.10", 443)
START = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"


class ServerTests(unittest.TestCase):
    def setUp(self):
        server.limiter.reset()
        self.conn = models.get_db(server.DB_PATH)
        for table in ("notifications_sent", "email_tokens", "subscriptions", "positions",
                      "games", "users"):
            self.conn.execute(f"DELETE FROM {table}")
        self.conn.commit()
        self.client = TestClient(server.app, client=CLOUDFLARE_EDGE)

    def tearDown(self):
        self.client.close()
        self.conn.close()

    def user(self, email="owner@example.com"):
        user = models.create_user(self.conn, email)
        models.verify_user(self.conn, user["verify_token"])
        token = models.rotate_auth_token(self.conn, user["id"])
        return user["id"], {"Authorization": f"Bearer {token}"}

    def matched_sub(self, user_id, label="Test"):
        sub = models.add_subscription(self.conn, user_id, label=label, player="Carlsen")
        game = models.insert_game(self.conn, {"White": "Carlsen"}, "1. e4 *", "twic1.pgn", 1)
        models.record_notification(self.conn, sub["id"], game, 1)
        self.conn.commit()
        return sub["id"]

    def test_pgn_download_works_for_any_label(self):
        uid, auth = self.user()
        sid = self.matched_sub(uid, label='Карлсен "Najdorf"')
        r = self.client.get(f"/api/subscriptions/{sid}/pgn?twic=1", headers=auth)
        self.assertEqual(r.status_code, 200)
        header = r.headers["content-disposition"]
        self.assertIn('filename="Najdorf_twic1.pgn"', header)
        self.assertIn("filename*=UTF-8''%D0%9A", header)

    def test_pgn_download_says_the_same_for_every_unowned_alert(self):
        _, auth = self.user()
        other, _ = self.user("other@example.com")
        with_games = self.matched_sub(other)
        without = models.add_subscription(self.conn, other, player="Caruana")["id"]
        for sid in (with_games, without):
            r = self.client.get(f"/api/subscriptions/{sid}/pgn", headers=auth)
            self.assertEqual((r.status_code, r.json()["detail"]), (404, "Subscription not found"))

    def test_numbers_beyond_sqlite_are_refused_not_crashed(self):
        _, auth = self.user()
        big = 10**20
        r = self.client.post("/api/subscriptions", headers=auth,
                             json={"player": "Carlsen", "min_elo": big})
        self.assertEqual(r.status_code, 422)
        self.assertEqual(self.client.get(f"/api/subscriptions/{big}/games?twic=1",
                                         headers=auth).status_code, 422)
        self.assertEqual(self.client.get(f"/api/subscriptions/1/games?twic={big}",
                                         headers=auth).status_code, 422)
        self.assertEqual(self.client.delete(f"/api/subscriptions/{big}",
                                            headers=auth).status_code, 422)

    def test_alert_fields_are_bounded(self):
        _, auth = self.user()
        for body in ({"player": "a " * 17000},
                     {"fen": [START] * (server.MAX_FENS + 1)},
                     {"player": "Carlsen", "label": "Hi\r\nBcc: x@example.com"}):
            r = self.client.post("/api/subscriptions", headers=auth, json=body)
            self.assertEqual(r.status_code, 422, body.keys())
        ok = self.client.post("/api/subscriptions", headers=auth,
                              json={"fen": [START, START], "label": "Two"})
        self.assertEqual(ok.status_code, 200)
        self.assertEqual(ok.json()["subscription"]["fen"], f"{START}\n{START}")

    def test_an_alert_typed_for_someone_elses_address_waits_for_its_owner(self):
        uid, auth = self.user()
        sent = {}
        with mock.patch.object(server, "send_login_email",
                               lambda to, token, **_: sent.setdefault("token", token)):
            r = self.client.post("/api/subscribe",
                                 json={"email": "owner@example.com", "player": "Spammer"})
        self.assertEqual(r.json()["status"], "subscription_added")
        self.assertEqual(self.client.get("/api/subscriptions", headers=auth).json(),
                         {"subscriptions": []})
        r = self.client.post("/api/exchange-token", json={"token": sent["token"]})
        auth = {"Authorization": f"Bearer {r.json()['auth_token']}"}
        subs = self.client.get("/api/subscriptions", headers=auth).json()["subscriptions"]
        self.assertEqual([s["player"] for s in subs], ["Spammer"])
        self.assertEqual(models.count_user_subscriptions(self.conn, uid), 1)

    def test_rate_limits_count_each_visitor_behind_cloudflare(self):
        for i in range(5):
            self.client.post("/api/login", json={"email": f"x{i}@example.com"},
                             headers={"CF-Connecting-IP": "198.51.100.1"})
        r = self.client.post("/api/login", json={"email": "y@example.com"},
                             headers={"CF-Connecting-IP": "198.51.100.2"})
        self.assertEqual(r.status_code, 400)  # not found, but not someone else's 429

    def test_a_direct_caller_cannot_choose_its_rate_limit_key(self):
        with TestClient(server.app, client=("203.0.113.5", 1)) as direct:
            codes = [direct.post("/api/login", json={"email": "x@example.com"},
                                 headers={"CF-Connecting-IP": f"198.51.100.{i}"}).status_code
                     for i in range(6)]
        self.assertEqual(codes[-1], 429)


class BookingKeyTests(unittest.TestCase):
    def test_an_unset_key_is_not_a_published_default(self):
        spec = importlib.util.spec_from_file_location("fresh_booking", booking.__file__)
        fresh = importlib.util.module_from_spec(spec)
        with mock.patch.dict(os.environ, {"BOOKING_API_KEY": ""}):
            os.environ.pop("BOOKING_API_KEY")
            spec.loader.exec_module(fresh)
        self.assertEqual(fresh.API_KEY, "")

    def test_the_bookings_list_is_closed_without_a_configured_key(self):
        booking.init_booking_db()
        with TestClient(server.app) as client:
            for configured in ("", "s3cret"):
                with mock.patch.object(booking, "API_KEY", configured):
                    for sent in ("", "change-me-in-production"):
                        r = client.get("/api/bookings", headers={"X-API-Key": sent})
                        self.assertEqual(r.status_code, 401, (configured, sent))
            with mock.patch.object(booking, "API_KEY", "s3cret"):
                r = client.get("/api/bookings", headers={"X-API-Key": "s3cret"})
                self.assertEqual(r.status_code, 200)


class BookingDateTests(unittest.TestCase):
    def test_dates_at_the_calendar_edge_are_refused_not_crashed(self):
        booking.init_booking_db()
        with TestClient(server.app) as client:
            self.assertEqual(client.get("/api/slots?week_start=9999-12-31").status_code, 400)
            for slot in ("0001-01-01T00:00:00+14:00", "9999-12-31T23:00:00-12:00"):
                r = client.post("/api/book", json={"slot": slot, "name": "x"})
                self.assertEqual(r.status_code, 400, slot)


class WeeklyTests(unittest.TestCase):
    def test_one_unmatchable_alert_does_not_stop_the_others(self):
        conn = models.get_db(Path(_TMP.name) / "weekly.db")
        try:
            broken = models.create_user(conn, "broken@example.com")
            models.verify_user(conn, broken["verify_token"])
            # More LIKE parameters than SQLite accepts in one query.
            models.add_subscription(conn, broken["id"], player="a " * 17000)
            fine = models.create_user(conn, "fine@example.com")
            models.verify_user(conn, fine["verify_token"])
            models.add_subscription(conn, fine["id"], player="Carlsen")
            models.insert_game(conn, {"White": "Carlsen"}, "1. e4 *", "twic1.pgn", 1)
            conn.commit()
            sent = []
            with mock.patch.object(weekly, "import_games_batch", lambda games, db: {}), \
                    mock.patch.object(weekly, "send_ses_email",
                                      lambda to, *a: sent.append(to) or True):
                weekly._run_match_and_notify(conn, [1], dry_run=False)
            self.assertIn("fine@example.com", sent)
        finally:
            conn.close()


if __name__ == "__main__":
    unittest.main()
