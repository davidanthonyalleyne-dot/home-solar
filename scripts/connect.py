"""One-time step: swap the code SolarEdge gave you for a refresh token and save
it as the SOLAREDGE_REFRESH_TOKEN repository secret.

Run by the "Connect SolarEdge" workflow. Paste either the code or the whole
address the callback page shows.
"""
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(__file__))
import build  # noqa: E402


def main():
    raw = os.environ.get("CODE", "").strip()
    if "code=" in raw:
        raw = urllib.parse.parse_qs(urllib.parse.urlsplit(raw).query).get("code", [""])[0]
    if not raw:
        sys.exit("::error::No code given. Paste the code from the callback page.")
    print(f"::add-mask::{raw}")
    try:
        tok = build.token_request({"grant_type": "authorization_code", "code": raw})
    except build.AuthError as e:
        sys.exit(f"::error::SolarEdge didn't accept the code ({e}). Codes work once and expire within minutes, so start again from the Connect button.")
    if not tok.get("refresh_token"):
        sys.exit("::error::SolarEdge returned no refresh token.")
    build.save_refresh_token(tok["refresh_token"])
    print("Connected. The refresh token is saved as SOLAREDGE_REFRESH_TOKEN.")


if __name__ == "__main__":
    main()
