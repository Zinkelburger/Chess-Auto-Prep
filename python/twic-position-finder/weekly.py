"""Weekly job: ingest latest TWIC, match subscriptions, import to Lichess, send emails."""

from collections import defaultdict
from pathlib import Path

from models import (
    get_db, get_all_active_subscriptions, record_notification,
    already_notified_batch, build_game_filters, create_email_token,
    cleanup_expired_email_tokens,
)
from query import find_games
from ingest import ingest_latest
from lichess import import_games_batch
from email_sender import build_email_html, build_email_text, send_ses_email


def match_subscription(db, sub: dict, twic_number: int) -> list[dict]:
    """Find games matching a subscription, limited to a specific TWIC issue."""
    filter_kwargs = {}
    for key in ("white", "black", "player", "exclude_site", "site", "min_elo", "eco"):
        if sub.get(key):
            filter_kwargs[key] = sub[key]

    if sub.get("fen"):
        games = find_games(db, sub["fen"], twic_number=twic_number,
                           limit=200, **filter_kwargs)
    elif filter_kwargs:
        clauses, params = build_game_filters(twic_number=twic_number, **filter_kwargs)
        sql = "SELECT g.* FROM games g"
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
    print("=" * 60)
    print("STEP 1: Ingesting latest TWIC files")
    print("=" * 60)
    new_issues = ingest_latest(db_path, start_from)

    if not new_issues:
        print("No new TWIC issues. Nothing to do.")
        return

    db = get_db(db_path)

    # Step 2: Match subscriptions against ALL newly-ingested issues
    print(f"\n{'=' * 60}")
    print(f"STEP 2: Matching subscriptions against TWIC #{', #'.join(map(str, new_issues))}")
    print("=" * 60)

    subs = get_all_active_subscriptions(db)
    print(f"  {len(subs)} active subscription(s) from verified users")

    # Group matches by user email
    user_matches: dict[str, list[tuple[dict, list[dict]]]] = defaultdict(list)

    for sub in subs:
        all_matches = []
        for twic_num in new_issues:
            all_matches.extend(match_subscription(db, sub, twic_num))
        if all_matches:
            print(f"  Sub #{sub['id']} ({sub.get('label','')}) -> {len(all_matches)} game(s)")
            user_matches[sub["email"]].append((sub, all_matches))
        else:
            print(f"  Sub #{sub['id']} ({sub.get('label','')}) -> no matches")

    if not user_matches:
        print("\nNo matches found for any subscription. Done.")
        db.close()
        return

    # Step 3: Import to Lichess
    print(f"\n{'=' * 60}")
    print("STEP 3: Importing matched games to Lichess")
    print("=" * 60)

    all_matched_games = {}
    for email, sub_matches in user_matches.items():
        for sub, games in sub_matches:
            for g in games:
                if g["id"] not in all_matched_games:
                    all_matched_games[g["id"]] = g

    unique_games = list(all_matched_games.values())
    print(f"  {len(unique_games)} unique game(s) to import")
    lichess_urls = import_games_batch(unique_games, db)
    print(f"  {len(lichess_urls)} game(s) imported to Lichess")

    # Step 4: Send emails
    print(f"\n{'=' * 60}")
    print("STEP 4: Sending notification emails")
    print("=" * 60)

    twic_label = ", #".join(map(str, new_issues))

    for email, sub_matches in user_matches.items():
        for sub, games in sub_matches:
            manage_token = create_email_token(db, sub["user_id"], "login")
            unsub_token = create_email_token(
                db, sub["user_id"], "unsubscribe",
                subscription_id=sub["id"],
            )
            subject = (f"TWIC #{twic_label}: {len(games)} game(s) matched"
                       f" — {sub.get('label') or 'Position Alert'}")
            html = build_email_html(sub, games, lichess_urls,
                                    manage_token=manage_token,
                                    unsub_token=unsub_token)
            text = build_email_text(sub, games, lichess_urls,
                                    manage_token=manage_token,
                                    unsub_token=unsub_token)

            if dry_run:
                print(f"  [DRY RUN] Would email {email}: {subject}")
                preview_path = Path(__file__).parent / "email_preview.html"
                preview_path.write_text(html)
                print(f"  Preview saved to {preview_path}")
            else:
                ok = send_ses_email(email, subject, html, text)
                if ok:
                    print(f"  Emailed {email}: {subject}")
                else:
                    print(f"  FAILED to email {email}: {subject}")

                for g in games:
                    record_notification(db, sub["id"], g["id"],
                                        g.get("twic_number", new_issues[-1]))

    removed = cleanup_expired_email_tokens(db)
    if removed:
        print(f"  Cleaned up {removed} expired email token(s)")

    db.commit()
    db.close()
    print(f"\nWeekly run complete.")


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Weekly TWIC ingestion and notification job")
    parser.add_argument("--db", type=Path, default=Path(__file__).parent / "positions.db")
    parser.add_argument("--dry-run", action="store_true",
                        help="Don't send emails, just print what would be sent and save HTML preview")
    parser.add_argument("--from", dest="start", type=int, default=None,
                        help="Start TWIC download from this number")
    args = parser.parse_args()

    run_weekly(args.db, dry_run=args.dry_run, start_from=args.start)
