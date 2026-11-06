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


def redirect_uri():
    owner, repo = os.environ.get("GITHUB_REPOSITORY", "/").split("/", 1)
    return f"https://{owner.lower()}.github.io/{repo}/callback.html"


def main():
    raw = os.environ.get("CODE", "").strip().strip('"\'')
    if "code=" in raw:
        # take the code straight from the address without turning "+" into a space
        part = raw.split("code=", 1)[1].split("&", 1)[0].split("#", 1)[0]
        raw = urllib.parse.unquote(part)
    # a "+" in the code may have been shown or pasted as a space
    raw = raw.replace("\r", "").replace("\n", "").strip().replace(" ", "+")
    if not raw:
        sys.exit("::error::No code given. Paste the code from the callback page.")
    print(f"::add-mask::{raw}")
    try:
        tok = build.token_request({"grant_type": "authorization_code", "code": raw, "redirect_uri": redirect_uri()})
    except build.AuthError as e:
        sys.exit(f"::error::SolarEdge didn't accept the code ({e}). Codes work once and expire within minutes, so start again from the Connect button.")
    if not tok.get("refresh_token"):
        sys.exit("::error::SolarEdge returned no refresh token.")
    build.save_refresh_token(tok["refresh_token"])
    print("Connected. The refresh token is saved as SOLAREDGE_REFRESH_TOKEN.")


if __name__ == "__main__":
    main()
