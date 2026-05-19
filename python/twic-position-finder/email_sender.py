"""Send notification emails via Amazon SES with rich HTML game summaries."""

import html
import os

import boto3
from botocore.exceptions import ClientError

SES_REGION = os.getenv("AWS_SES_REGION", "us-east-1")
FROM_EMAIL = os.getenv("TWIC_FROM_EMAIL", "subscriptions@chessautoprep.com")
SITE_URL = os.getenv("TWIC_SITE_URL", "https://chessautoprep.com")

_ses_client = None


def _get_ses_client():
    global _ses_client
    if _ses_client is None:
        _ses_client = boto3.client("ses", region_name=SES_REGION)
    return _ses_client


def _esc(value, fallback: str = "?") -> str:
    """HTML-escape a value from PGN data."""
    return html.escape(str(value)) if value else html.escape(fallback)


def _game_card_html(game: dict, lichess_url: str | None = None) -> str:
    """Render a single game as an HTML card for email."""
    white = _esc(game.get("white"))
    black = _esc(game.get("black"))
    elo_w = f" ({game['white_elo']})" if game.get('white_elo') else ""
    elo_b = f" ({game['black_elo']})" if game.get('black_elo') else ""
    event = _esc(game.get("event"), "")
    site = _esc(game.get("site"), "")
    date = _esc(game.get("date"), "")
    eco = _esc(game.get("eco"))
    opening = _esc(game.get("opening"), "")

    result_colors = {
        "1-0": "#2d8a4e", "0-1": "#c33",
        "1/2-1/2": "#888", "*": "#555",
    }
    result = game.get("result", "*")
    result_color = result_colors.get(result, "#555")
    result_safe = _esc(result)

    inner = f'''
      <div style="font-size:16px;margin-bottom:6px;">
        <span style="color:#e8e8e8;">{white}{elo_w}</span>
        <span style="color:#888;"> vs </span>
        <span style="color:#e8e8e8;">{black}{elo_b}</span>
        <span style="color:{result_color};font-weight:bold;margin-left:12px;">
          {result_safe}
        </span>
      </div>
      <div style="color:#aaa;font-size:13px;">
        {event} &middot; {site} &middot; {date}
      </div>
      <div style="color:#aaa;font-size:13px;">
        ECO: {eco} &middot; {opening}
        {f' &middot; Reached at ply {game["match_ply"]}' if game.get("match_ply") is not None else ""}
      </div>'''

    if lichess_url:
        return f'''
    <a href="{html.escape(lichess_url)}" target="_blank"
       style="display:block;background:#1e1e1e;border:1px solid #333;border-radius:8px;
              padding:16px;margin-bottom:12px;font-family:monospace;text-decoration:none;
              transition:border-color 0.2s;">
      {inner}
      <div style="color:#629924;font-size:12px;margin-top:8px;">View on Lichess &rarr;</div>
    </a>'''
    else:
        return f'''
    <div style="background:#1e1e1e;border:1px solid #333;border-radius:8px;
                padding:16px;margin-bottom:12px;font-family:monospace;">
      {inner}
    </div>'''


def build_email_html(subscription: dict, games: list[dict],
                     lichess_urls: dict[int, str],
                     manage_token: str | None = None,
                     unsub_token: str | None = None,
                     total_matches: int | None = None) -> str:
    """Build a full HTML email body for a subscription match."""
    total_matches = total_matches or len(games)
    sub_desc_parts = []
    if subscription.get("fen"):
        sub_desc_parts.append(f"Position: <code>{_esc(subscription['fen'])}</code>")
    if subscription.get("player"):
        sub_desc_parts.append(f"Player: {_esc(subscription['player'])}")
    if subscription.get("white"):
        sub_desc_parts.append(f"White: {_esc(subscription['white'])}")
    if subscription.get("black"):
        sub_desc_parts.append(f"Black: {_esc(subscription['black'])}")
    if subscription.get("eco"):
        sub_desc_parts.append(f"ECO: {_esc(subscription['eco'])}")
    if subscription.get("min_elo"):
        sub_desc_parts.append(f"Min Elo: {subscription['min_elo']}")
    if subscription.get("max_elo"):
        sub_desc_parts.append(f"Max Elo: {subscription['max_elo']}")
    # Only show time_control/result if non-default (i.e. user narrowed them)
    tc = subscription.get("time_control")
    if tc and tc != "classical,rapid,blitz":
        sub_desc_parts.append(f"Time control: {_esc(tc)}")
    res = subscription.get("result")
    if res and res != "1-0,0-1,1/2-1/2":
        sub_desc_parts.append(f"Result: {_esc(res)}")
    if subscription.get("event"):
        sub_desc_parts.append(f"Event: {_esc(subscription['event'])}")
    sub_desc = " &middot; ".join(sub_desc_parts)

    game_cards = ""
    for g in games:
        url = lichess_urls.get(g.get("id"))
        game_cards += _game_card_html(g, url)

    manage_qs = f"?token={manage_token}" if manage_token else ""
    manage_link = f'{SITE_URL}/dashboard{manage_qs}'

    unsub_link = ""
    if unsub_token:
        unsub_url = (f'{SITE_URL}/unsubscribe?token={unsub_token}'
                     f'&sub={subscription["id"]}')
        unsub_link = f'''
      <br/>
      <a href="{unsub_url}" style="color:#888;font-size:12px;
         text-decoration:underline;">
        Unsubscribe from this alert
      </a>'''

    showing_note = ""
    if total_matches > len(games):
        showing_note = f'''
    <p style="color:#aaa;font-size:13px;margin-bottom:16px;text-align:center;">
      Showing top {len(games)} by rating.
      <a href="{manage_link}" style="color:#629924;text-decoration:underline;">
        Download all {total_matches} games from your dashboard
      </a>
    </p>'''

    return f'''<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width"></head>
<body style="background:#121212;color:#e8e8e8;font-family:-apple-system,Segoe UI,
             Roboto,Helvetica,Arial,sans-serif;padding:24px;margin:0;">
  <div style="max-width:600px;margin:0 auto;">
    <div style="text-align:center;margin-bottom:24px;">
      <h1 style="color:#fff;font-size:22px;margin:0;">
        TWIC Position Alert
      </h1>
      <p style="color:#888;font-size:14px;margin:4px 0 0;">
        {total_matches} new game{"s" if total_matches != 1 else ""} matched your subscription
      </p>
    </div>

    <div style="background:#262626;border-radius:8px;padding:16px;margin-bottom:20px;">
      <div style="color:#aaa;font-size:13px;margin-bottom:4px;">Subscription:</div>
      <div style="color:#e8e8e8;font-size:14px;">
        {_esc(subscription.get("label"), "Untitled")}
      </div>
      <div style="color:#aaa;font-size:13px;margin-top:4px;">{sub_desc}</div>
      <p style="margin-top:12px;">
        <a href="{manage_link}" target="_blank"
           style="color:#629924;text-decoration:underline;font-size:13px;">
          Edit this filter in the dashboard
        </a>
      </p>
    </div>

    <h2 style="color:#fff;font-size:18px;margin-bottom:12px;">
      Matched Games
    </h2>

    {showing_note}
    {game_cards}

    <div style="text-align:center;margin-top:32px;padding-top:16px;
                border-top:1px solid #333;">
      <a href="{manage_link}" style="color:#629924;font-size:13px;
         text-decoration:underline;">
        Manage your subscriptions
      </a>
      {unsub_link}
      <p style="color:#666;font-size:11px;margin-top:8px;">
        TWIC Position Finder &middot; Chess Auto Prep
      </p>
    </div>
  </div>
</body>
</html>'''


def build_email_text(subscription: dict, games: list[dict],
                     lichess_urls: dict[int, str],
                     manage_token: str | None = None,
                     unsub_token: str | None = None,
                     total_matches: int | None = None) -> str:
    """Build a plain-text fallback for the email."""
    total_matches = total_matches or len(games)
    lines = [f"TWIC Position Alert — {total_matches} game(s) matched\n"]

    if subscription.get("label"):
        lines.append(f"Subscription: {subscription['label']}")
    if subscription.get("fen"):
        lines.append(f"Position: {subscription['fen']}")
    if subscription.get("player"):
        lines.append(f"Player: {subscription['player']}")
    lines.append("")

    if total_matches > len(games):
        lines.append(f"Showing top {len(games)} by rating. "
                     f"Download all {total_matches} from your dashboard.\n")

    for g in games:
        elo_w = f" ({g['white_elo']})" if g.get('white_elo') else ""
        elo_b = f" ({g['black_elo']})" if g.get('black_elo') else ""
        lines.append(f"{g.get('white','?')}{elo_w} vs {g.get('black','?')}{elo_b}  "
                      f"{g.get('result','*')}")
        lines.append(f"  {g.get('event','')} | {g.get('site','')} | {g.get('date','')}")
        url = lichess_urls.get(g.get("id"))
        if url:
            lines.append(f"  View on Lichess: {url}")
        lines.append("")

    manage_qs = f"?token={manage_token}" if manage_token else ""
    lines.append(f"Manage subscriptions: {SITE_URL}/dashboard{manage_qs}")

    if unsub_token:
        unsub_url = (f"{SITE_URL}/unsubscribe?token={unsub_token}"
                     f"&sub={subscription['id']}")
        lines.append(f"Unsubscribe from this alert: {unsub_url}")

    return "\n".join(lines)


def send_ses_email(to: str, subject: str, html_body: str, text_body: str) -> bool:
    """Send an email via Amazon SES. Returns True on success."""
    try:
        client = _get_ses_client()
        client.send_email(
            Source=FROM_EMAIL,
            Destination={"ToAddresses": [to]},
            Message={
                "Subject": {"Data": subject, "Charset": "UTF-8"},
                "Body": {
                    "Text": {"Data": text_body, "Charset": "UTF-8"},
                    "Html": {"Data": html_body, "Charset": "UTF-8"},
                },
            },
        )
        return True
    except Exception as e:
        print(f"  SES error sending to {to}: {e}")
        return False


def build_no_matches_html(subscription: dict, twic_label: str,
                          manage_token: str | None = None,
                          unsub_token: str | None = None) -> str:
    """Build an HTML email for when a subscription had no matches this week."""
    sub_desc_parts = []
    if subscription.get("fen"):
        sub_desc_parts.append(f"Position: <code>{_esc(subscription['fen'])}</code>")
    if subscription.get("player"):
        sub_desc_parts.append(f"Player: {_esc(subscription['player'])}")
    if subscription.get("white"):
        sub_desc_parts.append(f"White: {_esc(subscription['white'])}")
    if subscription.get("black"):
        sub_desc_parts.append(f"Black: {_esc(subscription['black'])}")
    if subscription.get("eco"):
        sub_desc_parts.append(f"ECO: {_esc(subscription['eco'])}")
    if subscription.get("min_elo"):
        sub_desc_parts.append(f"Min Elo: {subscription['min_elo']}")
    if subscription.get("max_elo"):
        sub_desc_parts.append(f"Max Elo: {subscription['max_elo']}")
    if subscription.get("exclude_site"):
        sub_desc_parts.append(f"Excluding: {_esc(subscription['exclude_site'])}")
    if subscription.get("event"):
        sub_desc_parts.append(f"Event: {_esc(subscription['event'])}")
    sub_desc = " &middot; ".join(sub_desc_parts)

    manage_qs = f"?token={manage_token}" if manage_token else ""
    manage_link = f'{SITE_URL}/dashboard{manage_qs}'

    unsub_link = ""
    if unsub_token:
        unsub_url = (f'{SITE_URL}/unsubscribe?token={unsub_token}'
                     f'&sub={subscription["id"]}')
        unsub_link = f'''
      <br/>
      <a href="{unsub_url}" style="color:#888;font-size:12px;
         text-decoration:underline;">
        Unsubscribe from this alert
      </a>'''

    return f'''<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width"></head>
<body style="background:#121212;color:#e8e8e8;font-family:-apple-system,Segoe UI,
             Roboto,Helvetica,Arial,sans-serif;padding:24px;margin:0;">
  <div style="max-width:600px;margin:0 auto;">
    <div style="text-align:center;margin-bottom:24px;">
      <h1 style="color:#fff;font-size:22px;margin:0;">
        TWIC #{_esc(twic_label)} — No Matches
      </h1>
      <p style="color:#888;font-size:14px;margin:4px 0 0;">
        Your filter is active, but no games matched this week.
      </p>
    </div>

    <div style="background:#262626;border-radius:8px;padding:16px;margin-bottom:20px;">
      <div style="color:#aaa;font-size:13px;margin-bottom:4px;">Subscription:</div>
      <div style="color:#e8e8e8;font-size:14px;">
        {_esc(subscription.get("label"), "Untitled")}
      </div>
      <div style="color:#aaa;font-size:13px;margin-top:4px;">{sub_desc}</div>
    </div>

    <div style="background:#1e1e1e;border:1px solid #333;border-radius:8px;
                padding:20px;text-align:center;margin-bottom:20px;">
      <p style="color:#aaa;font-size:15px;margin:0 0 12px;">
        We scanned TWIC #{_esc(twic_label)} and didn't find any games
        matching your criteria. We'll check again next week.
      </p>
      <a href="{manage_link}" style="color:#629924;font-size:14px;
         text-decoration:underline;">
        Adjust your filters
      </a>
    </div>

    <div style="text-align:center;margin-top:32px;padding-top:16px;
                border-top:1px solid #333;">
      <a href="{manage_link}" style="color:#629924;font-size:13px;
         text-decoration:underline;">
        Manage your subscriptions
      </a>
      {unsub_link}
      <p style="color:#666;font-size:11px;margin-top:8px;">
        TWIC Position Finder &middot; Chess Auto Prep
      </p>
    </div>
  </div>
</body>
</html>'''


def build_no_matches_text(subscription: dict, twic_label: str,
                          manage_token: str | None = None,
                          unsub_token: str | None = None) -> str:
    """Build a plain-text email for when a subscription had no matches."""
    lines = [f"TWIC #{twic_label} — No Matches\n"]

    if subscription.get("label"):
        lines.append(f"Subscription: {subscription['label']}")
    if subscription.get("fen"):
        lines.append(f"Position: {subscription['fen']}")
    if subscription.get("player"):
        lines.append(f"Player: {subscription['player']}")
    lines.append("")
    lines.append("We scanned this week's TWIC issue and didn't find any games "
                 "matching your criteria. We'll check again next week.")
    lines.append("")

    manage_qs = f"?token={manage_token}" if manage_token else ""
    lines.append(f"Adjust your filters: {SITE_URL}/dashboard{manage_qs}")

    if unsub_token:
        unsub_url = (f"{SITE_URL}/unsubscribe?token={unsub_token}"
                     f"&sub={subscription['id']}")
        lines.append(f"Unsubscribe from this alert: {unsub_url}")

    return "\n".join(lines)


def send_verification_email(to: str, verify_token: str) -> bool:
    """Send email verification link."""
    verify_url = f"{SITE_URL}/verify?token={verify_token}"
    html = f'''<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="background:#121212;color:#e8e8e8;font-family:-apple-system,Segoe UI,
             Roboto,Helvetica,Arial,sans-serif;padding:24px;margin:0;">
  <div style="max-width:500px;margin:0 auto;text-align:center;">
    <h1 style="color:#fff;font-size:22px;">Verify Your Email</h1>
    <p style="color:#aaa;">Click the button below to activate your TWIC Position Finder alerts.</p>
    <a href="{verify_url}" style="display:inline-block;background:#629924;color:#fff;
       padding:14px 32px;border-radius:6px;text-decoration:none;font-weight:bold;
       font-size:16px;margin:20px 0;">
      Verify Email
    </a>
    <p style="color:#666;font-size:12px;margin-top:24px;">
      If you didn't sign up, ignore this email.
    </p>
  </div>
</body>
</html>'''
    text = f"Verify your email for TWIC Position Finder:\n{verify_url}"
    return send_ses_email(to, "Verify your email — TWIC Position Finder", html, text)


def send_login_email(to: str, login_token: str) -> bool:
    """Send a magic login link containing a one-time token."""
    login_url = f"{SITE_URL}/dashboard?token={login_token}"
    html = f'''<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="background:#121212;color:#e8e8e8;font-family:-apple-system,Segoe UI,
             Roboto,Helvetica,Arial,sans-serif;padding:24px;margin:0;">
  <div style="max-width:500px;margin:0 auto;text-align:center;">
    <h1 style="color:#fff;font-size:22px;">Your Login Link</h1>
    <p style="color:#aaa;">Click to access your TWIC Position Finder dashboard.</p>
    <a href="{login_url}" style="display:inline-block;background:#629924;color:#fff;
       padding:14px 32px;border-radius:6px;text-decoration:none;font-weight:bold;
       font-size:16px;margin:20px 0;">
      Open Dashboard
    </a>
    <p style="color:#666;font-size:12px;margin-top:24px;">
      Keep this link private — it grants access to your account.
    </p>
  </div>
</body>
</html>'''
    text = f"Your TWIC Position Finder login link:\n{login_url}"
    return send_ses_email(to, "Your login link — TWIC Position Finder", html, text)
