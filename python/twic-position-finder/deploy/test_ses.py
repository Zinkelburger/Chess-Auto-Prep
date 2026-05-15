#!/usr/bin/env python3
"""Quick smoke test for AWS SES configuration.

Usage:
    python deploy/test_ses.py your-email@example.com

Sends a test email via the same SES path the app uses.
Requires .env or environment variables to be set.
"""
import os
import sys

def main():
    if len(sys.argv) < 2:
        print("Usage: python deploy/test_ses.py <recipient-email>")
        sys.exit(1)

    to = sys.argv[1]

    # Load .env if present
    env_path = os.path.join(os.path.dirname(__file__), "..", ".env")
    if os.path.exists(env_path):
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, _, val = line.partition("=")
                    os.environ.setdefault(key.strip(), val.strip())

    # Now import after env is loaded
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
    from email_sender import send_ses_email, FROM_EMAIL, SES_REGION

    print(f"From:   {FROM_EMAIL}")
    print(f"To:     {to}")
    print(f"Region: {SES_REGION}")
    print(f"Key:    {os.getenv('AWS_ACCESS_KEY_ID', '(not set)')[:8]}...")
    print()

    ok = send_ses_email(
        to=to,
        subject="TWIC Position Finder — SES Test",
        html_body="""
        <div style="background:#121212;color:#e8e8e8;padding:24px;font-family:sans-serif;">
          <h1 style="color:#fff;">SES is working!</h1>
          <p>If you're reading this, your AWS SES configuration for
             TWIC Position Finder is correct.</p>
        </div>""",
        text_body="SES is working! Your TWIC Position Finder email config is correct.",
    )

    if ok:
        print("SUCCESS — check your inbox (and spam folder)")
    else:
        print("FAILED — see error above")
        sys.exit(1)


if __name__ == "__main__":
    main()
