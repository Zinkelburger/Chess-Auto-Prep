"""Weekly job: ingest latest TWIC, match subscriptions, import to Lichess, send emails."""

import logging
import sys
from collections import defaultdict
from pathlib import Path

from models import (
    get_db, get_all_active_subscriptions, record_notification,
    already_notified_batch, build_game_filters, create_email_token,
    cleanup_expired_email_tokens, parse_fen_list,
)
from query import find_games
from ingest import ingest_latest
from lichess import import_games_batch
from email_sender import (
    build_email_html, build_email_text, send_ses_email,
    build_no_matches_html, build_no_matches_text,
)
from export_events import export_all as export_static_data

log = logging.getLogger("twic.weekly")


def match_subscription(db, sub: dict, twic_number: int) -> list[dict]:
    """Find games matching a subscription, limited to a specific TWIC issue."""
    filter_kwargs = {}
    for key in ("white", "black", "player", "exclude_site", "site",
                "min_elo", "max_elo", "eco", "time_control", "result", "event"):
        if sub.get(key):
            filter_kwargs[key] = sub[key]

    fens = parse_fen_list(sub.get("fen"))
    if fens:
        seen_ids: set[int] = set()
        games: list[dict] = []
        for fen in fens:
            for g in find_games(db, fen, twic_number=twic_number,
                                limit=200, **filter_kwargs):
                if g["id"] not in seen_ids:
                    seen_ids.add(g["id"])
                    games.append(g)
    elif filter_kwargs:
        clauses, params = build_game_filters(twic_number=twic_number, **filter_kwargs)
        sql = "SELECT g.*, NULL AS match_ply, NULL AS match_fen FROM games g"
        if clauses:
            sql += " WHERE " + " AND ".join(clauses)
        sql += " LIMIT 200"
        rows = db.execute(sql, params).fetchall()
        games = [dict(r) for r in rows]
    else:
        return []

    notified = already_notified_batch(db, sub["id"], [g["id"] for g in games])
    return [g for g in games if g["id"] not in notified]


def run_weekly(db_path: Path | None = None, dry_run: bool = False,
               start_from: int | None = None):
    """Full weekly pipeline: ingest -> match -> import -> email."""
    db_path = db_path or Path(__file__).parent / "positions.db"

    # Step 1: Ingest latest TWIC
    log.info("=" * 60)
    log.info("STEP 1: Ingesting latest TWIC files")
    log.info("=" * 60)
    new_issues = ingest_latest(db_path, start_from)

    if not new_issues:
        log.info("No new TWIC issues. Nothing to do.")
        return

    db = get_db(db_path)

    try:
        _run_match_and_notify(db, new_issues, dry_run)
    finally:
        removed = cleanup_expired_email_tokens(db)
        if removed:
            log.info("Cleaned up %d expired email token(s)", removed)
        db.commit()
        db.close()

    try:
        export_static_data(db_path)
        log.info("Exported updated events.json + players.json for frontend")
    except Exception:
        log.exception("Failed to export static JSON files (non-fatal)")

    log.info("Weekly run complete.")


def _run_match_and_notify(db, new_issues: list[int], dry_run: bool):
    """Steps 2–4: match, import, email."""
    # Step 2: Match subscriptions
    log.info("STEP 2: Matching subscriptions against TWIC #%s",
             ", #".join(map(str, new_issues)))

    subs = get_all_active_subscriptions(db)
    log.info("  %d active subscription(s) from verified users", len(subs))

    user_matches: dict[str, list[tuple[dict, list[dict]]]] = defaultdict(list)
    user_no_matches: dict[str, list[dict]] = defaultdict(list)

    for sub in subs:
        all_matches = []
        for twic_num in new_issues:
            all_matches.extend(match_subscription(db, sub, twic_num))
        if all_matches:
            log.info("  Sub #%d (%s) -> %d game(s)",
                     sub["id"], sub.get("label", ""), len(all_matches))
            user_matches[sub["email"]].append((sub, all_matches))
        else:
            log.info("  Sub #%d (%s) -> no matches",
                     sub["id"], sub.get("label", ""))
            user_no_matches[sub["email"]].append(sub)

    # Step 3: Import to Lichess (skip in dry-run)
    log.info("STEP 3: Importing matched games to Lichess")

    lichess_urls: dict[int, str] = {}
    if dry_run:
        log.info("  [DRY RUN] Skipping Lichess import")
    else:
        all_matched_games = {}
        for email, sub_matches in user_matches.items():
            for sub, games in sub_matches:
                for g in games:
                    if g["id"] not in all_matched_games:
                        all_matched_games[g["id"]] = g

        unique_games = list(all_matched_games.values())
        log.info("  %d unique game(s) to import", len(unique_games))
        lichess_urls = import_games_batch(unique_games, db)
        log.info("  %d game(s) imported to Lichess", len(lichess_urls))

    # Step 4: Send emails
    log.info("STEP 4: Sending notification emails")

    twic_label = ", #".join(map(str, new_issues))

    for email, sub_matches in user_matches.items():
        for sub, games in sub_matches:
            manage_token = create_email_token(db, sub["user_id"], "login")
            unsub_token = create_email_token(
                db, sub["user_id"], "unsubscribe",
                subscription_id=sub["id"],
            )

            # Sort by highest Elo (max of white/black), descending
            def _max_elo(g):
                w = g.get("white_elo") or 0
                b = g.get("black_elo") or 0
                return max(int(w) if w else 0, int(b) if b else 0)

            sorted_games = sorted(games, key=_max_elo, reverse=True)
            email_games = sorted_games[:10]
            total_count = len(games)

            subject = (f"TWIC #{twic_label}: {total_count} game(s) matched"
                       f" — {sub.get('label') or 'Position Alert'}")
            html = build_email_html(sub, email_games, lichess_urls,
                                    manage_token=manage_token,
                                    unsub_token=unsub_token,
                                    total_matches=total_count)
            text = build_email_text(sub, email_games, lichess_urls,
                                    manage_token=manage_token,
                                    unsub_token=unsub_token,
                                    total_matches=total_count)

            if dry_run:
                log.info("  [DRY RUN] Would email %s: %s", email, subject)
                preview_path = Path(__file__).parent / "email_preview.html"
                preview_path.write_text(html)
                log.info("  Preview saved to %s", preview_path)
            else:
                ok = send_ses_email(email, subject, html, text)
                if ok:
                    log.info("  Emailed %s: %s", email, subject)
                    # Record notifications for ALL matches, not just emailed ones
                    for g in games:
                        record_notification(
                            db, sub["id"], g["id"],
                            g.get("twic_number") or new_issues[-1],
                        )
                else:
                    log.error("  FAILED to email %s: %s (will retry next run)",
                              email, subject)

    # Step 5: Send "no matches" digests for subscriptions that had zero results
    for email, subs_without_matches in user_no_matches.items():
        # Skip if this user already got a matches email for a different sub
        # (they know we're alive)
        if email in user_matches:
            log.info("  Skipping no-match email for %s (already got a match email)",
                     email)
            continue

        for sub in subs_without_matches:
            manage_token = create_email_token(db, sub["user_id"], "login")
            unsub_token = create_email_token(
                db, sub["user_id"], "unsubscribe",
                subscription_id=sub["id"],
            )

            subject = (f"TWIC #{twic_label}: No matches this week"
                       f" — {sub.get('label') or 'Position Alert'}")
            html = build_no_matches_html(sub, twic_label,
                                         manage_token=manage_token,
                                         unsub_token=unsub_token)
            text = build_no_matches_text(sub, twic_label,
                                         manage_token=manage_token,
                                         unsub_token=unsub_token)

            if dry_run:
                log.info("  [DRY RUN] Would send no-match email %s: %s",
                         email, subject)
            else:
                ok = send_ses_email(email, subject, html, text)
                if ok:
                    log.info("  Sent no-match digest to %s: %s", email, subject)
                else:
                    log.error("  FAILED no-match email to %s (non-critical)",
                              email)


if __name__ == "__main__":
    import argparse

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        stream=sys.stdout,
    )

    parser = argparse.ArgumentParser(description="Weekly TWIC ingestion and notification job")
    parser.add_argument("--db", type=Path, default=Path(__file__).parent / "positions.db")
    parser.add_argument("--dry-run", action="store_true",
                        help="Don't send emails or import to Lichess, just preview")
    parser.add_argument("--from", dest="start", type=int, default=None,
                        help="Start TWIC download from this number")
    args = parser.parse_args()

    try:
        run_weekly(args.db, dry_run=args.dry_run, start_from=args.start)
    except Exception:
        log.exception("Weekly run failed")
        sys.exit(1)
