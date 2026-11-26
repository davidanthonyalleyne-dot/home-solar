"""Sets a TestFlight build's "What to Test" notes once Apple has processed it.
   python3 scripts/asc_notes.py <bundle id> <build number> <notes file>
Reads the App Store Connect key from env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH."""
import json, os, sys, time, urllib.request, urllib.error
import jwt  # PyJWT

def token():
    key = open(os.environ["ASC_KEY_PATH"]).read()
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"},
                      key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})

T = None
def api(method, path, body=None):
    global T
    T = T or token()
    url = path if path.startswith("http") else "https://api.appstoreconnect.apple.com" + path
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": "Bearer " + T, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            t = r.read()
            return json.loads(t) if t else {}
    except urllib.error.HTTPError as e:
        print(f"!! {method} {path} -> {e.code}: {e.read().decode()[:600]}")
        return None

def app_id(bundle):
    r = api("GET", f"/v1/apps?filter[bundleId]={bundle}")
    return r["data"][0]["id"]

def notes(bundle, build_number, path):
    """Waits for a build to finish processing, then sets its TestFlight "What to Test" notes from a file"""
    a = app_id(bundle); text = open(path).read().strip()
    for _ in range(60):
        r = api("GET", f"/v1/builds?filter[app]={a}&filter[version]={build_number}&limit=1")
        if r and r["data"] and r["data"][0]["attributes"]["processingState"] in ("VALID", "INVALID", "FAILED"): break
        time.sleep(30)
    else:
        print("build", build_number, "not processed yet"); return
    b = r["data"][0]; print("build", build_number, b["attributes"]["processingState"])
    locs = (api("GET", f"/v1/builds/{b['id']}/betaBuildLocalizations") or {}).get("data", [])
    if locs:
        for l in locs:
            api("PATCH", f"/v1/betaBuildLocalizations/{l['id']}", {"data": {"type": "betaBuildLocalizations", "id": l["id"], "attributes": {"whatsNew": text}}})
    else:
        for loc in ("en-CA", "en-US"):
            api("POST", "/v1/betaBuildLocalizations", {"data": {"type": "betaBuildLocalizations", "attributes": {"locale": loc, "whatsNew": text},
                "relationships": {"build": {"data": {"type": "builds", "id": b["id"]}}}}})
    print("what's new set:", text[:200])


if __name__ == "__main__":
    notes(sys.argv[1], sys.argv[2], sys.argv[3])
