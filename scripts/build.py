"""Builds the site into _site/.

Reads Toronto Hydro exports from data/hydro/ (.xlsx or .csv) and pulls
production from the SolarEdge Monitoring API V2, then writes everything the app
needs to _site/data.json.

SolarEdge V2 uses OAuth. The refresh token changes every time it is used, so
right after each refresh the new one is saved back to the repository's secrets
with the GitHub CLI. No credential is ever written to the site.

To keep inside the free tier (about 2,000 calls a month) the build reuses the
previously published data.json and only asks SolarEdge for what changed:
today's quarter-hour production on every daytime run, and the daily history,
lifetime total and site details once a day.
"""
import base64
import csv
import datetime as dt
import glob
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path
from zoneinfo import ZoneInfo

TZ = ZoneInfo("America/Toronto")
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "_site"
API = "https://monitoringapi.solaredge.com/v2"
TOKEN_URL = API + "/oauth2/token"
AUTHORIZE_URL = "https://connect.solaredge.com/authorize"
NIGHT = (22, 5)  # scheduled runs skip SolarEdge between 10 pm and 5 am


def log(msg):
    print(msg, file=sys.stderr)


def gh_output(key, value):
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a") as f:
            f.write(f"{key}={value}\n")


# ---------- Toronto Hydro ----------

def _parse_time(v):
    if isinstance(v, dt.datetime):
        return v
    if isinstance(v, dt.date):
        return dt.datetime(v.year, v.month, v.day)
    s = str(v or "").strip()
    for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d", "%m/%d/%Y %H:%M", "%m/%d/%Y"):
        try:
            return dt.datetime.strptime(s, fmt)
        except ValueError:
            pass
    return None


def _num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _rows(path):
    if path.suffix.lower() == ".csv":
        with open(path, newline="", encoding="utf-8-sig") as f:
            yield from csv.reader(f)
    else:
        import openpyxl
        wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
        for ws in wb.worksheets:
            ws.reset_dimensions()  # Toronto Hydro's export reports a wrong sheet size
            yield from ws.iter_rows(values_only=True)


def read_hydro():
    """Returns {date: [imported kWh, exported kWh]} from every file in data/hydro."""
    readings = {}
    files = sorted(glob.glob(str(ROOT / "data/hydro/*.xlsx")) + glob.glob(str(ROOT / "data/hydro/*.csv")))
    for f in files:
        imp_col = exp_col = None
        n = 0
        for row in _rows(Path(f)):
            cells = list(row or [])
            if imp_col is None:
                labels = [str(c or "").lower() for c in cells]
                if any("delivered" in c for c in labels) and any("received" in c for c in labels):
                    imp_col = next(i for i, c in enumerate(labels) if "delivered" in c)
                    exp_col = next(i for i, c in enumerate(labels) if "received" in c)
                continue
            if not cells:
                continue
            t = _parse_time(cells[0])
            imp = _num(cells[imp_col]) if imp_col < len(cells) else None
            exp = _num(cells[exp_col]) if exp_col < len(cells) else None
            if t is None or imp is None or exp is None:
                continue
            readings[t] = (imp, exp)  # keyed by timestamp, so overlapping files don't double count
            n += 1
        log(f"hydro: {Path(f).name}: {n} readings" if imp_col is not None else f"hydro: {Path(f).name}: no Delivered/Received columns found, skipped")
    daily = defaultdict(lambda: [0.0, 0.0])
    for t, (imp, exp) in readings.items():
        d = t.date().isoformat()
        daily[d][0] += imp
        daily[d][1] += exp
    return dict(daily)


# ---------- SolarEdge V2 ----------

class AuthError(Exception):
    pass


def _http(req):
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        try:
            body = json.loads(e.read() or b"null")
        except ValueError:
            body = None
        return e.code, body
    except (urllib.error.URLError, OSError, ValueError) as e:
        return 0, {"error": f"network error: {e}"}


def token_request(data):
    """POST to the token endpoint. Known clients use JSON with the credentials in
    the body; fall back to a form post with Basic auth if that is refused."""
    cid, secret = os.environ["SOLAREDGE_CLIENT_ID"].strip(), os.environ["SOLAREDGE_CLIENT_SECRET"].strip()
    headers = {"Accept": "application/json", "User-Agent": "home-solar"}
    attempts = [
        urllib.request.Request(TOKEN_URL, method="POST",
                               data=json.dumps({**data, "client_id": cid, "client_secret": secret}).encode(),
                               headers={**headers, "Content-Type": "application/json"}),
        urllib.request.Request(TOKEN_URL, method="POST", data=urllib.parse.urlencode(data).encode(),
                               headers={**headers, "Content-Type": "application/x-www-form-urlencoded",
                                        "Authorization": "Basic " + base64.b64encode(f"{cid}:{secret}".encode()).decode()}),
    ]
    last = None
    for req in attempts:
        status, body = _http(req)
        if status < 400 and isinstance(body, dict) and body.get("access_token"):
            return body
        last = last or f"HTTP {status}: {(body or {}).get('error_description') or (body or {}).get('detail') or (body or {}).get('error') or ''}".strip()
        if status >= 500 or status == 0:
            break
    raise AuthError(f"token request refused ({last})")


def save_refresh_token(token):
    """Store the new refresh token as a repository secret. It must happen right
    away: the old one stopped working the moment it was used."""
    if not os.environ.get("GH_TOKEN") or not os.environ.get("GITHUB_REPOSITORY"):
        raise RuntimeError("GH_PAT secret is missing, so the new refresh token can't be saved")
    print(f"::add-mask::{token}")
    subprocess.run(["gh", "secret", "set", "SOLAREDGE_REFRESH_TOKEN", "--repo", os.environ["GITHUB_REPOSITORY"]],
                   input=token.encode(), check=True, capture_output=True)


CALLS = 0


def api_get(token, path, params=None):
    global CALLS
    CALLS += 1
    url = f"{API}{path}" + ("?" + urllib.parse.urlencode(params) if params else "")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                                               "User-Agent": "home-solar"})
    for attempt in range(2):
        status, body = _http(req)
        if status == 429 and attempt == 0:
            time.sleep(15)
            continue
        if status in (401, 403):
            raise AuthError(f"{path}: HTTP {status}")
        if status >= 400 or status == 0:
            raise RuntimeError(f"{path}: HTTP {status} {body}")
        return body
    raise RuntimeError(f"{path}: rate limited")


def _instant(t):
    return t.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _find(data, *keys):
    """First value for any of keys, searching nested dicts."""
    if isinstance(data, dict):
        for k in keys:
            if k in data and data[k] is not None:
                return data[k]
        for v in data.values():
            r = _find(v, *keys)
            if r is not None:
                return r
    return None


def _series(body):
    """[(datetime or None, Wh)] from a {unit, values:[{timestamp, value}]} envelope."""
    values = _find(body, "values") if not isinstance(body, list) else body
    unit = str(_find(body, "unit", "units") or "WH").upper() if isinstance(body, dict) else "WH"
    factor = {"WH": 1, "KWH": 1000, "MWH": 1e6, "W": 1, "KW": 1000}.get(unit, 1)
    out = []
    for v in values or []:
        if not isinstance(v, dict):
            continue
        ts = v.get("timestamp") or v.get("date") or v.get("time")
        val = v.get("value")
        out.append((_ts(ts), None if val is None else float(val) * factor))
    return out


def _ts(s):
    if not s:
        return None
    s = str(s).replace("Z", "+00:00").replace(" ", "T")
    try:
        t = dt.datetime.fromisoformat(s)
    except ValueError:
        return None
    return t.astimezone(TZ) if t.tzinfo else t.replace(tzinfo=TZ)


def _day_of(t):
    # DAY buckets may come back as local midnight or as UTC midnight; adding
    # 12 hours lands both on the right calendar day.
    return (t + dt.timedelta(hours=12)).date().isoformat()


def fetch_daily(token, start, end):
    """Daily production (kWh) between two local dates. Falls back to month-sized
    requests if the API won't return the whole span in one call."""
    def one(a, b):
        body = api_get(token, f"/sites/{SITE}/energy", {
            "resolution": "DAY", "unit": "WH",
            "from": _instant(dt.datetime.combine(a, dt.time(), TZ)),
            "to": _instant(min(dt.datetime.combine(b + dt.timedelta(days=1), dt.time(), TZ), dt.datetime.now(TZ)))})
        return {_day_of(t): round(v / 1000, 2) for t, v in _series(body) if t and v is not None}
    try:
        return one(start, end)
    except RuntimeError as e:
        if (end - start).days <= 31:
            raise
        log(f"solaredge: long daily span refused ({e}), fetching month by month")
        out, a = {}, start
        while a <= end:
            b = min(a + dt.timedelta(days=30), end)
            out.update(one(a, b))
            a = b + dt.timedelta(days=1)
            time.sleep(7)  # 10 calls a minute
        return out


def authorize_url():
    cid, base = os.environ.get("SOLAREDGE_CLIENT_ID", "").strip(), os.environ.get("PAGES_URL", "").rstrip("/")
    if not cid or not base:
        return None
    return AUTHORIZE_URL + "?" + urllib.parse.urlencode({
        "response_type": "code", "client_id": cid, "redirect_uri": f"{base}/callback.html",
        "scope": "SITE_DATA DEVICE_DATA", "access_duration": "24", "external_id": "home-solar"})


def previous_data():
    base = os.environ.get("PAGES_URL", "").rstrip("/")
    if not base:
        return {}
    try:
        with urllib.request.urlopen(f"{base}/data.json?ts={int(time.time())}", timeout=20) as r:
            return json.load(r)
    except Exception as e:
        log(f"previous data.json not available ({e}), starting fresh")
        return {}


def read_solaredge(prev):
    """Returns (solar block, token_lost)."""
    global SITE
    SITE = os.environ.get("SOLAREDGE_SITE_ID", "").strip()
    refresh = os.environ.get("SOLAREDGE_REFRESH_TOKEN", "").strip()
    has_app = os.environ.get("SOLAREDGE_CLIENT_ID") and os.environ.get("SOLAREDGE_CLIENT_SECRET") and SITE
    if not has_app:
        log("solaredge: client ID, client secret or site ID not set, building without production data")
        return None, False
    if not refresh:
        log("solaredge: not connected yet, run the Connect SolarEdge workflow")
        return ({**prev, "connected": False, "needsConnect": True} if prev.get("daily") else {"connected": False, "needsConnect": True}), False

    now = dt.datetime.now(TZ)
    today = now.date()
    if os.environ.get("GITHUB_EVENT_NAME") == "schedule" and (now.hour >= NIGHT[0] or now.hour < NIGHT[1]) and prev.get("daily"):
        log("solaredge: night time, reusing the last data")
        return prev, False

    try:
        tok = token_request({"grant_type": "refresh_token", "refresh_token": refresh})
    except AuthError as e:
        log(f"solaredge: {e}. Access has expired, run the Connect SolarEdge workflow again")
        return {**prev, "connected": False, "needsConnect": True, "error": "SolarEdge access expired"}, False
    if tok.get("refresh_token"):
        try:
            save_refresh_token(tok["refresh_token"])
        except Exception as e:
            log(f"::error::Couldn't save the new SolarEdge refresh token: {e}. Run Connect SolarEdge again.")
            return {**prev, "connected": False, "needsConnect": True, "error": "SolarEdge token couldn't be saved"}, True
    access = tok["access_token"]

    solar = dict(prev) if prev.get("connected") or prev.get("daily") else {}
    solar.update({"connected": True, "needsConnect": False, "error": None})
    try:
        # once a day: site details, lifetime total and any missing daily history
        if solar.get("historyDate") != today.isoformat():
            d = api_get(access, f"/sites/{SITE}")
            solar["peakKw"] = _find(d, "peakPower") or solar.get("peakKw")
            inst = _find(d, "installationDate")
            solar["installed"] = str(inst)[:10] if inst else solar.get("installed")

            daily = dict(solar.get("daily") or {})
            if daily:
                start = dt.date.fromisoformat(max(daily)) - dt.timedelta(days=3)
            else:
                start = today - dt.timedelta(days=364)
            daily.update(fetch_daily(access, start, today))
            cutoff = (today - dt.timedelta(days=400)).isoformat()
            solar["daily"] = {k: v for k, v in sorted(daily.items()) if k >= cutoff}

            since = dt.date.fromisoformat(solar["installed"]) if solar.get("installed") else today - dt.timedelta(days=3650)
            body = api_get(access, f"/sites/{SITE}/energy", {
                "resolution": "YEAR", "unit": "WH",
                "from": _instant(dt.datetime.combine(since.replace(month=1, day=1), dt.time(), TZ)),
                "to": _instant(now)})
            solar["lifetimeBase"] = round(sum(v for _, v in _series(body) if v) / 1000, 1)
            solar["lifetimeBaseToday"] = solar["daily"].get(today.isoformat(), 0)
            solar["historyDate"] = today.isoformat()

        # every run: today's quarter hours
        body = api_get(access, f"/sites/{SITE}/energy", {
            "resolution": "QUARTER_HOUR", "unit": "WH",
            "from": _instant(dt.datetime.combine(today, dt.time(), TZ)), "to": _instant(now)})
        qh = [(t, v) for t, v in _series(body) if t and t.date() == today]
        today_kwh = round(sum(v for _, v in qh if v) / 1000, 2)
        last = next(((t, v) for t, v in reversed(qh) if v is not None), None)
        solar["todayCurve"] = [[t.strftime("%H:%M"), round((v or 0) * 4 / 1000, 2)] for t, v in qh]
        solar["nowKw"] = round(last[1] * 4 / 1000, 2) if last and (now - last[0]) < dt.timedelta(minutes=45) else 0
        solar["updated"] = last[0].isoformat() if last else solar.get("updated")
    except AuthError as e:
        log(f"solaredge: {e}")
        return {**prev, "connected": False, "needsConnect": True, "error": "SolarEdge refused the request"}, False
    except Exception as e:
        log(f"solaredge: request failed, keeping the last data: {e}")
        return {**(prev or {}), "error": str(e)[:200]}, False

    daily = solar["daily"]
    daily[today.isoformat()] = today_kwh
    ym, y = today.strftime("%Y-%m"), str(today.year)
    solar["today"] = today_kwh
    solar["month"] = round(sum(v for k, v in daily.items() if k.startswith(ym)), 1)
    solar["year"] = round(sum(v for k, v in daily.items() if k.startswith(y)), 1)
    solar["lifetime"] = round(solar.get("lifetimeBase", 0) - solar.get("lifetimeBaseToday", 0) + today_kwh, 1)
    log(f"solaredge: {CALLS} API calls, today {today_kwh} kWh")
    return solar, False


# ---------- build ----------

def main():
    hydro = read_hydro()
    prev = previous_data()
    solar, token_lost = read_solaredge(prev.get("solar") or {})
    panels_file = ROOT / "data/panels.json"
    panels = json.loads(panels_file.read_text()) if panels_file.exists() else None

    data = {
        "generated": dt.datetime.now(TZ).isoformat(timespec="minutes"),
        "hydro": {d: [round(v[0], 2), round(v[1], 2)] for d, v in sorted(hydro.items())},
        "solar": solar,
        "panels": panels,
        "connectUrl": authorize_url() if solar and solar.get("needsConnect") else None,
        "repo": os.environ.get("GITHUB_REPOSITORY"),
    }
    if OUT.exists():
        shutil.rmtree(OUT)
    shutil.copytree(ROOT / "web", OUT)
    (OUT / "data.json").write_text(json.dumps(data, separators=(",", ":")))
    gh_output("token_lost", "true" if token_lost else "false")
    log(f"built _site/ with {len(hydro)} hydro days, solar {'connected' if solar and solar.get('connected') else 'not connected'}")


SITE = ""

if __name__ == "__main__":
    main()
